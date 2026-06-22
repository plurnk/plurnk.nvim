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

-- The winbar is plurnk's OWN window header — its real estate, so the rich
-- detail lives here (identity + model + live L·T/status + the persistent money
-- trio), NOT in the user's shared statusline. Reactive: refresh_winbar re-renders
-- it on each notification so the live state stays current (operator, 2026-06-20).
local function fmt_usd(pico) return string.format("$%.2f", pico / 1e12) end
local function fmt_count(n)
  if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
  if n >= 1000 then return string.format("%.1fk", n / 1000) end
  return tostring(n)
end

local function build_winbar(session, key)
  local state = require("plurnk.state")
  local rid = type(key) == "number" and key or nil
  local parts = { "🐹 " .. session .. " · " .. run_label(session, rid) }

  local model = state.get_active_model(session)
  if model then parts[#parts + 1] = "🤖 " .. model end

  local loop_id = state.get_current_loop_id(session)
  local turn = state.get_current_turn(session)
  if loop_id then
    parts[#parts + 1] = turn and string.format("L%s·T%s", tostring(loop_id), tostring(turn))
      or ("L" .. tostring(loop_id))
  end

  -- ⏳ while a loop is in flight; else the last final's glyph + number.
  if state.is_loop_inflight(session) then
    parts[#parts + 1] = "⏳"
  else
    local final = state.get_final_status(session)
    if final then
      local g = require("plurnk.render").status_glyph(final)
      parts[#parts + 1] = ((g ~= "" and g) or "·") .. " " .. tostring(final)
    end
  end

  -- The LAST loop's token counts — not a session total.
  local usage = state.get_usage(session)
  if usage and (usage.prompt > 0 or usage.completion > 0) then
    parts[#parts + 1] = "↑" .. fmt_count(usage.prompt) .. " ↓" .. fmt_count(usage.completion)
  end

  -- Context-% gauge (svc#263): occupancy / the active model's window → "ctx 15%/49k".
  -- Rounded-k denominator to converge with the TUI/CLI gauge. Omitted when the
  -- provider can't report its window (contextSize null).
  local cs = state.get_active_context_size()
  if usage and type(usage.context_tokens) == "number" and type(cs) == "number" and cs > 0 then
    local k = cs >= 1000 and string.format("%dk", math.floor(cs / 1000 + 0.5)) or tostring(cs)
    parts[#parts + 1] = string.format("ctx %d%%/%s", math.floor(usage.context_tokens / cs * 100 + 0.5), k)
  end

  -- Money trio (loop | session | remaining) — daemon-sourced, each shown only
  -- when available; the client renders, never aggregates (svc#252/#254).
  local money = {}
  local loop_cost = state.get_cost_pico(session)
  if type(loop_cost) == "number" and loop_cost > 0 then money[#money + 1] = "loop: " .. fmt_usd(loop_cost) end
  local sess = state.get_session_cost_pico(session)
  if type(sess) == "number" then money[#money + 1] = "session: " .. fmt_usd(sess) end
  local bal = state.get_balance_pico(session)
  if type(bal) == "number" then money[#money + 1] = "remaining: " .. fmt_usd(bal) end
  if #money > 0 then parts[#parts + 1] = table.concat(money, " | ") end

  return " " .. table.concat(parts, " · ") .. " "
end

local function decorate_waterfall_win(win, session, key)
  vim.wo[win].wrap = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = false
  vim.wo[win].scrolloff = 3
  pcall(vim.api.nvim_set_option_value, "winbar", build_winbar(session, key), { win = win })
end

-- The rendered winbar string for a session/run — pure over state, exposed so
-- specs can assert the rich header without a real window.
M.winbar_text = function(session, key)
  return build_winbar(session, key)
end

-- Re-render the winbar for a session's open waterfall window(s) — called from
-- dispatch on each state-changing notification so the live L·T / status / money
-- stay current without a statusline round-trip.
M.refresh_winbar = function(session)
  local recs = records[session]
  if not recs then return end
  for key, rec in pairs(recs) do
    if rec.waterfall_win and vim.api.nvim_win_is_valid(rec.waterfall_win) then
      pcall(vim.api.nvim_set_option_value, "winbar", build_winbar(session, key), { win = rec.waterfall_win })
    end
  end
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

-- Rekey a session's tab records to a new name (session.rename, svc#248) and
-- refresh buffer titles + winbars in place. The session is the world; its name
-- is a mutable handle, so its open tab follows the rename rather than orphaning.
M.rename = function(old_session, new_session)
  if not old_session or not new_session or old_session == new_session then return end
  local recs = records[old_session]
  if not recs then return end
  records[new_session] = recs
  records[old_session] = nil
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
      if b and vim.api.nvim_buf_is_valid(b) then vim.b[b].plurnk_session = new_session end
    end
    rename_buf(rec.waterfall_buf, buffer_title(new_session, key))
    -- The input buffer's URI carries the session too — follow the rename, or
    -- the tab/statusline keeps showing plurnk://input/<old>/… (operator).
    rename_buf(rec.input_buf, require("plurnk.input").buffer_name(new_session, rec.run_id))
    if rec.waterfall_win and vim.api.nvim_win_is_valid(rec.waterfall_win) then
      decorate_waterfall_win(rec.waterfall_win, new_session, key)
    end
  end
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
