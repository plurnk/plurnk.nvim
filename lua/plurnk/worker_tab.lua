-- Worker-tab UI scaffold — worker-keyed.
--
-- The log is the worker's history, so the
-- waterfall is a worker's buffer: `plurnk-nvim://<workspace>/<worker-label>`, with a
-- matching input split below. Tabs are the default view (one per worker);
-- buffers are the unit of content, so users can compose other layouts
-- with vim's own window machinery.
--
-- workspace.create doesn't return the auto-created worker's id, so a fresh
-- workspace opens under a pending key; the worker id is learned from the
-- first log/entry (entries carry worker_id) or a workspace.workers round-trip,
-- and the record is adopted — rekeyed, buffer renamed, winbar refreshed.

local M = {}

-- records[workspace][key] = {
--   buf, worker_id?, tabpage?, waterfall_win?, input_win?, input_buf?,
-- }  where key = worker_id (number) | "pending".
local records = {}
local reproject_record
local waterfall_width

local function workspace_records(workspace)
  records[workspace] = records[workspace] or {}
  return records[workspace]
end

local function worker_label(workspace, worker_id)
  if not worker_id then return "pending" end
  local label = require("plurnk.state").get_worker_label(workspace, worker_id)
  return label or ("worker#" .. worker_id)
end

local function buffer_title(workspace, key)
  local rid = type(key) == "number" and key or nil
  return "plurnk-nvim://" .. workspace .. "/" .. worker_label(workspace, rid)
end

-- The winbar is plurnk's OWN window header — its real estate, so the rich
-- detail lives here (identity + authoritative status + loop accounting), NOT in
-- the user's shared statusline. Reactive: refresh_winbar re-renders
-- it on each notification so the live state stays current (operator, 2026-06-20).
local function fmt_count(n)
  if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
  if n >= 1000 then return string.format("%.1fk", n / 1000) end
  return tostring(n)
end

local function fmt_token(n)
  return type(n) == "number" and fmt_count(n) or "?"
end

local function is_zero_decimal(value)
  return value == "0" or (type(value) == "string" and value:match("^0%.0+$") ~= nil)
end

local function gauge(label, used, capacity)
  if type(used) ~= "number" or type(capacity) ~= "number" or capacity <= 0 then return nil end
  local compact = capacity >= 1000 and string.format("%dk", math.floor(capacity / 1000 + 0.5)) or tostring(capacity)
  return string.format("%s %d%%/%s", label, math.floor(used / capacity * 100 + 0.5), compact)
end

local function create_block_fold(rec, block)
  if not block or not block.fold or not block.first or not block.last or block.first >= block.last
      or not rec.waterfall_win or not vim.api.nvim_win_is_valid(rec.waterfall_win) then return end
  vim.api.nvim_win_call(rec.waterfall_win, function()
    pcall(vim.cmd, string.format("%d,%dfold", block.first, block.last))
    pcall(vim.cmd, string.format("%dfoldclose", block.first))
    if block.open then pcall(vim.cmd, string.format("%dfoldopen", block.first)) end
  end)
end

