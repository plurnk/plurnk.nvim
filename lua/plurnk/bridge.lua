-- Logical requests own their binding, interrupts, and HTTP segments independently.
-- {§nvim-conversation-requests} {§nvim-agui-interrupt-resume}
local M = {}
local agui = require("plurnk.agui")
local state = require("plurnk.state")
local active_runs, interrupts, requests, renaming = {}, {}, {}, {}

function M.target()
  local env = require("plurnk.operator_env")
  local config = require("plurnk.config")
  local url = env.get("PLURNK_AGUI_URL")
  if url == nil then
    url = "http://" .. (env.get("PLURNK_HOST") or config.get("host"))
      .. ":" .. (env.get("PLURNK_PORT") or tostring(config.get("port")))
  end
  return { url = url, token = env.get("PLURNK_AGUI_TOKEN") }
end

function M.enabled() return true end
function M.active(binding) return active_runs[binding] end
function M.busy(workspace)
  for request in pairs(requests) do
    if request.binding.workspace == workspace then return true end
  end
  return false
end
function M.set_renaming(workspace, value) renaming[workspace] = value or nil end
function M.is_renaming(workspace) return renaming[workspace] == true end

local function problem(kind, title, detail)
  return agui.transport_problem(kind, title, 502, detail, false)
end

local function notify_failure(method, failure)
  if failure.source == "client:connection" and failure.kind == "refused" then
    vim.notify(table.concat({
      "plurnk: no daemon is running - the plurnk client connects to one.",
      "  Quick start (no install):  npx @plurnk/plurnk-service start",
      "  Or install it:             npm i -g @plurnk/plurnk-service && plurnk-service",
    }, "\n"), vim.log.levels.WARN)
    return
  end
  vim.notify("plurnk: " .. method .. " - " .. tostring(failure.detail or failure.title)
    .. (type(failure.recovery) == "string" and ("\n  " .. failure.recovery) or ""), vim.log.levels.WARN)
end

local function dispatch(request, notification)
  if not notification then return end
  local binding = request.binding
  local params = notification.params or {}
  notification.params = params
  params.workspaceName = binding.workspace
  params.binding = binding
  params.requestSource = request.kind
  params.reviewRequested = request.review
  if notification.method == "problem/event" then request.problem_dispatched = true end
  if request.kind == "model" and notification.method == "log/entry"
      and binding.workerId == nil and type(params.entry) == "table"
      and type(params.entry.worker_id) == "number" then
    state.identify(binding, params.entry.worker_id)
    require("plurnk.worker_tab").note_worker_resolved(binding.workspace)
  end
  params.workerId = params.workerId or binding.workerId
  require("plurnk.dispatch").handle_notification(notification)
end

local function consume(request, segment, event)
  local ok, handled, gauge = pcall(require("plurnk.runtime_status").reduce, segment.gauge, event)
  if not ok then
    segment.problem = problem("state-invalid", "State invalid",
      "The AG-UI stream contained invalid runtime state: " .. tostring(handled))
    return nil
  end
  if handled then
    segment.gauge = gauge
    -- An action's private snapshot must not rewind a live model stream's gauge.
    local active = active_runs[request.binding]
    if request.kind == "model" or active == nil or active.phase == "recovering" then
      dispatch(request, { method = "loop/packet", params = { gauge = gauge } })
    end
    require("plurnk.recovery").observed(request.binding, require("plurnk.dispatch"))
    return nil
  end
  local valid, notification = pcall(agui.unproject, event, segment.tool)
  if not valid then
    segment.problem = problem("event-invalid", "Event invalid", "The AG-UI event could not be projected: " .. tostring(notification))
    return nil
  end
  if notification and notification.method == "problem/event" then
    segment.problem = notification.params.problem
  end
  return notification
end

local function retire_interrupt(request)
  local id = request.interrupt_id
  if not id then return end
  local pending = interrupts[request.binding]
  if pending and pending[id] == request then
    pending[id] = nil
    if next(pending) == nil then interrupts[request.binding] = nil end
  end
  request.interrupt_id = nil
  dispatch(request, { method = "interrupt/ended", params = { interruptId = id } })
end

local function finish(request, result, failure, gauge)
  if request.finished then return end
  if (request.injections or 0) > 0 then
    request.completion = { result = result, failure = failure, gauge = gauge }
    return
  end
  request.finished = true
  requests[request] = nil
  retire_interrupt(request)
  if active_runs[request.binding] == request then active_runs[request.binding] = nil end
  if failure and not request.quiet and not request.problem_dispatched then
    if request.kind == "model" then dispatch(request, { method = "problem/event", params = { problem = failure } })
    else notify_failure(request.method, failure) end
  end
  if request.cb then request.cb(result, failure, gauge) end
  if request.follow then M.observe(request.binding) end
