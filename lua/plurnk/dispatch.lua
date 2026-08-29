-- Response and notification routing.
--
-- Plurnk is push-driven: log/entry / loop/proposal / loop/terminated /
-- notice/event notifications arrive with full payloads as state
-- changes; no pulse-and-pull reconciliation step is needed.
--
-- Per plurnk SPEC §5.1 (log/entry), §6.1 (loop/proposal), §8.6
-- (notice/event).

local M = {}
local state = require("plurnk.state")

-- ── Helpers ─────────────────────────────────────────────────────────

local function log(msg)
  local _ = msg   -- transport logging is intentionally silent
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
-- Client housekeeping (op.exec etc.) lands in the client worker and
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
    pcall(function() require("plurnk.worker_tab").note_worker_resolved(workspace_name) end)
    return true
  end
  return false
end

local function apply_entry_to_state(workspace_name, entry)
  if type(entry.id) == "number" then
    state.set_last_seen_log_id(workspace_name, entry.worker_id, entry.id)
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

-- AG-UI STATE is the sole status authority. The bridge reduces each stream's
-- snapshot and deltas before projecting the resulting gauge here.
M.handle_loop_packet = function(params, workspace_name)
  if not workspace_name or type(params) ~= "table" or type(params.gauge) ~= "table" then return end
  state.set_runtime_gauge(workspace_name, params.gauge)
  vim.schedule(function()
    local ok, worker_tab = pcall(require, "plurnk.worker_tab")
    if ok then worker_tab.refresh_winbar(workspace_name) end
    redraw_statusline()
  end)
end

-- Connection health is client-owned presentation state, distinct from the
-- daemon-owned runtime gauge. A broken wire must never rewrite lifecycle; its
-- overlay simply takes precedence until a later supported AG-UI Run proves the
-- connection live again.
M.handle_transport_status = function(params, workspace_name)
  if not workspace_name or type(params) ~= "table" then return end
  local status = nil
  if params.phase ~= "connected" then
    status = {
      phase = params.phase,
      attempt = params.attempt,
      attempts = params.attempts,
      detail = params.detail,
      recovery = params.recovery,
    }
  end
  state.set_transport_status(workspace_name, status)
  vim.schedule(function()
    local ok, worker_tab = pcall(require, "plurnk.worker_tab")
    if ok then worker_tab.refresh_winbar(workspace_name) end
    redraw_statusline()
  end)
end

-- Standard provider reasoning is presentation evidence, not a log operation.
-- Preserve its live AG-UI lifecycle while one buffer region grows in place.
M.handle_reasoning_event = function(params, workspace_name)
  if type(params) ~= "table" or type(params.messageId) ~= "string" or not workspace_name then return end
  vim.schedule(function()
    local ok, worker_tab = pcall(require, "plurnk.worker_tab")
    if not ok then return end
    if params.phase == "start" then
      worker_tab.begin_reasoning(workspace_name, params.workerId, params.messageId)
    elseif params.phase == "content" and type(params.delta) == "string" then
      worker_tab.append_reasoning_delta(workspace_name, params.workerId, params.messageId, params.delta)
    elseif params.phase == "end" then
      worker_tab.end_reasoning(workspace_name, params.workerId, params.messageId)
    end
  end)
end

-- loop/proposal: a side-effecting op is paused awaiting client resolution
-- per SPEC §6.1. We hand it off to resolve.lua.
--
-- AG-UI projects only client-owned proposals onto this surface. Loop-owned
-- accept/reject dispositions settle in Core and never become review work here.
-- One daemon proposal fans out to EVERY open SSE of the workspace (each in-flight
-- action run is a live stream) — process once per logEntryId; the log is
-- append-only, so an id never legitimately recurs.
local seen_proposals = {}

M.handle_loop_proposal = function(params, workspace_name)
  if not params or type(params.logEntryId) ~= "number" then return end
  if seen_proposals[params.logEntryId] then return end
  seen_proposals[params.logEntryId] = true
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
  state.record_loop_usage(workspace_name, params.usage)  -- exact last-loop envelope; never a client tally
  vim.schedule(function()
    local ok, worker_tab = pcall(require, "plurnk.worker_tab")
    if ok then
      worker_tab.close_document(workspace_name)
      worker_tab.refresh_winbar(workspace_name)
    end
    redraw_statusline()
  end)
end

M.handle_problem_event = function(params, workspace_name)
  if type(params) ~= "table" or type(params.problem) ~= "table" then return end
  local problem = params.problem
  local line = require("plurnk.render").render_diagnostic(problem)
  vim.schedule(function()
    if workspace_name then
      local ok, worker_tab = pcall(require, "plurnk.worker_tab")
      if ok then worker_tab.append_line(workspace_name, line) end
    end
    local ok, hud = pcall(require, "plurnk.hud")
    if ok then hud.show(line) end
    safe_echo(line, "ErrorMsg")
  end)
end

