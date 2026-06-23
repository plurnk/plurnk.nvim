-- Response and notification routing.
--
-- Plurnk is push-driven: log/entry / loop/proposal / loop/terminated /
-- telemetry/event notifications arrive with full payloads as state
-- changes — no pulse-and-pull reconciliation step is needed. (Contrast
-- with rummy, which sent content-free `run/changed` pulses and required
-- a `getEntries` round-trip to actually learn what happened.)
--
-- Per plurnk SPEC §5.1 (log/entry), §6.1 (loop/proposal), §8.6
-- (telemetry/event).

local M = {}
local state = require("plurnk.state")

-- ── Helpers ─────────────────────────────────────────────────────────

local function log(msg)
  require("plurnk.transport").log(msg)
end

local function redraw_statusline()
  vim.cmd("redrawstatus! | redrawtabline")
end

local function safe_echo(text, hl)
  if #text > 70 then text = text:sub(1, 69) .. "…" end
  pcall(vim.api.nvim_echo, {{ text, hl or "None" }}, false, {})
end

-- A log_entry's URI components are unprefixed per grammar 0.8.0.
local function entry_path(entry)
  if not entry then return nil end
  if not entry.scheme and not entry.pathname then return nil end
  local scheme = entry.scheme
  local pathname = entry.pathname or ""
  if not scheme then return pathname end
  local hostname = entry.hostname or ""
  return string.format("%s://%s%s", scheme, hostname, pathname)
end

-- ── Per-entry state side effects ────────────────────────────────────

-- Is this entry part of the CONVERSATION (the model run)? Run-split
-- (§13.7): client housekeeping (op.exec etc.) lands in the client run and
-- is not shown in the conversation waterfall. The conversation run is
-- authoritative from loop.run's modelRunId / session.runs. Before it's
-- known, events arriving WHILE we drive a loop are the model run (the
-- conversation being generated) — adopt the first one's run_id. op.exec
-- fires when we are NOT driving a loop, so its client-run events are never
-- adopted. Once known, route strictly by run_id (catches wake-loop events
-- too, which share the model run).
local function conversation_entry(session_name, entry)
  if type(entry.run_id) ~= "number" then return false end
  local conv = state.get_run_id(session_name)
  if conv then return entry.run_id == conv end
  if state.is_loop_inflight(session_name) then
    state.set_run_id(session_name, entry.run_id)
    pcall(function() require("plurnk.run_tab").note_run_resolved(session_name) end)
    return true
  end
  return false
end

-- Track current loop/turn for the statusline (conversation entries only).
local function apply_entry_to_state(session_name, entry)
  if type(entry.id) == "number" then
    state.set_last_seen_log_id(session_name, entry.id)
  end
  if type(entry.loop_id) == "number" then
    state.set_current_loop_id(session_name, entry.loop_id)
  end
  if type(entry.turn_id) == "number" then
    state.set_current_turn(session_name, entry.turn_id)
  end
end

-- ── Notification handlers ──────────────────────────────────────────

-- log/entry: one per-action trace per SPEC §5.1.
M.handle_log_entry = function(params, session_name)
  if not params or type(params.entry) ~= "table" then return end
  local entry = params.entry
  -- Only the conversation (model run) is shown; client-run housekeeping
  -- is silent in the waterfall.
  if not session_name or not conversation_entry(session_name, entry) then return end
  apply_entry_to_state(session_name, entry)

  vim.schedule(function()
    local ok, run_tab = pcall(require, "plurnk.run_tab")
    if ok then
      run_tab.append_history(session_name, { entry })
      run_tab.refresh_winbar(session_name)
    end
    redraw_statusline()
  end)
end

-- loop/proposal: a side-effecting op is paused awaiting client resolution
-- per SPEC §6.1. We hand it off to resolve.lua.
--
-- Server-resolved proposals (loop flags.yolo = server-side YOLO auto-accept,
-- flags.noProposals = server-side auto-reject) settle in-process before any
-- human can react — review UI and a loop.resolve would race the already-
-- settled entry. Skip; the lifecycle still shows in the log/entry waterfall.
M.handle_loop_proposal = function(params, session_name)
  if not params or type(params.logEntryId) ~= "number" then return end
  local flags = params.flags
  if type(flags) == "table" and (flags.yolo == true or flags.noProposals == true) then return end
  if session_name then state.add_proposal(session_name, params.logEntryId, params) end
  vim.schedule(function()
    local ok, resolve = pcall(require, "plurnk.resolve")
    if ok then resolve.process(session_name, params) end
  end)
end

