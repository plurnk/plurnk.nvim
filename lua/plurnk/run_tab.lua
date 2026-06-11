-- Run-tab UI scaffold — RUN-keyed (#16 topology, 2026-06-10).
--
-- The log is the RUN's history (plurnk-service SPEC §0.6), so the
-- waterfall is a run's buffer: `plurnk://<session>/<run-label>`, with a
-- matching input split below. Tabs are the DEFAULT view (one per run);
-- buffers are the unit of content, so users can compose other layouts
-- with vim's own window machinery.
--
-- session.create doesn't return the auto-created run's id, so a fresh
-- session opens under a PENDING key; the run id is learned from the
-- first log/entry (entries carry run_id) or a session.runs round-trip,
-- and the record is adopted — rekeyed, buffer renamed, winbar refreshed.

local M = {}

-- records[session][key] = {
--   buf, run_id?, tabpage?, waterfall_win?, input_win?, input_buf?,
-- }  where key = run_id (number) | "pending".
local records = {}

local function session_records(session)
  records[session] = records[session] or {}
  return records[session]
end

local function run_label(session, run_id)
  if not run_id then return "pending" end
  local label = require("plurnk.state").get_run_label(session, run_id)
  return label or ("run#" .. run_id)
end

local function buffer_title(session, key)
  local rid = type(key) == "number" and key or nil
  return "plurnk://" .. session .. "/" .. run_label(session, rid)
end

local function decorate_waterfall_win(win, session, key)
  vim.wo[win].wrap = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = false
  vim.wo[win].scrolloff = 3
  local rid = type(key) == "number" and key or nil
  pcall(vim.api.nvim_set_option_value, "winbar",
    " ⚡ " .. session .. " · " .. run_label(session, rid) .. " ", { win = win })
end

local function ensure_record(session, key)
  local recs = session_records(session)
  local rec = recs[key]
  if rec and rec.waterfall_buf and vim.api.nvim_buf_is_valid(rec.waterfall_buf) then return rec end
  local buf = vim.api.nvim_create_buf(true, true)
  pcall(vim.api.nvim_buf_set_name, buf, buffer_title(session, key))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.b[buf].plurnk_session = session
  if type(key) == "number" then vim.b[buf].plurnk_run_id = key end
  rec = rec or {}
  rec.waterfall_buf = buf
  rec.run_id = type(key) == "number" and key or nil
  recs[key] = rec
  return rec
end

-- The record for a run, adopting the session's pending record when this
-- run id is first seen (rekey + rename + restamp buffer vars + winbar).
local function record_for_run(session, run_id)
  local recs = session_records(session)
  -- First run id seen claims "current" when the session has none — the
  -- earliest entries come from the run this connection is bound to.
  local state = require("plurnk.state")
  if state.get_run_id(session) == nil then state.set_run_id(session, run_id) end
  if recs[run_id] then return recs[run_id] end
  local pending = recs.pending
  if pending then
    recs.pending = nil
    recs[run_id] = pending
    pending.run_id = run_id
    if pending.waterfall_buf and vim.api.nvim_buf_is_valid(pending.waterfall_buf) then
      vim.b[pending.waterfall_buf].plurnk_run_id = run_id
      local old_name = vim.api.nvim_buf_get_name(pending.waterfall_buf)
      pcall(vim.api.nvim_buf_set_name, pending.waterfall_buf, buffer_title(session, run_id))
      -- Renaming leaves an unlisted ghost buffer under the old name —
      -- wipe it or name-based lookups find an empty impostor.
      local ghost = vim.fn.bufnr(old_name)
      if ghost ~= -1 and ghost ~= pending.waterfall_buf then
        pcall(vim.api.nvim_buf_delete, ghost, { force = true })
      end
    end
    if pending.input_buf and vim.api.nvim_buf_is_valid(pending.input_buf) then
      vim.b[pending.input_buf].plurnk_run_id = run_id
    end
    if pending.waterfall_win and vim.api.nvim_win_is_valid(pending.waterfall_win) then
      decorate_waterfall_win(pending.waterfall_win, session, run_id)
    end
    return pending
  end
  return ensure_record(session, run_id)
end

-- Called when the session's current run id resolves (session.runs after
-- create, or an attach) so the pending record adopts without waiting
-- for a log/entry.
M.note_run_resolved = function(session)
  local run_id = require("plurnk.state").get_run_id(session)
  if not run_id then return end
  if session_records(session).pending then record_for_run(session, run_id) end