local function build_winbar(workspace, key)
  local state = require("plurnk.state")
  local rid = type(key) == "number" and key or nil
  -- {§nvim-worker-hops} — where this tab is in the tree, then whose it is.
  local parts = { "plurnk · " .. workspace .. " · " .. require("plurnk.workers").position_label(workspace) .. " " .. worker_label(workspace, rid) }

  local runtime = state.get_runtime_status(workspace)
  local transport = state.get_transport_status(workspace)
  if transport and transport.phase == "reconnecting" then
    parts[#parts + 1] = "↻ reconnecting"
  elseif transport and transport.phase == "stale" then
    parts[#parts + 1] = "⚠ stale"
  else
    local lifecycle = runtime and require("plurnk.runtime_status").lifecycle_glyph(runtime.lifecycle) or ""
    if lifecycle ~= "" then parts[#parts + 1] = lifecycle end
  end

  local model = runtime and runtime.model or state.get_active_model(workspace)
  if model then parts[#parts + 1] = "🤖 " .. model end
  if runtime then parts[#parts + 1] = "P" .. tostring(runtime.packet_count) end
  -- The ant is the daemon's count of alive direct children ({§nvim-status-children}).
  if runtime and runtime.children ~= nil then parts[#parts + 1] = "🐜" .. tostring(runtime.children) end

  local reasoning = state.get_reasoning_policy(workspace)
  if reasoning then parts[#parts + 1] = "🧠 " .. reasoning end

  -- The daemon's conventional aggregate for the LAST loop, not a client tally.
  local usage = state.get_usage(workspace)
  local accounting = type(usage) == "table" and type(usage.accounting) == "table" and usage.accounting or nil
  if accounting then
    local aggregate = type(accounting.usage) == "table" and accounting.usage or nil
    parts[#parts + 1] = "↑" .. fmt_token(aggregate and aggregate.inputTokens)
      .. " ↓" .. fmt_token(aggregate and aggregate.outputTokens)
  end

  -- Curation pressure and physical context occupancy are independent gauges
  -- from this loop's terminal envelope. Never compare weight with tokens or
  -- infer capacity from the current alias; the loop may have used another model.
  local curation = gauge("cur", usage and usage.curationWeight, usage and usage.curationBudget)
  if curation then parts[#parts + 1] = curation end
  local context = gauge("ctx", usage and usage.contextTokens, usage and usage.contextCapacity)
  if context then parts[#parts + 1] = context end

  local loop_cost = accounting and accounting.costUsd
  if type(loop_cost) == "string" and not is_zero_decimal(loop_cost) then
    parts[#parts + 1] = "loop: $" .. loop_cost
  elseif accounting and loop_cost == nil and type(accounting.requests) == "table" and #accounting.requests > 0 then
    parts[#parts + 1] = "loop: $unknown"
  end

  return " " .. table.concat(parts, " · ") .. " "
end

local function decorate_waterfall_win(win, workspace, key)
  vim.wo[win].wrap = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = false
  vim.wo[win].scrolloff = 3
  vim.wo[win].foldmethod = "manual"
  vim.wo[win].foldenable = true
  vim.wo[win].foldlevel = 0
  vim.wo[win].foldtext = "v:lua.require'plurnk.worker_tab'.foldtext()"
  local rec = workspace_records(workspace)[key]
  if rec and rec.block_fold_win ~= win then
    rec.block_fold_win = win
    for _, block in ipairs(rec.blocks or {}) do
      create_block_fold(rec, block)
    end
  end
  pcall(vim.api.nvim_set_option_value, "winbar", build_winbar(workspace, key), { win = win })
end

-- The rendered winbar string for a workspace/worker — pure over state, exposed so
-- specs can assert the rich header without a real window.
M.winbar_text = function(workspace, key)
  return build_winbar(workspace, key)
end

-- Re-render the winbar for a workspace's open waterfall window(s) — called from
-- dispatch on each state-changing notification so status and accounting
-- stay current without a statusline round-trip.
M.refresh_winbar = function(workspace)
  local recs = records[workspace]
  if not recs then return end
  for key, rec in pairs(recs) do
    if rec.waterfall_win and vim.api.nvim_win_is_valid(rec.waterfall_win) then
      pcall(vim.api.nvim_set_option_value, "winbar", build_winbar(workspace, key), { win = rec.waterfall_win })
    end
  end
end

local function ensure_record(workspace, key)
  local recs = workspace_records(workspace)
  local rec = recs[key]
  if rec and rec.waterfall_buf and vim.api.nvim_buf_is_valid(rec.waterfall_buf) then return rec end
  local buf = vim.api.nvim_create_buf(true, true)
  pcall(vim.api.nvim_buf_set_name, buf, buffer_title(workspace, key))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  -- The waterfall is not one Markdown document. Model bodies are projected
  -- independently so their syntax state can never style Plurnk control rows.
  vim.bo[buf].syntax = ""
  vim.b[buf].plurnk_workspace = workspace
  if type(key) == "number" then vim.b[buf].plurnk_worker_id = key end
  rec = rec or {}
  rec.waterfall_buf = buf
  rec.worker_id = type(key) == "number" and key or nil
  rec.reasoning_ids = rec.reasoning_ids or {}
  rec.blocks = rec.blocks or {}
  rec.reasoning_live = rec.reasoning_live or {}
  recs[key] = rec
  return rec
end

-- The record for a worker, adopting the workspace's pending record when this
-- worker id is first seen (rekey + rename + restamp buffer vars + winbar).
local function record_for_worker(workspace, worker_id)
  local recs = workspace_records(workspace)
  -- First worker id seen claims "current" when the workspace has none — the
  -- earliest entries come from the worker this connection is bound to.
  local state = require("plurnk.state")
  if state.get_worker_id(workspace) == nil then state.set_worker_id(workspace, worker_id) end
  if recs[worker_id] then return recs[worker_id] end
  local pending = recs.pending
  if pending then
    recs.pending = nil
    recs[worker_id] = pending
    pending.worker_id = worker_id
    if pending.waterfall_buf and vim.api.nvim_buf_is_valid(pending.waterfall_buf) then
      vim.b[pending.waterfall_buf].plurnk_worker_id = worker_id
      local old_name = vim.api.nvim_buf_get_name(pending.waterfall_buf)
      pcall(vim.api.nvim_buf_set_name, pending.waterfall_buf, buffer_title(workspace, worker_id))
      -- Renaming leaves an unlisted ghost buffer under the old name —
      -- wipe it or name-based lookups find an empty impostor.
      local ghost = vim.fn.bufnr(old_name)
      if ghost ~= -1 and ghost ~= pending.waterfall_buf then
        pcall(vim.api.nvim_buf_delete, ghost, { force = true })
      end
    end
    if pending.input_buf and vim.api.nvim_buf_is_valid(pending.input_buf) then
      vim.b[pending.input_buf].plurnk_worker_id = worker_id
    end
    if pending.waterfall_win and vim.api.nvim_win_is_valid(pending.waterfall_win) then
      decorate_waterfall_win(pending.waterfall_win, workspace, worker_id)
    end
    return pending
  end
  return ensure_record(workspace, worker_id)
end

-- Called when the workspace's current worker id resolves (workspace.workers after
-- create, or an attach) so the pending record adopts without waiting
-- for a log/entry.
M.note_worker_resolved = function(workspace)
  local worker_id = require("plurnk.state").get_worker_id(workspace)
  if not worker_id then return end
  if workspace_records(workspace).pending then record_for_worker(workspace, worker_id) end
end

M.current_alias = function()
  return vim.b[vim.api.nvim_get_current_buf()].plurnk_workspace
end

local function tab_valid(rec)
  return rec and rec.tabpage and vim.api.nvim_tabpage_is_valid(rec.tabpage)
end

-- The workspace's current-worker record (or its pending one). Used by specs
-- and the input module.
M.get_record = function(workspace)
  local recs = workspace_records(workspace)
  local worker_id = require("plurnk.state").get_worker_id(workspace)
  local rec = (worker_id and recs[worker_id]) or recs.pending
  if rec and rec.tabpage and not vim.api.nvim_tabpage_is_valid(rec.tabpage) then
    rec.tabpage = nil
  end
  return rec
end

-- Rekey a workspace's tab records to a new name and
-- refresh buffer titles + winbars in place. The workspace is the world; its name
-- is a mutable handle, so its open tab follows the rename rather than orphaning.
M.rename = function(old_workspace, new_workspace)
  if not old_workspace or not new_workspace or old_workspace == new_workspace then return end
  local recs = records[old_workspace]
  if not recs then return end
  records[new_workspace] = recs
  records[old_workspace] = nil
  local rename_buf = function(buf, new_name)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
    local old_name = vim.api.nvim_buf_get_name(buf)
    if old_name == new_name then return end
    pcall(vim.api.nvim_buf_set_name, buf, new_name)
    -- Renaming leaves an unlisted ghost under the old name — wipe it so
    -- name-based lookups don't find an empty impostor (same as adoption).
    local ghost = vim.fn.bufnr(old_name)
    if ghost ~= -1 and ghost ~= buf then pcall(vim.api.nvim_buf_delete, ghost, { force = true }) end
  end
  for key, rec in pairs(recs) do
    for _, b in ipairs({ rec.waterfall_buf, rec.input_buf }) do
      if b and vim.api.nvim_buf_is_valid(b) then vim.b[b].plurnk_workspace = new_workspace end
    end
    rename_buf(rec.waterfall_buf, buffer_title(new_workspace, key))
    -- The input buffer's URI carries the workspace too — follow the rename, or
    -- the tab/statusline keeps showing plurnk-nvim://input/<old>/… (operator).
    rename_buf(rec.input_buf, require("plurnk.input").buffer_name(new_workspace, rec.worker_id))
    if rec.waterfall_win and vim.api.nvim_win_is_valid(rec.waterfall_win) then
      decorate_waterfall_win(rec.waterfall_win, new_workspace, key)
    end
  end
end

-- Which workspace owns this tabpage, if any (any worker's tab counts).
M.workspace_for_tabpage = function(tabpage)
  for workspace, recs in pairs(records) do
    for _, rec in pairs(recs) do
      if rec.tabpage == tabpage and vim.api.nvim_tabpage_is_valid(tabpage) then
        return workspace
      end
    end
  end
  return nil
end

-- {§nvim-active-worker} — the worker a tabpage is bound to: its workspace and worker id, or nil
-- for a tab that is not a worker tab (a pending record has no worker yet).
M.binding_for_tabpage = function(tabpage)
  for workspace, recs in pairs(records) do
    for key, rec in pairs(recs) do
      if rec.tabpage == tabpage and vim.api.nvim_tabpage_is_valid(tabpage) and type(key) == "number" then
        return workspace, key
      end
    end
  end
  return nil
end

-- {§nvim-active-worker} — entering a worker tab makes its worker the workspace's active worker: the
-- one every plurnk command speaks to, from inside the tab or from any other buffer, until the user
-- enters another worker tab. Nothing is inferred; the binding is the tab's own record.
M.activate_current_tab = function()
  local workspace, worker_id = M.binding_for_tabpage(vim.api.nvim_get_current_tabpage())
  if not workspace then return nil end
  local state = require("plurnk.state")
  state.set_active_workspace_name(workspace)
  if state.get_worker_id(workspace) ~= worker_id then
    state.set_worker_id(workspace, worker_id)
    M.refresh_winbar(workspace)
  end
  pcall(vim.cmd.redrawstatus)
  return workspace, worker_id
end

-- Open (or focus) the tab for a worker — defaults to the workspace's current
-- worker (pending when the id isn't known yet). Focuses the input split.
M.open = function(workspace, worker_id)
  if not workspace then return end
  worker_id = worker_id or require("plurnk.state").get_worker_id(workspace)
  local key = worker_id or "pending"
  if worker_id then record_for_worker(workspace, worker_id) end
  local rec = ensure_record(workspace, key)

  if tab_valid(rec) then
    vim.api.nvim_set_current_tabpage(rec.tabpage)
    if rec.input_win and vim.api.nvim_win_is_valid(rec.input_win) then
      vim.api.nvim_set_current_win(rec.input_win)
    end
    return
  end

  vim.cmd("tabnew")
  rec.tabpage = vim.api.nvim_get_current_tabpage()
  rec.waterfall_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(rec.waterfall_win, rec.waterfall_buf)
  decorate_waterfall_win(rec.waterfall_win, workspace, key)
  if rec.render_width ~= waterfall_width(rec) then reproject_record(rec) end

  local total = vim.api.nvim_buf_line_count(rec.waterfall_buf)
  pcall(vim.api.nvim_win_set_cursor, rec.waterfall_win, { math.max(total, 1), 0 })

  rec.input_buf, rec.input_win = require("plurnk.input").create_in_tab(workspace, rec.worker_id)
end

local function autoscroll(rec)
  if not rec.waterfall_win or not vim.api.nvim_win_is_valid(rec.waterfall_win) then return end
  local total = vim.api.nvim_buf_line_count(rec.waterfall_buf)
  pcall(vim.api.nvim_win_set_cursor, rec.waterfall_win, { math.max(total, 1), 0 })
end

-- Append-or-replace: replace the initial empty line on the first write.
local function write_lines(buf, lines, replace_all)
  vim.bo[buf].modifiable = true
  local first
  if replace_all then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    first = 1
  else
    local current = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if #current == 1 and current[1] == "" then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      first = 1
    else
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
      first = #current + 1
    end
  end
  vim.bo[buf].modifiable = false
  return first, first + #lines - 1
end

waterfall_width = function(rec)
  if rec.waterfall_win and vim.api.nvim_win_is_valid(rec.waterfall_win) then
    return vim.api.nvim_win_get_width(rec.waterfall_win)
  end
  return vim.o.columns
end

local function is_answer(entry)
  return (entry.op == "DONE" or entry.op == "FAIL") and entry.origin == "model"
end

local function schedule_reproject(rec)
  if rec.reproject_scheduled then return end
  rec.reproject_scheduled = true
  vim.schedule(function()
    rec.reproject_scheduled = nil
    if rec.waterfall_buf and vim.api.nvim_buf_is_valid(rec.waterfall_buf) then reproject_record(rec) end
  end)
end

local function render_block(rec, block)
  if block.kind == "entry" then
    return require("plurnk.render").render_log_block(
      block.entry,
      waterfall_width(rec),
      function() schedule_reproject(rec) end
    )
  end
  if block.kind == "reasoning" then
    return { lines = require("plurnk.render").render_reasoning(block.content) }
  end
  return { lines = vim.split(block.text or "", "\n", { plain = true }) }
end

local function block_foldable(block, content)
  if #(content.lines or {}) < 2 then return false end
  if block.kind == "entry" then return not is_answer(block.entry) end
  return block.kind == "reasoning" and block.complete == true
end

local function append_block(rec, block)
  rec.blocks = rec.blocks or {}
  if not block.registered then
    rec.blocks[#rec.blocks + 1] = block
    block.registered = true
  end
  local content = render_block(rec, block)
  if #content.lines == 0 then return end
  block.first, block.last = write_lines(rec.waterfall_buf, content.lines)
  block.fold = block_foldable(block, content)
  block.open = false
  create_block_fold(rec, block)
end

local function capture_fold_states(rec)
  if not rec.waterfall_win or not vim.api.nvim_win_is_valid(rec.waterfall_win) then return end
  vim.api.nvim_win_call(rec.waterfall_win, function()
    for _, block in ipairs(rec.blocks or {}) do
      if block.fold and block.first then block.open = vim.fn.foldclosed(block.first) == -1 end
    end
  end)
end

reproject_record = function(rec)
  if not rec.waterfall_buf or not vim.api.nvim_buf_is_valid(rec.waterfall_buf) then return end
  capture_fold_states(rec)
  local view, at_bottom
  if rec.waterfall_win and vim.api.nvim_win_is_valid(rec.waterfall_win) then
    vim.api.nvim_win_call(rec.waterfall_win, function()
      view = vim.fn.winsaveview()
      at_bottom = view.lnum >= vim.api.nvim_buf_line_count(rec.waterfall_buf)
      pcall(vim.cmd, "silent! normal! zE")
    end)
  end

  local all_lines = {}
  for _, block in ipairs(rec.blocks or {}) do
    local content = render_block(rec, block)
    block.first = #all_lines + 1
    for _, line in ipairs(content.lines or {}) do all_lines[#all_lines + 1] = line end
    block.last = #all_lines
    block.fold = block_foldable(block, content)
  end

  write_lines(rec.waterfall_buf, #all_lines > 0 and all_lines or { "" }, true)
  for _, block in ipairs(rec.blocks or {}) do create_block_fold(rec, block) end
  rec.render_width = waterfall_width(rec)

  if rec.waterfall_win and vim.api.nvim_win_is_valid(rec.waterfall_win) then
    vim.api.nvim_win_call(rec.waterfall_win, function()
      if at_bottom then
        pcall(vim.api.nvim_win_set_cursor, rec.waterfall_win,
          { math.max(vim.api.nvim_buf_line_count(rec.waterfall_buf), 1), 0 })
      elseif view then
        vim.fn.winrestview(view)
      end
    end)
  end
end

local function replace_block(rec, block)
  if rec.blocks[#rec.blocks] ~= block then
    reproject_record(rec)
    return
  end
  local content = render_block(rec, block)
  local first = block.first
  if not first then
    append_block(rec, block)
    return
  end
  vim.bo[rec.waterfall_buf].modifiable = true
  vim.api.nvim_buf_set_lines(rec.waterfall_buf, first - 1, block.last, false, content.lines)
  vim.bo[rec.waterfall_buf].modifiable = false
  block.last = first + #content.lines - 1
  block.fold = block_foldable(block, content)
end

-- Append entries, each routed to ITS worker's buffer by entry.worker_id —
-- never interleave workers in one waterfall (the model sees one worker's log;
-- so should the user). Entries without worker_id land on the current worker.
M.append_history = function(workspace, entries)
  if not workspace or not entries or #entries == 0 then return end
  local by_rec = {}
  for _, entry in ipairs(entries) do
    local rec
    if type(entry.worker_id) == "number" then
      rec = record_for_worker(workspace, entry.worker_id)
    else
      rec = M.get_record(workspace) or ensure_record(workspace, "pending")
    end
    by_rec[rec] = by_rec[rec] or {}
    table.insert(by_rec[rec], entry)
  end
  for rec, worker_entries in pairs(by_rec) do
    -- Auto-folding: every multi-line block folds closed on
    -- arrival — except the model's broadcast answer, which stays open as the
    -- conversation's payoff. Folds persist per record and are recreated when
    -- the window re-decorates; the user reopens any block with ordinary
    -- fold motions (za / zR).
    for _, entry in ipairs(worker_entries) do
      append_block(rec, { kind = "entry", entry = entry })
    end
    autoscroll(rec)
  end
end

local function reasoning_record(workspace, worker_id)
  return type(worker_id) == "number" and record_for_worker(workspace, worker_id)
    or M.get_record(workspace) or ensure_record(workspace, "pending")
end

M.begin_reasoning = function(workspace, worker_id, message_id)
  if not workspace or type(message_id) ~= "string" then return end
  local rec = reasoning_record(workspace, worker_id)
  rec.reasoning_ids = rec.reasoning_ids or {}
  rec.reasoning_live = rec.reasoning_live or {}
  if rec.reasoning_ids[message_id] then return end
  if rec.reasoning_live[message_id] ~= nil then error("reasoning message started twice: " .. message_id, 0) end
  rec.reasoning_live[message_id] = {
    content = "",
    block = { kind = "reasoning", content = "", complete = false },
  }
end

M.append_reasoning_delta = function(workspace, worker_id, message_id, delta)
  if not workspace or type(message_id) ~= "string" or type(delta) ~= "string" then return end
  if delta == "" then return end
  local rec = reasoning_record(workspace, worker_id)
  if rec.reasoning_ids and rec.reasoning_ids[message_id] then return end
  local live = rec.reasoning_live and rec.reasoning_live[message_id]
  if live == nil then error("reasoning content arrived before its start: " .. message_id, 0) end
  live.content = live.content .. delta
  live.block.content = live.content
  if live.block.first == nil then
    append_block(rec, live.block)
  else
    replace_block(rec, live.block)
  end
  autoscroll(rec)
end

M.end_reasoning = function(workspace, worker_id, message_id)
  if not workspace or type(message_id) ~= "string" then return end
  local rec = reasoning_record(workspace, worker_id)
  if rec.reasoning_ids and rec.reasoning_ids[message_id] then return end
  local live = rec.reasoning_live and rec.reasoning_live[message_id]
  if live == nil then error("reasoning message ended before its start: " .. message_id, 0) end
  rec.reasoning_live[message_id] = nil
  rec.reasoning_ids = rec.reasoning_ids or {}
  rec.reasoning_ids[message_id] = true
  if live.block.first == nil or live.block.last == nil then return end
  live.block.complete = true
  live.block.fold = live.block.first < live.block.last
  live.block.open = false
  create_block_fold(rec, live.block)
  autoscroll(rec)
end

-- Completed replay uses the same lifecycle as live delivery.
M.append_reasoning = function(workspace, worker_id, message_id, content)
  if not workspace or type(message_id) ~= "string" or type(content) ~= "string" or content == "" then return end
  local rec = type(worker_id) == "number" and record_for_worker(workspace, worker_id)
    or M.get_record(workspace) or ensure_record(workspace, "pending")
  rec.reasoning_ids = rec.reasoning_ids or {}
  if rec.reasoning_ids[message_id] then return end
  M.begin_reasoning(workspace, worker_id, message_id)
  M.append_reasoning_delta(workspace, worker_id, message_id, content)
  M.end_reasoning(workspace, worker_id, message_id)
end

-- Replace a worker's waterfall with rendered history (log.read on switch
-- to a historical worker).
M.hydrate = function(workspace, worker_id, entries)
  if not workspace or not worker_id then return end
  local rec = record_for_worker(workspace, worker_id)
  rec.reasoning_ids = {}
  rec.blocks = {}
  rec.reasoning_live = {}
  if rec.waterfall_win and vim.api.nvim_win_is_valid(rec.waterfall_win) then
    vim.api.nvim_win_call(rec.waterfall_win, function() pcall(vim.cmd, "silent! normal! zE") end)
  end
  for _, entry in ipairs(entries or {}) do
    rec.blocks[#rec.blocks + 1] = { kind = "entry", entry = entry, registered = true }
  end
  reproject_record(rec)
  autoscroll(rec)
end

-- Free-text line (Notice headlines etc.) — current worker's waterfall.
M.append_line = function(workspace, text)
  if not workspace or not text or text == "" then return end
  local rec = M.get_record(workspace) or ensure_record(workspace, "pending")
  append_block(rec, { kind = "text", text = text })
  autoscroll(rec)
end

-- Close the current worker's tab (`:AI/clear`). Buffers persist
-- (bufhidden=hide) so reopening keeps the waterfall history.
M.close = function(workspace)
  local rec = M.get_record(workspace)
  if not rec or not tab_valid(rec) then return end
  local tabpage = rec.tabpage
  rec.tabpage = nil
  if #vim.api.nvim_list_tabpages() == 1 then return end
  local current = vim.api.nvim_get_current_tabpage()
  vim.api.nvim_set_current_tabpage(tabpage)
  vim.cmd("tabclose")
  if current ~= tabpage and vim.api.nvim_tabpage_is_valid(current) then
    vim.api.nvim_set_current_tabpage(current)
  end
end

M.close_document = function(_) end
M.update_status = function(_) end

M.foldtext = function()
  local first = vim.fn.getline(vim.v.foldstart):gsub("%s+$", "")
  local count = vim.v.foldend - vim.v.foldstart + 1
  return string.format("%s … %d lines", first, count)
end

M.setup = function()
  require("plurnk.markdown").setup()
  local group = vim.api.nvim_create_augroup("plurnk_waterfall_projection", { clear = true })
  -- {§nvim-active-worker}
  vim.api.nvim_create_autocmd("TabEnter", {
    group = group,
    callback = function() M.activate_current_tab() end,
  })
  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      for _, recs in pairs(records) do
        for _, rec in pairs(recs) do
          if rec.waterfall_win and vim.api.nvim_win_is_valid(rec.waterfall_win)
              and rec.render_width ~= waterfall_width(rec) then
            reproject_record(rec)
          end
        end
      end
    end,
  })
end

-- Test/teardown hook.
M.reset = function()
  records = {}
  require("plurnk.markdown").reset()
end

return M