end

local function interrupt_id(notification)
  if notification.method == "loop/proposal" then return "prop:" .. notification.params.logEntryId end
  if notification.method == "loop/interaction" then return "int:" .. notification.params.interactionId end
end

local function pause(request, notification, outcome)
  local id = notification and interrupt_id(notification)
  if not id or not agui.has_interrupt(outcome, id) then
    return problem("interrupt-mismatch", "Interrupt mismatch",
      "The request ended without its matching AG-UI interrupt outcome.")
  end
  interrupts[request.binding] = interrupts[request.binding] or {}
  assert(interrupts[request.binding][id] == nil, "An interrupt already has a request owner")
  interrupts[request.binding][id] = request
  request.interrupt_id = id
  request.phase = "paused"
  dispatch(request, notification)
end

local function settle_reasoning(request, segment)
  for _, id in ipairs(vim.tbl_keys(segment.tool.reasoning or {})) do
    segment.tool.reasoning[id] = nil
    dispatch(request, { method = "reasoning/event", params = { phase = "end", messageId = id } })
  end
end

local function model_stream(request)
  local segment = { tool = {} }
  local function event(e)
    if request.finished then return end
    if e.type == "RUN_STARTED" then segment.started = true end
    local n = consume(request, segment, e)
    if n and interrupt_id(n) then segment.interrupt = n; n = nil end
    if e.type == "RUN_ERROR" then segment.run_error = true; return end
    if e.type == "RUN_FINISHED" then
      segment.terminal = true
      if e.outcome and e.outcome.type == "interrupt" then
        segment.problem = segment.problem or pause(request, segment.interrupt, e.outcome)
        segment.paused = segment.problem == nil
      elseif e.outcome and e.outcome.type == "success" then
        segment.status = segment.status or 200
      else
        segment.problem = problem("terminal-invalid", "Terminal invalid", "The AG-UI run has no supported outcome.")
      end
      return
    end
    if n and n.method == "loop/terminated" then
      segment.status, segment.problem = agui.operation_result(n.params.result)
    end
    if n and not (request.quiet and n.method == "problem/event") then dispatch(request, n) end
  end
  local function done(_, transport_error)
    if request.finished or segment.paused then return end
    settle_reasoning(request, segment)
    local failure = segment.problem or transport_error
    if not segment.terminal and not segment.run_error and failure == nil then
      failure = agui.transport_problem("terminal-missing", "Terminal missing", 502,
        "The AG-UI stream ended before reporting the run outcome.", true, "stream-reconciliation",
        { recovery = "Reconnect to observe durable state; do not replay the prompt." })
    elseif segment.run_error and failure == nil then
      failure = problem("problem-missing", "Problem missing",
        "The AG-UI stream reported a failed run without its required Problem Details.")
    end
    if segment.started and not segment.terminal and not segment.run_error and failure
        and (failure.kind == "terminal-missing" or failure.kind == "stream-read-failed"
          or failure.kind == "event-stream-empty" or (failure.source == "client:connection" and failure.retryable)) then
      request.phase = "recovering"
      require("plurnk.recovery").reconcile(request.binding.workspace, {
        binding = request.binding, cause = failure,
      }, function(status, recovered_problem)
        request.problem_dispatched = recovered_problem ~= nil
        finish(request, status or 502, recovered_problem, segment.gauge)
      end)
      return
    end
    finish(request, failure and failure.status or segment.status or 502, failure, segment.gauge)
  end
  return event, done
end

local function action_stream(request)
  local segment = { tool = {} }
  local function event(e)
    if request.finished then return end
    local n = consume(request, segment, e)
    if n and interrupt_id(n) then segment.interrupt = n; return end
    if n and not (request.quiet and n.method == "problem/event") then dispatch(request, n) end
  end
  local function done(outcome)
    if request.finished then return end
    local failure = segment.problem or outcome.problem
    if failure then finish(request, nil, failure, segment.gauge)
    elseif outcome.state == "interrupted" then
      failure = pause(request, segment.interrupt, outcome.outcome)
      if failure then finish(request, nil, failure, segment.gauge) end
    else finish(request, outcome.result, nil, segment.gauge) end
  end
  return event, done
end

function M.run(binding, prompt, opts, on_done)
  assert(active_runs[binding] == nil, "The conversation already has an observed model run")
  local request = { binding = binding, target = M.target(), kind = "model", method = "loop.run",
    cb = on_done, review = opts and opts.review == true }
  active_runs[binding] = request
  requests[request] = true
  local event, done = model_stream(request)
  request.handle = agui.run(request.target, {
    workspace = binding.workspace, threadId = binding.threadId, prompt = prompt,
    forwardedProps = opts and opts.forwardedProps,
  }, event, done)
  return request
