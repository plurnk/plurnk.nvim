-- The nvim bridge is the AG-UI+ transport. Runs ride HTTP/SSE and each event
-- un-projects into dispatch.handle_notification; verbs and resolutions ride
-- the action surface. The threadId IS the workspace (workspace) name,
-- verbatim — no prefix, no forging (module §agui-thread-is-run: the workspace is the
-- world, the thread binds its model worker); workspace options ride the first run's forwardedProps.
local M = {}
local agui = require("plurnk.agui")
local active_runs = {}

local function consume_status_event(current, event, thread_id, worker_id, dispatch, quiet)
  local ok, handled, next_gauge = pcall(require("plurnk.runtime_status").reduce, current, event)
  if not ok then
    local problem = agui.transport_problem(
      "state-invalid",
      "State invalid",
      502,
      "The AG-UI stream contained invalid runtime state: " .. tostring(handled),
      false)
    if not quiet then
      dispatch.handle_notification({
        method = "problem/event",
        params = { problem = problem, workspaceName = thread_id },
      })
    end
    return true, current, problem
  end
  if not handled then return false, current, nil end
  dispatch.handle_notification({
    method = "loop/packet",
    params = {
      workspaceName = thread_id,
      workerId = worker_id,
      gauge = next_gauge,
    },
  })
  require("plurnk.recovery").observed(thread_id, dispatch)
  return true, next_gauge, nil
end

local function unproject(e, assembler, workspace_name, worker_id)
  local n = agui.unproject(e, assembler)
  if n ~= nil and n.method == "reasoning/event" then
    n.params.workspaceName = workspace_name
    if type(worker_id) == "number" then n.params.workerId = worker_id end
  end
  return n
end

local function settle_reasoning(assembler, workspace_name, worker_id, dispatch)
  if type(assembler.reasoning) ~= "table" then return end
  local ids = vim.tbl_keys(assembler.reasoning)
  table.sort(ids)
  for _, message_id in ipairs(ids) do
    assembler.reasoning[message_id] = nil
    pcall(dispatch.handle_notification, {
      method = "reasoning/event",
      params = {
        workspaceName = workspace_name,
        workerId = worker_id,
        phase = "end",
        messageId = message_id,
      },
    })
  end
end

-- AG-UI+ IS the client surface: default http://PLURNK_HOST:PLURNK_PORT (the
-- daemon's in-process module); PLURNK_AGUI_URL stays an explicit remote override.
function M.target()
  local url = vim.env.PLURNK_AGUI_URL
  if url == nil or url == "" then
    local host = (vim.env.PLURNK_HOST ~= nil and vim.env.PLURNK_HOST ~= "") and vim.env.PLURNK_HOST or "127.0.0.1"
    local port = (vim.env.PLURNK_PORT ~= nil and vim.env.PLURNK_PORT ~= "") and vim.env.PLURNK_PORT or "3044"
    url = "http://" .. host .. ":" .. port
  end
  return { url = url, token = vim.env.PLURNK_AGUI_TOKEN }
end

function M.enabled() return true end

