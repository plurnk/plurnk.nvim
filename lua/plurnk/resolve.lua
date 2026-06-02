-- Proposal review (loop/proposal → loop.resolve).
--
-- Wire (plurnk-grammar 0.17): the proposal payload carries
--   { logEntryId, loopId, turnId, op, target {scheme, pathname}, body, attrs }
-- where `body` is a udiff for EDIT and a shell command for EXEC.
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

local function notify(text, level)
  pcall(client.notify, text, level or vim.log.levels.INFO)
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

local function review_edit(session_name, proposal)
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
  local left_buf = make_scratch("plurnk://disk/" .. tail, original_lines, ft)
  vim.api.nvim_win_set_buf(0, left_buf)
  local left_win = vim.api.nvim_get_current_win()
  vim.cmd("diffthis")

  vim.cmd("rightbelow vsplit")
  local right_buf = make_scratch("plurnk://proposed/" .. tail, proposed_lines, ft)
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
    if session_name then
      require("plurnk.state").remove_proposal(session_name, proposal.logEntryId)
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
end

-- ── EXEC proposal: scratch buffer ────────────────────────────────────

local function review_exec(session_name, proposal)
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
  local buf = make_scratch("plurnk://exec/" .. tostring(proposal.logEntryId), lines, "sh")
  vim.api.nvim_win_set_buf(0, buf)

  local function cleanup()
    if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
    if session_name then
      require("plurnk.state").remove_proposal(session_name, proposal.logEntryId)
    end
  end

  vim.keymap.set("n", "a", function() send_resolve(proposal.logEntryId, "accept"); cleanup() end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "r", function() send_resolve(proposal.logEntryId, "reject"); cleanup() end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "c", function() send_resolve(proposal.logEntryId, "cancel"); cleanup() end, { buffer = buf, nowait = true })
end

-- ── Entry point ──────────────────────────────────────────────────────

M.process = function(session_name, proposal)
  if not proposal or not proposal.logEntryId then return end

  if diff.is_yolo() then
    send_resolve(proposal.logEntryId, "accept", { outcome = "client_yolo" })
    return
  end

  if proposal.op == "EDIT" then
    review_edit(session_name, proposal)
  else
    -- EXEC and any future op kind that needs review fall through to the
    -- scratch-buffer reviewer; it's a fail-safe shape (no patch parse).
    review_exec(session_name, proposal)
  end
end

return M