-- Severity comes from the producer-set notice.level —
-- mirrors the npm client (#110). The producer owns severity; the client colors
-- straight off it, never re-deriving from the kind string. error → ErrorMsg
-- (red), warn → WarningMsg (yellow), info → Comment (dim).
local function notice_hl(level)
  if level == "error" then return "ErrorMsg" end
  if level == "warn" then return "WarningMsg" end
  return "Comment"
end

-- notice/event: transient, nonterminal progress and diagnostics. Durable
-- failures remain log rows. Rendered as a `📡 source:kind` line inline.
M.handle_notice_event = function(params, workspace_name)
  if not params or type(params.notice) ~= "table" then return end
  local notice = params.notice
  -- engine:turn liveness is the activity slot, not a waterfall line.
  if notice.source == "engine:turn" then return end
  -- The immediately preceding AG-UI STATE_DELTA owns derivation activity.
  if notice.source == "engine:derivation" and notice.kind == "embed_progress" then
    return
  end
  -- Search page acquisition is compact edge state too: a percentage in the
  -- statusline, never one waterfall line per milestone or candidate.
  if type(notice.source) == "string" and notice.source:match("^exec:")
      and notice.kind == "search_progress" then
    if workspace_name then
      local active = notice.phase ~= "complete" and notice.phase ~= "failed"
      state.set_search_progress(workspace_name, active and tonumber(notice.percent) or nil)
      redraw_statusline()
    end
    return
  end
  vim.schedule(function()
    local headline = require("plurnk.render").render_diagnostic(notice)
    if workspace_name then
      local ok, worker_tab = pcall(require, "plurnk.worker_tab")
      if ok then worker_tab.append_line(workspace_name, headline) end
    end
    local ok, hud = pcall(require, "plurnk.hud")
    if ok then hud.show(headline) end
    safe_echo(headline, notice_hl(notice.level))
  end)
end

-- workspace/created: broadcast to all clients when a workspace is created.
-- We don't currently track all workspaces globally; ignore unless the
-- model picker / workspaces list is open.
M.handle_workspace_created = function(_)
  -- no-op for v0.1
end

-- Serialized branch batches are compact workspace state while queued/running.
-- Only terminal or operator-recovery transitions append a line.
M.handle_branch_batch = function(params, workspace_name)
  if type(params) ~= "table" or not workspace_name then return end
  local terminal = params.state == "completed" or params.state == "failed"
  if terminal then
    state.set_branch_batch(workspace_name, nil)
  else
    state.set_branch_batch(workspace_name, params)
  end
  if terminal or params.state == "recovery_required" then
    vim.schedule(function()
      local ok, worker_tab = pcall(require, "plurnk.worker_tab")
      local problem = type(params.problem) == "table" and params.problem.detail or nil
      local line
      if params.state == "completed" then
        line = string.format("🌿 branch batch %s complete (%s/%s)",
          tostring(params.batchId or "?"), tostring(params.completed or params.total or 0),
          tostring(params.total or params.completed or 0))
      elseif params.state == "failed" then
        line = string.format("❌ branch batch %s failed: %s",
          tostring(params.batchId or "?"), tostring(problem or "branch preflight failed"))
      else
        line = string.format("❌ branch batch %s requires recovery: %s",
          tostring(params.batchId or "?"), tostring(problem or "inspect the workspace Git state"))
      end
      if ok then worker_tab.append_line(workspace_name, line) end
      safe_echo(line, params.state == "completed" and "Comment" or "ErrorMsg")
    end)
  end
  redraw_statusline()
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
  local workspace_name = params.workspaceName
    or state.workspace_name_for_id(params.workspaceId)
    or state.get_active_workspace_name()

  if method == "log/entry" then M.handle_log_entry(params, workspace_name)
  elseif method == "loop/packet" then M.handle_loop_packet(params, workspace_name)
  elseif method == "transport/status" then M.handle_transport_status(params, workspace_name)
  elseif method == "reasoning/event" then M.handle_reasoning_event(params, workspace_name)
  elseif method == "loop/proposal" then M.handle_loop_proposal(params, workspace_name)
  elseif method == "loop/interaction" then M.handle_loop_interaction(params, workspace_name)
  elseif method == "loop/terminated" then M.handle_loop_terminated(params, workspace_name)
  elseif method == "problem/event" then M.handle_problem_event(params, workspace_name)
  elseif method == "notice/event" then M.handle_notice_event(params, workspace_name)
  elseif method == "stream/event" then
    pcall(function() require("plurnk.stream").on_event(params, workspace_name) end)
  elseif method == "stream/concluded" then
    pcall(function() require("plurnk.stream").on_concluded(params, workspace_name) end)
  elseif method == "workspace/branch-batch" then M.handle_branch_batch(params, workspace_name)
  elseif method == "workspace/created" then M.handle_workspace_created(params)
  end
end

-- {§question-tool} — a client interaction pauses its owning loop: present the
-- standard message + response schema and answer through the interaction resume.
local seen_interactions = {}
M.handle_loop_interaction = function(params, workspace_name)
  if not params or type(params.interactionId) ~= "number" then return end
  if seen_interactions[params.interactionId] then return end
  seen_interactions[params.interactionId] = true
  vim.schedule(function()
    local ok, question = pcall(require, "plurnk.question")
    if ok then question.review(workspace_name, params) end
  end)
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
    -- Per-request callback handles the loop acknowledgement.
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

return M