end

M.current_alias = function()
  return vim.b[vim.api.nvim_get_current_buf()].plurnk_session
end

local function tab_valid(rec)
  return rec and rec.tabpage and vim.api.nvim_tabpage_is_valid(rec.tabpage)
end

-- The session's current-run record (or its pending one). Used by specs
-- and the input module.
M.get_record = function(session)
  local recs = session_records(session)
  local run_id = require("plurnk.state").get_run_id(session)
  local rec = (run_id and recs[run_id]) or recs.pending
  if rec and rec.tabpage and not vim.api.nvim_tabpage_is_valid(rec.tabpage) then
    rec.tabpage = nil
  end
  return rec
end

-- Which session owns this tabpage, if any (any run's tab counts).
M.session_for_tabpage = function(tabpage)
  for session, recs in pairs(records) do
    for _, rec in pairs(recs) do
      if rec.tabpage == tabpage and vim.api.nvim_tabpage_is_valid(tabpage) then
        return session
      end
    end
  end
  return nil
end

-- Open (or focus) the tab for a run — defaults to the session's current
-- run (pending when the id isn't known yet). Focuses the input split.
M.open = function(session, run_id)
  if not session then return end
  run_id = run_id or require("plurnk.state").get_run_id(session)
  local key = run_id or "pending"
  if run_id then record_for_run(session, run_id) end
  local rec = ensure_record(session, key)

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
  decorate_waterfall_win(rec.waterfall_win, session, key)

  local total = vim.api.nvim_buf_line_count(rec.waterfall_buf)
  pcall(vim.api.nvim_win_set_cursor, rec.waterfall_win, { math.max(total, 1), 0 })

  rec.input_buf, rec.input_win = require("plurnk.input").create_in_tab(session, rec.run_id)
end

local function autoscroll(rec)
  if not rec.waterfall_win or not vim.api.nvim_win_is_valid(rec.waterfall_win) then return end
  local total = vim.api.nvim_buf_line_count(rec.waterfall_buf)
  pcall(vim.api.nvim_win_set_cursor, rec.waterfall_win, { math.max(total, 1), 0 })
end

-- Append-or-replace: replace the initial empty line on the first write.
local function write_lines(buf, lines, replace_all)
  vim.bo[buf].modifiable = true
  if replace_all then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  else
    local current = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if #current == 1 and current[1] == "" then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    else
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    end
  end
  vim.bo[buf].modifiable = false
end

local function render_entries(entries)
  local render = require("plurnk.render")
  local lines = {}
  for _, entry in ipairs(entries) do
    for _, ln in ipairs(render.render_log_entry(entry)) do
      lines[#lines + 1] = ln
    end
  end
  return lines
end

-- Append entries, each routed to ITS run's buffer by entry.run_id —
-- never interleave runs in one waterfall (the model sees one run's log;
-- so should the user). Entries without run_id land on the current run.
M.append_history = function(session, entries)
  if not session or not entries or #entries == 0 then return end
  local by_rec = {}
  for _, entry in ipairs(entries) do
    local rec
    if type(entry.run_id) == "number" then
      rec = record_for_run(session, entry.run_id)
    else
      rec = M.get_record(session) or ensure_record(session, "pending")
    end
    by_rec[rec] = by_rec[rec] or {}
    table.insert(by_rec[rec], entry)
  end
  for rec, run_entries in pairs(by_rec) do
    write_lines(rec.waterfall_buf, render_entries(run_entries))
    autoscroll(rec)
  end
end

-- Replace a run's waterfall with rendered history (log.read on switch
-- to a historical run).
M.hydrate = function(session, run_id, entries)
  if not session or not run_id then return end
  local rec = record_for_run(session, run_id)
  write_lines(rec.waterfall_buf, render_entries(entries or {}), true)
  autoscroll(rec)
end

-- Free-text line (telemetry headlines etc.) — current run's waterfall.
M.append_line = function(session, text)
  if not session or not text or text == "" then return end
  local rec = M.get_record(session) or ensure_record(session, "pending")
  write_lines(rec.waterfall_buf, vim.split(text, "\n", { plain = true }))
  autoscroll(rec)
end

-- Close the current run's tab (`:AI/clear`). Buffers persist
-- (bufhidden=hide) so reopening keeps the waterfall history.
M.close = function(session)
  local rec = M.get_record(session)
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
M.setup = function() end

-- Test/teardown hook.
M.reset = function()
  records = {}
end

return M
