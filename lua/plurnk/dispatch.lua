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
  local _ = msg   -- transport log retired with the WS client
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

-- Is this entry part of the CONVERSATION (the model worker)? Worker-split
-- (§13.7): client housekeeping (op.exec etc.) lands in the client worker and
-- is not shown in the conversation waterfall. The conversation worker is
-- authoritative from loop.run's modelWorkerId / workspace.workers. Before it's
-- known, events arriving WHILE we drive a loop are the model worker (the
-- conversation being generated) — adopt the first one's worker_id. op.exec
-- fires when we are NOT driving a loop, so its client-worker events are never
-- adopted. Once known, route strictly by worker_id (catches wake-loop events
-- too, which share the model worker).
local function conversation_entry(workspace_name, entry)
  if type(entry.worker_id) ~= "number" then return false end
  local conv = state.get_worker_id(workspace_name)
  if conv then return entry.worker_id == conv end
  if state.is_loop_inflight(workspace_name) then
    state.set_worker_id(workspace_name, entry.worker_id)
    pcall(function() require("plurnk.worker_tab").note_run_resolved(workspace_name) end)
    return true
  end
  return false
end

-- Track current loop/turn for the statusline (conversation entries only).
local function apply_entry_to_state(workspace_name, entry)
  if type(entry.id) == "number" then
    state.set_last_seen_log_id(workspace_name, entry.id)
  end
  if type(entry.loop_id) == "number" then
    state.set_current_loop_id(workspace_name, entry.loop_id)
  end
  if type(entry.turn_id) == "number" then
    state.set_current_turn(workspace_name, entry.turn_id)
  end
end

-- ── Notification handlers ──────────────────────────────────────────