-- Run a prompt through the bridge. Events un-project into the dispatcher;
-- on_done(finalStatus). Returns the vim.system
-- handle (handle:kill() = /stop, the bridge cancels on hangup).
function M.run(thread_id, prompt, opts, on_done)
  local t = M.target()
  if t == nil then return nil end
  local dispatch = require("plurnk.dispatch")
  local active = { thread_id = thread_id }

  -- A terminate/resume interaction is one logical run carried by distinct HTTP
  -- streams. Each stream owns its terminal evidence so a delayed completion
  -- callback from the interrupted stream cannot corrupt the resumed stream.
  local function bind_stream()
    active.proposal_id = nil
    local final = nil
    local run_problem = nil
    local saw_run_error = false
    local problem_dispatched = false
    local plurnk_status = nil -- family metadata; AG-UI terminal events own lifecycle
    local tool = {} -- the TOOL_CALL triple assembler belongs to this stream
    local paused = false
    local proposed_interrupt = nil
    local interaction_interrupt = nil
    local pending_proposal = nil
    local interrupt_confirmed = false
    local saw_run_started = false
    local status_gauge = nil

    local function stream_event(e)
      if type(e) == "table" and e.type == "RUN_STARTED" then saw_run_started = true end
      local status_handled, next_gauge, status_problem = consume_status_event(
        status_gauge,
        e,
        thread_id,
        opts and opts.workerId,
        dispatch)
      status_gauge = next_gauge
      if status_problem ~= nil then
        run_problem = status_problem
        problem_dispatched = true
        final = status_problem.status
        return
      end
      if status_handled then return end
      if type(e) == "table" and e.type == "RUN_ERROR" then
        saw_run_error = true
        if type(run_problem) == "table" then final = tonumber(run_problem.status) end
        return
      end
      if type(e) == "table" and e.type == "RUN_FINISHED" then
        local interaction = unproject(e, tool, thread_id, opts and opts.workerId)
        if interaction ~= nil and interaction.method == "loop/interaction" then
          paused = true
          interaction_interrupt = "int:" .. tostring(interaction.params.interactionId)
        end
        local outcome = e.outcome
        if interaction_interrupt ~= nil then
          if not agui.has_interrupt(outcome, interaction_interrupt) then
            paused = false
            run_problem = agui.transport_problem(
              "interrupt-mismatch",
              "Interrupt mismatch",
              502,
              "The interaction ended without its matching AG-UI interrupt outcome.",
              false,
              "interaction-resolution",
              { interactionId = tonumber(interaction_interrupt:sub(5)) }
            )
            final = run_problem.status
          else
            interrupt_confirmed = true
            pcall(dispatch.handle_notification, interaction)
          end
        elseif proposed_interrupt ~= nil then
          if not agui.has_interrupt(outcome, proposed_interrupt) then
            paused = false
            run_problem = agui.transport_problem(
              "interrupt-mismatch",
              "Interrupt mismatch",
              502,
              "The proposal ended without its matching AG-UI interrupt outcome.",
              false,
              "proposal-resolution",
              { logEntryId = tonumber(proposed_interrupt:sub(6)) }
            )
            final = run_problem.status
          else
            interrupt_confirmed = true
            pcall(dispatch.handle_notification, pending_proposal)
          end
        elseif type(outcome) == "table" and outcome.type == "success" then
          final = plurnk_status or 200
        else
          final = 502
        end
        return
      end
      local n = unproject(e, tool, thread_id, opts and opts.workerId)
      if n == nil then return end
      if n.method == "loop/proposal" then
        paused = true
        proposed_interrupt = "prop:" .. tostring(n.params.logEntryId)
        pending_proposal = n
        active.proposal_id = n.params.logEntryId
        return
      elseif n.method == "loop/interaction" then
        paused = true
        interaction_interrupt = "int:" .. tostring(n.params.interactionId)
      elseif n.method == "problem/event" and type(n.params) == "table" then
        run_problem = n.params.problem
        problem_dispatched = true
      end
      if n.method == "loop/terminated" then
        paused = false
        proposed_interrupt = nil
        interaction_interrupt = nil
        local result = type(n.params) == "table" and n.params.result or nil
        local terminal_problem
        plurnk_status, terminal_problem = agui.operation_result(result)
        if type(result) == "table" then
          result.status = plurnk_status
          if terminal_problem ~= nil then result.problem = terminal_problem end
        end
        if terminal_problem ~= nil then
          run_problem = terminal_problem
        end
        if terminal_problem ~= nil and not problem_dispatched then
          problem_dispatched = true
          pcall(dispatch.handle_notification, {
            method = "problem/event",
            params = { problem = terminal_problem },
          })
        end
      end
      pcall(dispatch.handle_notification, n)
    end

    local function stream_done(_, transport_error)
      if final == nil and not interrupt_confirmed and transport_error ~= nil then
        run_problem = transport_error
      elseif final == nil and not interrupt_confirmed and run_problem == nil then
        run_problem = saw_run_error
            and agui.transport_problem(
              "problem-missing",
              "Problem missing",
              502,
              "The AG-UI stream reported a failed run without its required Problem Details.",
              false
            )
            or agui.transport_problem(
                "terminal-missing",
                "Terminal missing",
                502,
                "The AG-UI stream ended before reporting the run outcome.",
                true,
                "stream-reconciliation",
                { recovery = "Reconnect to observe durable state; do not replay the prompt." }
              )
      end

      -- A confirmed interrupt is the normal terminate/resume boundary. Its
      -- delayed completion is local to this stream and cannot inspect a later
      -- stream's state.
      if interrupt_confirmed and run_problem == nil then return end

      settle_reasoning(tool, thread_id, opts and opts.workerId, dispatch)

      -- An unterminalled stream is recoverable observation loss. The daemon has
      -- already received the hangup as cancellation; only read-only state/log
      -- reconciliation is legal here. Never submit the prompt a second time.
      local recoverable = saw_run_started and final == nil and not saw_run_error
          and type(run_problem) == "table"
          and (run_problem.kind == "terminal-missing"
            or run_problem.kind == "stream-read-failed"
            or run_problem.kind == "event-stream-empty"
            or (run_problem.source == "client:connection" and run_problem.retryable == true))
      if recoverable then
        if active_runs[thread_id] == active then active_runs[thread_id] = nil end
        require("plurnk.recovery").reconcile(thread_id, {
          workerId = opts and opts.workerId,
          cause = run_problem,
        }, function(status)
          if on_done then on_done(status or 502) end
        end)
        return
      end

      if run_problem ~= nil and final == nil then final = tonumber(run_problem.status) or 502 end
      if type(run_problem) == "table" and not problem_dispatched then
        problem_dispatched = true
        pcall(dispatch.handle_notification, {
          method = "problem/event",
          params = { problem = run_problem },
        })
      end
      if active_runs[thread_id] == active then active_runs[thread_id] = nil end
      if not paused and on_done then on_done(final or 502) end
    end

    return stream_event, stream_done
  end

  -- Resume streams render into the same worker waterfall, but their transport
  -- callbacks remain bound to their own segment evidence.
  active.begin_resume = bind_stream
  local stream_event, stream_done = bind_stream()
  active_runs[thread_id] = active
  return agui.run(t, { threadId = thread_id, prompt = prompt, forwardedProps = opts and opts.forwardedProps or nil },
    stream_event, stream_done)