end

function M.rpc(binding, method, params, cb, options)
  local request = { binding = binding, target = M.target(), kind = "action", method = method,
    cb = cb, quiet = options and options.quiet == true }
  if renaming[binding.workspace] and method ~= "workspace.rename" then
    finish(request, nil, problem("workspace-renaming", "Workspace renaming", "Retry this action after the workspace rename completes."))
    return request
  end
  requests[request] = true
  local event, done = action_stream(request)
  request.handle = agui.rpc(request.target, binding, method, params, done, event)
  return request
end

function M.observe(binding)
  if active_runs[binding] then return end
  local since_id = state.get_last_seen_log_id(binding.workspace, binding.workerId)
  state.set_loop_inflight(binding.workspace, true, binding.workerId)
  return M.run(binding, nil, { forwardedProps = { mode = "sync" } }, function()
    -- Restore any rows committed between admission and attaching the observer.
    -- This is the same bounded, inference-free history reconciliation as reconnect.
    require("plurnk.recovery").reconcile(binding.workspace, { binding = binding, sinceId = since_id }, function()
      state.set_loop_inflight(binding.workspace, false, binding.workerId)
      require("plurnk.worker_tab").refresh_winbar(binding.workspace)
    end)
  end)
end

function M.inject(binding, prompt, cb)
  local active = active_runs[binding]
  if active then active.injections = (active.injections or 0) + 1 end
  return M.rpc(binding, "loop.inject", { prompt = prompt }, function(result, failure)
    local enqueued = type(result) == "table" and result.action == "enqueued_new_loop"
    if active then
      active.injections = active.injections - 1
      active.follow = active.follow or enqueued
      if active.completion and active.injections == 0 then
        local completion = active.completion
        finish(active, completion.result, completion.failure, completion.gauge)
      end
    elseif enqueued then M.observe(binding) end
    if cb then cb(result, failure) end
  end)
end

local function resume(binding, id, resolution, cb)
  local request = interrupts[binding] and interrupts[binding][id]
  if request == nil then
    local failure = problem("interrupt-not-pending", "Interrupt not pending",
      "Interrupt '" .. id .. "' is not pending in this conversation.")
    notify_failure("resume", failure)
    if cb then cb(nil, failure) end
    return
  end
  retire_interrupt(request)
  request.phase = "running"
  local run = { workspace = binding.workspace, threadId = binding.threadId, resume = { resolution } }
  if request.kind == "action" then
    local event, done = action_stream(request)
    request.handle = agui.action_segment(request.target, run, function(segment)
      done(segment)
      if cb then cb(segment.state ~= "failed" and segment.code or nil, segment.problem) end
    end, event)
  else
    local event, done = model_stream(request)
    request.handle = agui.run(request.target, run, event, function(code, failure)
      done(code, failure)
      if cb then cb(failure == nil and code or nil, failure) end
    end)
  end
end

function M.resolve(binding, value, cb)
  local id = "prop:" .. tostring(value.logEntryId)
  resume(binding, id, value.decision == "cancel" and { interruptId = id, status = "cancelled" }
    or { interruptId = id, status = "resolved", payload = { decision = value.decision, body = value.body } }, cb)
end

function M.resolve_interaction(binding, interaction_id, payload, cb)
  local id = "int:" .. tostring(interaction_id)
  resume(binding, id, payload == "cancel" and { interruptId = id, status = "cancelled" }
    or { interruptId = id, status = "resolved", payload = payload }, cb)
end

-- Server admission owns cancellation. Only its acknowledged model request is
-- retired; independently submitted actions and other conversations remain live.
function M.cancel(binding, cb)
  local active = active_runs[binding]
  local runtime = state.get_runtime_status(binding.workspace, binding.workerId)
  return M.rpc(binding, "loop.cancel", { reason = "user_stop" }, function(result, failure)
    if not failure and type(result) == "table" and result.cancelled and active and not active.finished then
      finish(active, 499)
      if active.handle and active.handle.kill then active.handle:kill() end
    end
    if not failure and type(result) == "table" and result.cancelled and runtime and runtime.loop_id then
      require("plurnk.recovery").reconcile(binding.workspace, {
        binding = binding, cancelledLoopId = runtime.loop_id,
      }, function(_, problem)
        if cb then cb(result, problem) end
      end)
      return
    end
    if cb then cb(result, failure) end
  end)
end

return M