-- log/entry: one per-action trace per SPEC §5.1.
M.handle_log_entry = function(params, workspace_name)
  if not params or type(params.entry) ~= "table" then return end
  local entry = params.entry
  -- Only the conversation (model worker) is shown; client-worker housekeeping
  -- is silent in the waterfall.
  if not workspace_name or not conversation_entry(workspace_name, entry) then return end
  apply_entry_to_state(workspace_name, entry)

  vim.schedule(function()
    local ok, worker_tab = pcall(require, "plurnk.worker_tab")
    if ok then
      worker_tab.append_history(workspace_name, { entry })
      worker_tab.refresh_winbar(workspace_name)
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
-- One daemon proposal fans out to EVERY open SSE of the workspace (each in-flight
-- action run is a live stream) — process once per logEntryId; the log is
-- append-only, so an id never legitimately recurs.
local seen_proposals = {}

M.handle_loop_proposal = function(params, workspace_name)
  if not params or type(params.logEntryId) ~= "number" then return end
  if seen_proposals[params.logEntryId] then return end
  seen_proposals[params.logEntryId] = true
  local flags = params.flags
  if type(flags) == "table" and (flags.yolo == true or flags.noProposals == true) then return end
  if workspace_name then state.add_proposal(workspace_name, params.logEntryId, params) end
  vim.schedule(function()
    local ok, resolve = pcall(require, "plurnk.resolve")
    if ok then resolve.process(workspace_name, params) end
  end)
end

-- loop/terminated: the model loop is done. Reflect final state.
M.handle_loop_terminated = function(params, workspace_name)
  if not params or not workspace_name then return end
  state.set_loop_inflight(workspace_name, false)
  state.set_embedding(workspace_name, false)  -- the abacus never outlives the loop
  state.record_loop_usage(workspace_name, params.usage)  -- last loop only; NOT a workspace total (svc#254)
  if type(params.finalStatus) == "number" then
    state.set_final_status(workspace_name, params.finalStatus)
  end
  vim.schedule(function()
    local ok, worker_tab = pcall(require, "plurnk.worker_tab")
    if ok then
      worker_tab.close_document(workspace_name)
      worker_tab.refresh_winbar(workspace_name)
    end
    redraw_statusline()
  end)
end

-- Severity from the producer-set event.level (grammar 0.74.29+ / svc#276) —
-- mirrors the npm client (#110). The producer owns severity; the client colors
-- straight off it, never re-deriving from the kind string. error → ErrorMsg
-- (red), warn → WarningMsg (yellow), info/absent → Comment (dim).
local function telemetry_hl(level)
  if level == "error" then return "ErrorMsg" end
  if level == "warn" then return "WarningMsg" end
  return "Comment"
end

-- telemetry/event: parse errors, engine rail signals, scheme/provider
-- failures. Per SPEC §8.6. Rendered as a `📡 source:kind` line inline.
M.handle_telemetry_event = function(params, workspace_name)
  if not params or type(params.event) ~= "table" then return end
  local event = params.event
  -- engine:turn liveness is the ⏳ gutter, not a waterfall line (mirrors the TUI).
  if event.source == "engine:turn" then return end
  -- embed_progress toggles the 🧮 abacus on the EDGE — never a per-tick line.
  if event.source == "engine:derivation" and event.kind == "embed_progress" then
    local active = tonumber(event.completed) ~= nil and tonumber(event.total) ~= nil
      and tonumber(event.completed) < tonumber(event.total)
    if workspace_name and active ~= state.is_embedding(workspace_name) then
      state.set_embedding(workspace_name, active)
      redraw_statusline()
    end
    return
  end
  -- Search page acquisition is compact edge state too: a percentage in the
  -- statusline, never one waterfall line per milestone or candidate.
  if type(event.source) == "string" and event.source:match("^exec:")
      and event.kind == "search_progress" then
    if workspace_name then
      local active = event.phase ~= "complete" and event.phase ~= "failed"
      state.set_search_progress(workspace_name, active and tonumber(event.percent) or nil)
      redraw_statusline()
    end
    return
  end
  vim.schedule(function()
    local tag = tostring(event.source or "?") .. ":" .. tostring(event.kind or "?")
    local headline = "  📡 " .. tag
    if type(event.message) == "string" and #event.message > 0 then
      headline = headline .. ' "' .. event.message .. '"'
    end
    if workspace_name then
      local ok, worker_tab = pcall(require, "plurnk.worker_tab")
      if ok then worker_tab.append_line(workspace_name, headline) end
    end
    local ok, hud = pcall(require, "plurnk.hud")
    if ok then hud.show(headline) end
    safe_echo(headline, telemetry_hl(event.level))
  end)
end

-- workspace/created: broadcast to all clients when a workspace is created.
-- We don't currently track all workspaces globally; ignore unless the
-- model picker / workspaces list is open.
M.handle_workspace_created = function(_)
  -- no-op for v0.1
end

-- ── Notification dispatch ───────────────────────────────────────────

-- The transport doesn't know which workspace a notification belongs to
-- beyond the connection scope. For v0.1 we pass nil workspace_name to
-- handlers that don't already carry one; future work can attach a
-- connection→workspace map.
M.handle_notification = function(payload)
  local method = payload.method
  if not method then return end
  local params = payload.params or {}
  log("DISPATCH notification: method=" .. method)

  -- The daemon stamps workspaceId on every notification (plurnk-service
  -- #191, landed 2026-06-10). Route on it; the active-workspace fallback
  -- covers only ids we haven't learned a name for yet.
  local workspace_name = state.workspace_name_for_id(params.workspaceId)
    or state.get_active_workspace_name()

  if method == "log/entry" then M.handle_log_entry(params, workspace_name)
  elseif method == "loop/proposal" then M.handle_loop_proposal(params, workspace_name)
  elseif method == "loop/terminated" then M.handle_loop_terminated(params, workspace_name)
  elseif method == "telemetry/event" then M.handle_telemetry_event(params, workspace_name)
  elseif method == "stream/event" then
    pcall(function() require("plurnk.stream").on_event(params, workspace_name) end)
  elseif method == "stream/concluded" then
    pcall(function() require("plurnk.stream").on_concluded(params, workspace_name) end)
  elseif method == "workspace/created" then M.handle_workspace_created(params)
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
  elseif method == "workspace.create" or method == "workspace.attach" then
    -- Per-request callbacks bind the result to the calling buffer/tab.
  elseif method == "workspace.list" or method == "workspace.workers" then
    -- Per-request callbacks consume the result (picker, etc.).
  elseif method == "loop.run" then
    -- Per-request callback handles the loop result (finalStatus, turnIds).
  elseif method == "loop.resolve" then
    -- Per-request callback acknowledges the resolution.
  elseif method == "log.read" then
    -- Per-request callback hydrates the worker-tab transcript.
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
    end
    local prefix = "Plurnk Error: " .. msg
    local ok, hud = pcall(require, "plurnk.hud")
    if ok then hud.show("✗ " .. prefix) end
    safe_echo(prefix, "ErrorMsg")
    redraw_statusline()
  end)
end

return M
