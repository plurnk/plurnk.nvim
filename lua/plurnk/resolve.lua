-- Proposal review (loop/proposal → loop.resolve).
--
-- Wire (plurnk-grammar 0.17): the proposal payload carries
--   { logEntryId, loopId, turnId, op, target {scheme, pathname}, body, attrs, flags }
-- where `body` is a udiff for EDIT and a shell command for EXEC. Server-
-- resolved proposals (flags.yolo / flags.noProposals) never reach this module
-- — dispatch.handle_loop_proposal drops them before review.
-- loop.resolve takes { logEntryId, decision: "accept"|"reject"|"cancel", body?, outcome? }.
--
-- EDIT: opens a diffsplit — left = disk content, right = post-patch content.
--   <localleader>a  accept-as-proposed (send original udiff)
--   <localleader>e  accept-with-edits  (regenerate udiff from right buffer)
--   r               reject
--   c               cancel
--
-- EXEC: opens a scratch buffer showing the command.
--   a r c           accept / reject / cancel  (no edit)

local M = {}
local client = require("plurnk.client")
local diff = require("plurnk.diff")
local patch_mod = require("plurnk.patch")

-- Pending-proposal stack. Each entry: { workspace_name, proposal, focus(), accept_as_proposed(), accept_with_edits(), reject(), cancel() }.
-- index tracks which proposal :PlurnkNext / :PlurnkPrev are pointing at.
local stack = {}
local index = 0

local function notify(text, level)
  pcall(client.notify, text, level or vim.log.levels.INFO)
end

local function current() return stack[index] end

M.pending_count = function() return #stack end
M.current_index = function() return index end