end

-- A verb is a §3 action run. cb(result, problem); an action error surfaces as a notify —
-- honest, never silent. The action stream ALSO carries any events the dispatch
-- emits (log/entry from a client op, a proposal from a gated EXEC, stream chunks)
-- — feed them through the same unproject→dispatch path as a run, or client ops
-- would render nothing and gated ops would hang unresolved.
-- ONE management lane: an interrupted action retains the lane until its resume
-- produces the action result. Other actions queue; the resolution that continues
-- the lane owner runs inside that lane rather than deadlocking behind itself.
local lane = { busy = false, queue = {}, action = nil }
local function lane_next()
  local job = table.remove(lane.queue, 1)
  if job == nil then lane.busy = false; return end
  job()
end
local function lane_run(job)
  if lane.busy then lane.queue[#lane.queue + 1] = job; return end
  lane.busy = true
  job()
end

local function bridge_problem(kind, title, detail)
  return agui.transport_problem(kind, title, 502, detail, false)
end

local function notify_action_failure(method, problem)
  if type(problem) == "table"
      and problem.source == "client:connection"
      and problem.kind == "refused" then
    vim.notify(table.concat({
      "plurnk: no daemon is running - the plurnk client connects to one.",
      "  Quick start (no install):  npx @plurnk/plurnk-service start",
      "  Or install it:             npm i -g @plurnk/plurnk-service && plurnk-service",
    }, "\n"), vim.log.levels.WARN)
    return
  end
  local message = type(problem) == "table"
      and tostring(problem.detail or problem.title or "action failed")
      or tostring(problem)
  local recovery = type(problem) == "table" and problem.recovery or nil
  vim.notify("plurnk: " .. method .. " - " .. message
    .. (type(recovery) == "string" and ("\n  " .. recovery) or ""), vim.log.levels.WARN)
end

local resume_action

local function finish_action(action, result, problem)
  if lane.action ~= action then return end
  lane.action = nil
  if problem ~= nil and not action.problem_dispatched and not action.quiet then
    notify_action_failure(action.method, problem)
  end
  if action.cb then action.cb(result, problem, action.status_gauge) end
  vim.schedule(lane_next)
end

local function finish_resolution(resolution, segment)
  if resolution == nil or resolution.cb == nil then return end
  if segment.state == "failed" then
    resolution.cb(nil, segment.problem)
  else
    resolution.cb(segment.code, nil)
  end
end

local function accept_action_segment(action, segment, resolution)
  if lane.action ~= action then return end
  finish_resolution(resolution, segment)
  if action.problem ~= nil then
    finish_action(action, nil, action.problem)
    return
  end
  if segment.state == "failed" then
    finish_action(action, nil, segment.problem)
    return
  end
  if segment.state == "complete" then
    finish_action(action, segment.result, nil)
    return
  end
  local interrupt_id = action.proposal_id ~= nil and ("prop:" .. tostring(action.proposal_id)) or nil
  if interrupt_id == nil or not agui.has_interrupt(segment.outcome, interrupt_id) then
    finish_action(action, nil, bridge_problem(
      "action-interrupt-mismatch",
      "Action interrupt mismatch",
      "The action proposal did not match the AG-UI interrupt outcome."
    ))
    return
  end
  action.phase = "paused"
  if action.resolution ~= nil then resume_action(action) end
end

local function action_event(action, e)
  local status_handled, next_gauge, status_problem = consume_status_event(
    action.status_gauge,
    e,
    action.thread_id,
    action.worker_id,
    action.dispatch,
    action.quiet)
  action.status_gauge = next_gauge
  if status_problem ~= nil then
    action.problem = status_problem
    action.problem_dispatched = true
    return
  end
  if status_handled then return end
  local n = unproject(e, action.tool, action.thread_id, action.worker_id)
  if n == nil then return end
  if n.method == "loop/proposal" then
    action.proposal_id = n.params.logEntryId
  elseif n.method == "problem/event" and type(n.params) == "table" then
    action.problem = n.params.problem
    action.problem_dispatched = not action.quiet
    if action.quiet then return end
  end
  pcall(action.dispatch.handle_notification, n)
end

resume_action = function(action)
  local resolution = action.resolution
  action.resolution = nil
  action.proposal_id = nil
  action.phase = "running"
  agui.resume_action(action.target, vim.tbl_extend(
    "force",
    { threadId = action.thread_id },
    resolution.params
  ), function(segment)
    accept_action_segment(action, segment, resolution)
  end, function(e)
    action_event(action, e)
  end)
end

function M.rpc(thread_id, method, params, cb, options)
  local t = M.target()
  local dispatch = require("plurnk.dispatch")
  lane_run(function()
    local action = {
      thread_id = thread_id,
      worker_id = require("plurnk.state").get_worker_id(thread_id),
      method = method,
      cb = cb,
      target = t,
      dispatch = dispatch,
      tool = {},
      phase = "running",
      proposal_id = nil,
      resolution = nil,
      problem = nil,
      problem_dispatched = false,
      status_gauge = nil,
      quiet = options and options.quiet == true,
    }
    lane.action = action
    agui.rpc(t, thread_id, method, params, function(segment)
      accept_action_segment(action, segment, nil)
    end, function(e)
      action_event(action, e)
    end)
  end)
end

-- Answer a stopped-world client interaction: the tool-result resume run.
-- The payload is the standard answer; "cancel" cancels the paused run.
function M.resolve_interaction(thread_id, interaction_id, payload, cb)
  local t = M.target()
  if t == nil then
    if cb then cb(nil, bridge_problem("target-unavailable", "Target unavailable", "No bridge target is configured.")) end
    return
  end
  local a = active_runs[thread_id]
  local dispatch = require("plurnk.dispatch")
  local tool = {}
  local worker_id = require("plurnk.state").get_worker_id(thread_id)
  local detached_gauge = nil
  local on_event, on_done
  if a ~= nil and a.thread_id == thread_id then
    on_event, on_done = a.begin_resume()
  else
    on_event = function(e)
      local handled, next_gauge = consume_status_event(detached_gauge, e, thread_id, worker_id, dispatch)
      detached_gauge = next_gauge
      if handled then return end
      local n = unproject(e, tool, thread_id, worker_id)
      if n ~= nil then pcall(dispatch.handle_notification, n) end
    end
    on_done = function(_) end
  end
  agui.resolve_interaction(t, thread_id, interaction_id, payload, on_event, function(code, transport_error)
    on_done(code, transport_error)
    if cb then cb(transport_error == nil and code or nil, transport_error) end
  end)
end

-- Answer a stopped-world proposal: the tool-result resume run. The continued
-- work's events (a loop's rows OR an action's exec streams + result) ride the
-- SAME unproject→dispatch path as every other stream — a loop run's registered
-- on_done still fires so its inflight state clears.
function M.resolve(thread_id, r, cb)
  local t = M.target()
  local action = lane.action
  if action ~= nil and action.thread_id == thread_id and action.proposal_id == r.logEntryId then
    if action.resolution ~= nil then
      local problem = bridge_problem(
        "proposal-already-resolved",
        "Proposal already resolved",
        "The action's active proposal already has a pending resolution."
      )
      notify_action_failure("loop.resolve", problem)
      if cb then cb(nil, problem) end
      return
    end
    action.resolution = { params = r, cb = cb }
    if action.phase == "paused" then resume_action(action) end
    return
  end
  local a = active_runs[thread_id]
  local action_proposal = action ~= nil and action.thread_id == thread_id and action.proposal_id or nil
  local loop_proposal = a ~= nil and a.proposal_id or nil
  if (action_proposal ~= nil or loop_proposal ~= nil) and loop_proposal ~= r.logEntryId then
    local problem = bridge_problem(
      "proposal-resolution-mismatch",
      "Proposal resolution mismatch",
      "The proposal resolution did not identify an active proposal on this thread."
    )
    notify_action_failure("loop.resolve", problem)
    if cb then cb(nil, problem) end
    return
  end
  local dispatch = require("plurnk.dispatch")
  local tool = {}
  local worker_id = require("plurnk.state").get_worker_id(thread_id)
  local detached_gauge = nil
  local on_event, on_done
  if a ~= nil and a.thread_id == thread_id then
    on_event, on_done = a.begin_resume()
  else
    on_event = function(e)
      local handled, next_gauge = consume_status_event(detached_gauge, e, thread_id, worker_id, dispatch)
      detached_gauge = next_gauge
      if handled then return end
      local n = unproject(e, tool, thread_id, worker_id)
      if n ~= nil then pcall(dispatch.handle_notification, n) end
    end
    on_done = function(_) end
  end
  -- A model loop is independent of the serialized management-action lane. Its
  -- proposal resume stays on that loop's own stream even while an unrelated
  -- action on the same thread is still draining.
  agui.resolve(t, vim.tbl_extend("force", { threadId = thread_id }, r), on_event, function(code, transport_error)
    on_done(code, transport_error)
    if cb then cb(transport_error == nil and code or nil, transport_error) end
  end)
end

return M
