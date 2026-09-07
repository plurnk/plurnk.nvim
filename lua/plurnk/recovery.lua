-- Bounded recovery of durable worker truth after an AG-UI stream is lost.

local M = {}
local agui = require("plurnk.agui")
local reconciliations = {}
local DEFAULT_ATTEMPTS = 3
local DEFAULT_DELAY_MS = 150

local function project_status(dispatch, thread_id, phase, fields)
  dispatch.handle_notification({
    method = "transport/status",
    params = vim.tbl_extend("force", { workspaceName = thread_id, phase = phase }, fields or {}),
  })
end

-- Any valid STATE on a fresh action Run proves a previously stale connection
-- live. An active reconciliation retains its stronger reconnecting overlay until
-- it observes a non-running daemon lifecycle.
function M.observed(thread_id, dispatch)
  local transport = require("plurnk.state").get_transport_status(thread_id)
  if transport ~= nil and transport.phase == "stale" then
    project_status(dispatch, thread_id, "connected")
  end
end

local function recovered_status(lifecycle)
  return lifecycle == "queued" and 100
    or lifecycle == "completed" and 200
    or lifecycle == "parked" and 202
    or lifecycle == "cancelled" and 499
    or lifecycle == "failed" and 502
    or 200
end

-- Re-observe one worker through the existing AG-UI action surface. Each
-- log.read Run contributes both an authoritative STATE_SNAPSHOT and the durable
-- rows beyond the worker's last observed id. A still-running snapshot may be
-- the small race between socket close and daemon cancellation, so it is
-- observed again a bounded number of times. Nothing here replays inference.
function M.reconcile(thread_id, options, cb)
  options = options or {}
  local existing = reconciliations[thread_id]
  if existing ~= nil then
    if cb then existing.callbacks[#existing.callbacks + 1] = cb end
    return
  end

  local dispatch = require("plurnk.dispatch")
  local state = require("plurnk.state")
  local worker_id = options.workerId or state.get_worker_id(thread_id)
  local attempts = math.max(1, math.floor(tonumber(options.attempts) or DEFAULT_ATTEMPTS))
  local delay_ms = math.max(0, math.floor(tonumber(options.delay_ms) or DEFAULT_DELAY_MS))
  local recovery = { callbacks = cb and { cb } or {}, attempt = 0 }
  reconciliations[thread_id] = recovery

  local function finish(status, problem)
    if reconciliations[thread_id] ~= recovery then return end
    reconciliations[thread_id] = nil
    for _, callback in ipairs(recovery.callbacks) do pcall(callback, status, problem) end
  end

  local function fail(detail, cause)
    local problem = agui.transport_problem(
      "reconciliation-failed",
      "Stream reconciliation failed",
      502,
      detail,
      true,
      "stream-reconciliation",
      {
        recovery = "Run :AI/reconnect or reopen the worker after the daemon is reachable.",
        cause = type(cause) == "table" and cause or options.cause,
      }
    )
    project_status(dispatch, thread_id, "stale", {
      detail = problem.detail,
      recovery = problem.recovery,
    })
    pcall(dispatch.handle_notification, {
      method = "problem/event",
      params = { workspaceName = thread_id, problem = problem },
    })
    finish(502, problem)
  end

  local attempt
  attempt = function()
    recovery.attempt = recovery.attempt + 1
    project_status(dispatch, thread_id, "reconnecting", {
      attempt = recovery.attempt,
      attempts = attempts,
    })
    require("plurnk.bridge").rpc(thread_id, "log.read", {
      workerId = worker_id,
      sinceId = state.get_last_seen_log_id(thread_id, worker_id),
      limit = 1000,
    }, function(result, problem, gauge)
      if reconciliations[thread_id] ~= recovery then return end
      local projected
      if problem == nil and type(gauge) == "table" then
        local ok, value = pcall(require("plurnk.runtime_status").project, gauge)
        if ok then
          projected = value
        else
          problem = agui.transport_problem(
            "state-invalid",
            "State invalid",
            502,
            "The reconciliation Run returned invalid runtime state: " .. tostring(value),
            false
          )
        end
      end
      if problem == nil and type(result) ~= "table" then
        problem = agui.transport_problem(
          "log-missing",
          "Log missing",
          502,
          "The reconciliation Run returned no durable log result.",
          false
        )
      end
      if problem == nil and type(result.entries) == "table" and #result.entries >= 1000 then
        problem = agui.transport_problem(
          "log-window-incomplete",
          "Log window incomplete",
          502,
          "The durable-log action reached its public result limit, so lossless reconciliation cannot be proven.",
          false
        )
      end

      if problem ~= nil or projected == nil or projected.lifecycle == "running" then
        local retryable = projected ~= nil and projected.lifecycle == "running"
          or type(problem) == "table" and problem.retryable == true
        if retryable and recovery.attempt < attempts then
          vim.defer_fn(attempt, delay_ms * recovery.attempt)
          return
        end
        fail(projected and "The daemon remained active after bounded stream reconciliation."
          or "The client could not re-observe durable worker state after the stream ended.", problem)
        return
      end

      local entries = type(result.entries) == "table" and result.entries or {}
      table.sort(entries, function(a, b)
        return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
      end)
      if worker_id == nil then
        for _, entry in ipairs(entries) do
          if type(entry.worker_id) == "number" then
            worker_id = entry.worker_id
            require("plurnk.workspace_context").note_model_worker(thread_id, worker_id)
            break
          end
        end
      end
      if type(worker_id) == "number" then
        require("plurnk.worker_tab").append_history(thread_id, entries)
        for _, entry in ipairs(entries) do
          state.set_last_seen_log_id(thread_id, worker_id, entry.id)
        end
      end
      project_status(dispatch, thread_id, "connected")
      finish(recovered_status(projected.lifecycle), nil)
    end, { quiet = true })
  end

  attempt()
end

return M