-- loop/terminated: the model loop is done. Reflect final state.
M.handle_loop_terminated = function(params, session_name)
  if not params or not session_name then return end
  state.set_loop_inflight(session_name, false)
  state.record_loop_usage(session_name, params.usage)  -- last loop only; NOT a session total (svc#254)
  if type(params.finalStatus) == "number" then
    state.set_final_status(session_name, params.finalStatus)
  end
  vim.schedule(function()
    local ok, run_tab = pcall(require, "plurnk.run_tab")
    if ok then
      run_tab.close_document(session_name)
      run_tab.refresh_winbar(session_name)
    end
    redraw_statusline()
  end)
end

-- Severity from the source:kind discriminator (the wire carries no level) —
-- mirrors the npm client's classifier so errors read as errors. Failure kinds
-- → ErrorMsg (red), warnings (stale/blocked) → WarningMsg (yellow), neutral
-- (graceful/note/url/…) → Comment (dim). Plain substring match (no patterns).
local TELE_ERR = { "error", "fail", "refus", "invalid", "not_found", "ambiguous", "exceeded", "overflow", "denied", "unknown", "missing", "closed", "strike", "unenforced", "rejected", "conflict", "crash" }
local TELE_WARN = { "stale", "warn", "deprecat", "blocked" }
local function telemetry_hl(tag)
  for _, t in ipairs(TELE_ERR) do if tag:find(t, 1, true) then return "ErrorMsg" end end
  for _, t in ipairs(TELE_WARN) do if tag:find(t, 1, true) then return "WarningMsg" end end
  return "Comment"
end

-- telemetry/event: parse errors, engine rail signals, scheme/provider
-- failures. Per SPEC §8.6. Rendered as a `📡 source:kind` line inline.
M.handle_telemetry_event = function(params, session_name)
  if not params or type(params.event) ~= "table" then return end
  local event = params.event
  vim.schedule(function()
    local tag = tostring(event.source or "?") .. ":" .. tostring(event.kind or "?")
    local headline = "  📡 " .. tag
    if type(event.message) == "string" and #event.message > 0 then
      headline = headline .. ' "' .. event.message .. '"'
    end
    if session_name then
      local ok, run_tab = pcall(require, "plurnk.run_tab")
      if ok then run_tab.append_line(session_name, headline) end
    end
    local ok, hud = pcall(require, "plurnk.hud")
    if ok then hud.show(headline) end
    safe_echo(headline, telemetry_hl(tag))
  end)
end

-- session/created: broadcast to all clients when a session is created.
-- We don't currently track all sessions globally; ignore unless the
-- model picker / sessions list is open.
M.handle_session_created = function(_)
  -- no-op for v0.1
end

-- ── Notification dispatch ───────────────────────────────────────────

-- The transport doesn't know which session a notification belongs to
-- beyond the connection scope. For v0.1 we pass nil session_name to
-- handlers that don't already carry one; future work can attach a
-- connection→session map.
M.handle_notification = function(payload)
  local method = payload.method
  if not method then return end
  local params = payload.params or {}
  log("DISPATCH notification: method=" .. method)

  -- The daemon stamps sessionId on every notification (plurnk-service
  -- #191, landed 2026-06-10). Route on it; the active-session fallback
  -- covers only ids we haven't learned a name for yet.
  local session_name = state.session_name_for_id(params.sessionId)
    or state.get_active_session_name()

  if method == "log/entry" then M.handle_log_entry(params, session_name)
  elseif method == "loop/proposal" then M.handle_loop_proposal(params, session_name)
  elseif method == "loop/terminated" then M.handle_loop_terminated(params, session_name)
  elseif method == "telemetry/event" then M.handle_telemetry_event(params, session_name)
  elseif method == "stream/event" then
    pcall(function() require("plurnk.stream").on_event(params, session_name) end)
  elseif method == "stream/concluded" then
    pcall(function() require("plurnk.stream").on_concluded(params, session_name) end)
  elseif method == "session/created" then M.handle_session_created(params)
  end
end

-- ── Response handler ────────────────────────────────────────────────

M.handle_response = function(req_meta, result)
  local method = tostring(req_meta.method)
  log("DISPATCH response: method=" .. method)

  if method == "providers.list" then
    if type(result) == "table" and type(result.aliases) == "table" then
      state.set_available_aliases(result.aliases)
    end
  elseif method == "session.create" or method == "session.attach" then
    -- Per-request callbacks bind the result to the calling buffer/tab.
  elseif method == "session.list" or method == "session.runs" then
    -- Per-request callbacks consume the result (picker, etc.).
  elseif method == "loop.run" then
    -- Per-request callback handles the loop result (finalStatus, turnIds).
  elseif method == "loop.resolve" then
    -- Per-request callback acknowledges the resolution.
  elseif method == "log.read" then
    -- Per-request callback hydrates the run-tab transcript.
  elseif method == "op.parse" then
    -- Per-request callback (TUI-style raw DSL passthrough).
  elseif method == "ping" then
    log("PONG")
  end
end

-- ── Error handler ───────────────────────────────────────────────────

M.handle_error = function(payload)
  if not payload or not payload.error then return end
  local msg = tostring(payload.error.message or "(no message)")
  log("ERROR: " .. msg)
  vim.schedule(function()
    if msg:match("[Cc]onnection") then
      pcall(function() require("plurnk.transport").reset_connection() end)
    end
    local prefix = "Plurnk Error: " .. msg
    local ok, hud = pcall(require, "plurnk.hud")
    if ok then hud.show("✗ " .. prefix) end
    safe_echo(prefix, "ErrorMsg")
    redraw_statusline()
  end)
end

return M