M.next = function()
  if #stack == 0 then notify("No pending proposals", vim.log.levels.WARN); return end
  index = (index % #stack) + 1
  local entry = current()
  if entry and entry.focus then entry.focus() end
end

M.prev = function()
  if #stack == 0 then notify("No pending proposals", vim.log.levels.WARN); return end
  index = ((index - 2) % #stack) + 1
  local entry = current()
  if entry and entry.focus then entry.focus() end
end

local function pop_current()
  if index < 1 or index > #stack then return end
  table.remove(stack, index)
  if #stack == 0 then index = 0
  elseif index > #stack then index = #stack end
end

local function dispatch_to_current(method)
  local entry = current()
  if not entry then notify("No pending proposal", vim.log.levels.WARN); return end
  local fn = entry[method]
  if fn then fn() end
end

M.accept         = function() dispatch_to_current("accept_as_proposed") end
M.accept_edits   = function() dispatch_to_current("accept_with_edits") end
M.reject         = function() dispatch_to_current("reject") end
M.cancel_current = function() dispatch_to_current("cancel") end

M.cancel_all = function()
  if #stack == 0 then return 0 end
  local n = 0
  while #stack > 0 do
    local entry = stack[1]
    if entry and entry.cancel then entry.cancel() end
    n = n + 1
  end
  index = 0
  return n
end

local function send_resolve(log_entry_id, decision, opts)
  local params = { logEntryId = log_entry_id, decision = decision }
  if opts then
    if opts.body then params.body = opts.body end
    if opts.outcome then params.outcome = opts.outcome end
  end
  client.send("loop.resolve", params)
end

local function fs_read_lines(path)
  if vim.fn.filereadable(path) ~= 1 then return {} end
  return vim.fn.readfile(path)
end

local function make_scratch(name, lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
  if name then pcall(vim.api.nvim_buf_set_name, buf, name) end
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  if ft and ft ~= "" then vim.bo[buf].filetype = ft end
  return buf
end

-- ── EDIT proposal: diffsplit ──────────────────────────────────────────

local function review_edit(workspace_name, proposal)
  local target = proposal.target or {}
  local pathname = target.pathname or ""
  local abs_path = pathname ~= "" and vim.fn.fnamemodify(pathname, ":p") or pathname
  local original_lines = fs_read_lines(abs_path)
  local original_content = table.concat(original_lines, "\n") .. (#original_lines > 0 and "\n" or "")

  local proposed_content, err = patch_mod.apply_patch(original_content, proposal.body or "")
  local proposed_lines
  if proposed_content then
    proposed_lines = vim.split(proposed_content, "\n")
    if #proposed_lines > 0 and proposed_lines[#proposed_lines] == "" then
      table.remove(proposed_lines)
    end
  else
    notify("Patch preview failed: " .. tostring(err), vim.log.levels.WARN)
    proposed_lines = vim.split(proposal.body or "", "\n")
  end

  local ft = vim.filetype.match({ filename = pathname }) or ""
  local tail = vim.fn.fnamemodify(pathname, ":t")
  if tail == "" then tail = "proposal" end

  vim.cmd("botright vsplit")
  local left_buf = make_scratch("plurnk-nvim://disk/" .. tail, original_lines, ft)
  vim.api.nvim_win_set_buf(0, left_buf)
  local left_win = vim.api.nvim_get_current_win()
  vim.cmd("diffthis")

  vim.cmd("rightbelow vsplit")
  local right_buf = make_scratch("plurnk-nvim://proposed/" .. tail, proposed_lines, ft)
  vim.api.nvim_win_set_buf(0, right_buf)
  local right_win = vim.api.nvim_get_current_win()
  vim.cmd("diffthis")

  vim.api.nvim_set_current_win(left_win)

  local winbar = string.format(
    " proposal EDIT %s · <localleader>a accept · <localleader>e accept-with-edits · r reject · c cancel",
    pathname)
  pcall(vim.api.nvim_set_option_value, "winbar", winbar, { win = left_win })
  pcall(vim.api.nvim_set_option_value, "winbar", winbar, { win = right_win })

  local closed = false
  local function cleanup()
    if closed then return end
    closed = true
    for _, w in ipairs({ left_win, right_win }) do
      if vim.api.nvim_win_is_valid(w) then pcall(vim.api.nvim_win_close, w, true) end
    end
    for _, b in ipairs({ left_buf, right_buf }) do
      if vim.api.nvim_buf_is_valid(b) then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
    end
    if workspace_name then
      require("plurnk.state").remove_proposal(workspace_name, proposal.logEntryId)
    end
    for i, e in ipairs(stack) do
      if e.proposal.logEntryId == proposal.logEntryId then
        table.remove(stack, i)
        if index > #stack then index = #stack end
        break
      end
    end
  end

  local function focus()
    if vim.api.nvim_win_is_valid(left_win) then
      vim.api.nvim_set_current_win(left_win)
    end
  end

  local function accept_as_proposed()
    send_resolve(proposal.logEntryId, "accept")
    cleanup()
  end

  local function accept_with_edits()
    local edited_lines = vim.api.nvim_buf_get_lines(right_buf, 0, -1, false)
    local edited_text = table.concat(edited_lines, "\n") .. "\n"
    -- Regenerate a unified diff against the original disk content.
    local ok, regen = pcall(vim.diff, original_content, edited_text, {
      result_type = "unified",
      ctxlen = 3,
    })
    if not ok or type(regen) ~= "string" or regen == "" then
      notify("No changes vs. disk — rejecting instead", vim.log.levels.WARN)
      send_resolve(proposal.logEntryId, "reject", { outcome = "no_diff_after_edits" })
      cleanup()
      return
    end
    send_resolve(proposal.logEntryId, "accept", { body = regen })
    cleanup()
  end

  local function reject() send_resolve(proposal.logEntryId, "reject"); cleanup() end
  local function cancel() send_resolve(proposal.logEntryId, "cancel"); cleanup() end

  for _, b in ipairs({ left_buf, right_buf }) do
    vim.keymap.set("n", "<localleader>a", accept_as_proposed, { buffer = b, nowait = true })
    vim.keymap.set("n", "<localleader>e", accept_with_edits, { buffer = b, nowait = true })
    vim.keymap.set("n", "r", reject, { buffer = b, nowait = true })
    vim.keymap.set("n", "c", cancel, { buffer = b, nowait = true })
  end

  table.insert(stack, {
    workspace_name = workspace_name,
    proposal = proposal,
    focus = focus,
    accept_as_proposed = accept_as_proposed,
    accept_with_edits = accept_with_edits,
    reject = reject,
    cancel = cancel,
  })
  index = #stack
end

-- ── EXEC proposal: scratch buffer ────────────────────────────────────

local function review_exec(workspace_name, proposal)
  local body = proposal.body or ""
  local lines = {
    string.format("── EXEC proposal %s ──", proposal.target and proposal.target.pathname or "(no target)"),
    "",
  }
  for chunk in (body .. "\n"):gmatch("([^\n]*)\n") do lines[#lines+1] = chunk end
  if lines[#lines] == "" then table.remove(lines) end
  lines[#lines+1] = ""
  lines[#lines+1] = "[a]ccept · [r]eject · [c]ancel"

  vim.cmd("botright split")
  local buf = make_scratch("plurnk-nvim://exec/" .. tostring(proposal.logEntryId), lines, "sh")
  vim.api.nvim_win_set_buf(0, buf)
  local win = vim.api.nvim_get_current_win()

  local function cleanup()
    if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
    if workspace_name then
      require("plurnk.state").remove_proposal(workspace_name, proposal.logEntryId)
    end
    for i, e in ipairs(stack) do
      if e.proposal.logEntryId == proposal.logEntryId then
        table.remove(stack, i)
        if index > #stack then index = #stack end
        break
      end
    end
  end

  local accept_as_proposed = function() send_resolve(proposal.logEntryId, "accept"); cleanup() end
  local reject = function() send_resolve(proposal.logEntryId, "reject"); cleanup() end
  local cancel = function() send_resolve(proposal.logEntryId, "cancel"); cleanup() end
  local focus = function() if vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end end

  vim.keymap.set("n", "a", accept_as_proposed, { buffer = buf, nowait = true })
  vim.keymap.set("n", "r", reject, { buffer = buf, nowait = true })
  vim.keymap.set("n", "c", cancel, { buffer = buf, nowait = true })

  table.insert(stack, {
    workspace_name = workspace_name,
    proposal = proposal,
    focus = focus,
    accept_as_proposed = accept_as_proposed,
    -- EXEC has no edit semantics — accept-with-edits falls through to accept.
    accept_with_edits = accept_as_proposed,
    reject = reject,
    cancel = cancel,
  })
  index = #stack
end

-- ── SEND[300] questions (#346) ───────────────────────────────────────
-- A question rides the SAME proposal lifecycle (world-stopped; answer via
-- loop.resolve body), but is a SEND carrying attrs {question, choices} (choices
-- absent/empty = open question). Detection is pure so it's testable.
M.question_from_proposal = function(proposal)
  if not proposal or proposal.op ~= "SEND" then return nil end
  local a = proposal.attrs
  if type(a) ~= "table" or type(a.question) ~= "string" then return nil end
  local choices = {}
  if type(a.choices) == "table" then
    for _, c in ipairs(a.choices) do if type(c) == "string" then choices[#choices + 1] = c end end
  end
  return { question = a.question, choices = choices }
end

-- Render the question and collect by picking or typing. vim.ui.select for the
-- choices (+ an always-present Free Response escape to reject the premise);
-- vim.ui.input for the free text and for open questions. The answer resolves the
-- world-stopped proposal via loop.resolve body. Dismiss = leave pending (the
-- daemon's proposal timeout / a re-review still applies) — never auto-answered.
local function review_question(workspace_name, proposal, q)
  local cleanup = function() require("plurnk.state").remove_proposal(workspace_name, proposal.logEntryId) end
  local function free_response()
    vim.ui.input({ prompt = q.question .. " (Free Response): " }, function(input)
      if input == nil or input == "" then return end
      send_resolve(proposal.logEntryId, "accept", { body = input }); cleanup()
    end)
  end
  if #q.choices == 0 then free_response(); return end
  local items = vim.list_extend({}, q.choices)
  items[#items + 1] = "Free Response…"
  vim.ui.select(items, { prompt = q.question }, function(choice)
    if choice == nil then return end
    if choice == "Free Response…" then free_response(); return end
    send_resolve(proposal.logEntryId, "accept", { body = choice }); cleanup()
  end)
end

-- ── Entry point ──────────────────────────────────────────────────────

M.process = function(workspace_name, proposal)
  if not proposal or not proposal.logEntryId then return end

  -- A SEND[300] question is checked BEFORE yolo: even a yolo loop stops the world
  -- for a human — never auto-answered (#346).
  local q = M.question_from_proposal(proposal)
  if q then
    review_question(workspace_name, proposal, q)
    return
  end

  if diff.is_yolo() then
    send_resolve(proposal.logEntryId, "accept", { outcome = "client_yolo" })
    return
  end

  if proposal.op == "EDIT" then
    review_edit(workspace_name, proposal)
  else
    -- EXEC and any future op kind that needs review fall through to the
    -- scratch-buffer reviewer; it's a fail-safe shape (no patch parse).
    review_exec(workspace_name, proposal)
  end
end

return M
