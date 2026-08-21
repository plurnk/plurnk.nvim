-- The nvim bridge transport mirrors the client's
-- BridgeTransport. When PLURNK_AGUI_URL is set, runs ride agui.run (curl -N SSE)
-- with each event un-projected into the SAME dispatch.handle_notification the WS
-- path feeds, so the worker-tab renders unchanged; verbs + resolve ride the
-- management + resolve endpoints. The threadId IS the workspace (workspace) name,
-- verbatim — no prefix, no forging (module §agui-thread-is-run: the workspace is the
-- world, the thread binds its model worker); workspace options ride the first run's forwardedProps.
local M = {}
local agui = require("plurnk.agui")

local function unproject(e, assembler, workspace_name, worker_id)
  local n = agui.unproject(e, assembler)
  if n ~= nil and n.method == "reasoning/message" then
    n.params.workspaceName = workspace_name
    if type(worker_id) == "number" then n.params.workerId = worker_id end
  end
  return n
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

-- Run a prompt through the bridge. Events un-project into the dispatcher (the
-- worker-tab renders identically to WS); on_done(finalStatus). Returns the vim.system
-- handle (handle:kill() = /stop, the bridge cancels on hangup).
function M.run(thread_id, prompt, opts, on_done)
  local t = M.target()
  if t == nil then return nil end
  local dispatch = require("plurnk.dispatch")
  local final = nil
  local run_problem = nil
  local saw_run_error = false
  local problem_dispatched = false
  local plurnk_status = nil -- family metadata; AG-UI terminal events own lifecycle
  local tool = {}   -- the TOOL_CALL triple assembler (interrupt/resume proposals)
  local paused = false
  local proposed_interrupt = nil
  local interaction_interrupt = nil
  local on_event
  on_event = function(e)
    if type(e) == "table" and e.type == "RUN_ERROR" then
      saw_run_error = true
      if type(run_problem) == "table" then final = tonumber(run_problem.status) end
      return
    end
    if type(e) == "table" and e.type == "RUN_FINISHED" then
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
    elseif n.method == "loop/interaction" then
      paused = true
      interaction_interrupt = "int:" .. tostring(n.params.interactionId)
    elseif n.method == "problem/event" and type(n.params) == "table" then
      run_problem = n.params.problem
      problem_dispatched = true
    end
    if n.method == "loop/terminated" then
      paused = false
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
  -- resolve.lua answers via M.resolve below; the resume run's events feed the SAME
  -- on_event/on_done, so the worker-tab renders the continuation seamlessly.
  M._active = { thread_id = thread_id, on_event = on_event, on_done = function(_, transport_error)
    if transport_error ~= nil then
      run_problem = transport_error
      final = tonumber(transport_error.status) or 500
      local recovery = type(transport_error.recovery) == "string" and ("\n  " .. transport_error.recovery) or ""
      vim.notify("plurnk: " .. tostring(transport_error.detail or transport_error.title or "request failed") .. recovery, vim.log.levels.ERROR)
    elseif not paused and final == nil then
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
            false
          )
      final = run_problem.status
      vim.notify("plurnk: " .. run_problem.detail, vim.log.levels.ERROR)
    end
    if type(run_problem) == "table" and not problem_dispatched then
      problem_dispatched = true
      pcall(dispatch.handle_notification, {
        method = "problem/event",
        params = { problem = run_problem },
      })
    end
    -- A stream that died without an AG-UI terminal is a broken wire — 502, never 200.
    if not paused and on_done then on_done(final or 502) end
  end }
  return agui.run(t, { threadId = thread_id, prompt = prompt, forwardedProps = opts and opts.forwardedProps or nil },
    on_event, M._active.on_done)
end

-- A verb is a §3 action run. cb(result); an action error surfaces as a notify —
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
  if problem ~= nil and not action.problem_dispatched then
    notify_action_failure(action.method, problem)
  end
  if action.cb then action.cb(result) end
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
  local n = unproject(e, action.tool, action.thread_id, action.worker_id)
  if n == nil then return end
  if n.method == "loop/proposal" then
    action.proposal_id = n.params.logEntryId
  elseif n.method == "problem/event" and type(n.params) == "table" then
    action.problem = n.params.problem
    action.problem_dispatched = true
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

function M.rpc(thread_id, method, params, cb)
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
  local a = M._active
  local dispatch = require("plurnk.dispatch")
  local tool = {}
  local worker_id = require("plurnk.state").get_worker_id(thread_id)
  local on_event = (a ~= nil and a.thread_id == thread_id) and a.on_event or function(e)
    local n = unproject(e, tool, thread_id, worker_id)
    if n ~= nil then pcall(dispatch.handle_notification, n) end
  end
  local on_done = (a ~= nil and a.thread_id == thread_id) and a.on_done or function(_) end
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
  if action ~= nil and action.thread_id == thread_id then
    if action.proposal_id ~= r.logEntryId then
      local problem = bridge_problem(
        "proposal-resolution-mismatch",
        "Proposal resolution mismatch",
        "The proposal resolution did not identify the action's active proposal."
      )
      notify_action_failure("loop.resolve", problem)
      if cb then cb(nil, problem) end
      return
    end
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
  local a = M._active
  local dispatch = require("plurnk.dispatch")
  local tool = {}
  local worker_id = require("plurnk.state").get_worker_id(thread_id)
  local on_event = (a ~= nil and a.thread_id == thread_id) and a.on_event or function(e)
    local n = unproject(e, tool, thread_id, worker_id)
    if n ~= nil then pcall(dispatch.handle_notification, n) end
  end
  local on_done = (a ~= nil and a.thread_id == thread_id) and a.on_done or function(_) end
  -- The resume run rides the same lane: its rebound stream carries the continued
  -- work's events (exec output, loop rows) — nothing may steal the binding mid-run.
  lane_run(function()
    agui.resolve(t, vim.tbl_extend("force", { threadId = thread_id }, r), on_event, function(code, transport_error)
      vim.schedule(lane_next)
      on_done(code, transport_error)
      if cb then cb(transport_error == nil and code or nil, transport_error) end
    end)
  end)
end

return M
