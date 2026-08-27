-- {§nvim-stream-recovery}: a broken message stream never leaves a truthful-
-- looking running gauge. The client re-observes durable state through ordinary
-- log.read action runs, replaces the transcript once, and never replays the
-- prompt. Exhausted reconciliation becomes an explicit stale connection that a
-- later manual reconciliation can clear.
local NAME = "52_stream_recovery"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local function gauge(lifecycle, packets)
  return {
    plurnk = { status = {
      lifecycle = lifecycle,
      model = { alias = "deepdumb", provider = "deepseek", model = "deepseek-v4-flash" },
      loopId = 7,
      packetCount = packets,
      activity = vim.NIL,
    } },
    budget = {},
  }
end

local ok, err = pcall(function()
  local agui = require("plurnk.agui")
  local bridge = require("plurnk.bridge")
  local dispatch = require("plurnk.dispatch")
  local state = require("plurnk.state")
  local worker_tab = require("plurnk.worker_tab")
  local original_run = agui.run
  local original_rpc = agui.rpc
  local original_dispatch = dispatch.handle_notification
  local original_append = worker_tab.append_history
  local original_begin = worker_tab.begin_reasoning
  local original_delta = worker_tab.append_reasoning_delta
  local original_end = worker_tab.end_reasoning

  local recovery_calls, prompts, proposals, problems = 0, 0, 0, 0
  local hydrated, reasoning = {}, { begins = 0, deltas = 0, ends = 0 }
  worker_tab.append_history = function(workspace, entries)
    hydrated[#hydrated + 1] = { workspace = workspace, entries = entries }
  end
  worker_tab.begin_reasoning = function() reasoning.begins = reasoning.begins + 1 end
  worker_tab.append_reasoning_delta = function() reasoning.deltas = reasoning.deltas + 1 end
  worker_tab.end_reasoning = function() reasoning.ends = reasoning.ends + 1 end
  dispatch.handle_notification = function(notification)
    if notification.method == "loop/proposal" then proposals = proposals + 1 end
    if notification.method == "problem/event" then problems = problems + 1 end
    original_dispatch(notification)
  end

  state.set_worker_id("recover", 42)
  state.set_loop_inflight("recover", true)
  agui.run = function(_, run, on_event, on_done)
    prompts = prompts + (run.prompt ~= nil and 1 or 0)
    on_event({ type = "RUN_STARTED" })
    on_event({ type = "STATE_SNAPSHOT", snapshot = gauge("running", 1) })
    on_event({ type = "REASONING_MESSAGE_START", messageId = "7/2/SEND/reasoning", role = "reasoning" })
    on_event({ type = "REASONING_MESSAGE_CONTENT", messageId = "7/2/SEND/reasoning", delta = "partial thought" })
    on_event({ type = "TOOL_CALL_START", toolCallId = "prop:99", toolCallName = "request_approval" })
    on_event({ type = "TOOL_CALL_ARGS", toolCallId = "prop:99", delta = '{"op":"EDIT"}' })
    on_event({ type = "TOOL_CALL_END", toolCallId = "prop:99" })
    on_done(18, nil) -- curl observed a truncated response; no AG-UI terminal.
    return { kill = function() end }
  end
  agui.rpc = function(_, _, method, params, cb, on_event)
    H.assert_eq(method, "log.read", "reconciliation uses the public durable-log action")
    H.assert_eq(params.workerId, 42, "reconciliation stays on the bound worker")
    recovery_calls = recovery_calls + 1
    on_event({ type = "STATE_SNAPSHOT", snapshot = gauge(recovery_calls == 1 and "running" or "completed", recovery_calls) })
    cb({ state = "complete", result = { entries = { { id = recovery_calls } } }, code = 0 })
  end

  local final
  bridge.run("recover", "do not replay me", { workerId = 42 }, function(status)
    final = status
    state.set_loop_inflight("recover", false)
  end)
  H.wait_for(function() return final ~= nil end, 3000, "bounded reconciliation reaches durable terminal state")
  H.assert_eq(final, 200, "recovered completed lifecycle settles the local run")
  H.assert_eq(prompts, 1, "the prompt is submitted exactly once")
  H.assert_eq(recovery_calls, 2, "a still-running cancellation race is observed again, not guessed")
  H.assert_eq(#hydrated, 1, "missing durable history is appended once after terminal truth")
  H.assert_eq(hydrated[1].entries[1].id, 2, "only the terminal observation is materialized")
  H.assert_eq(reasoning.begins, 1, "reasoning began")
  H.assert_eq(reasoning.deltas, 1, "partial reasoning rendered")
  H.assert_eq(reasoning.ends, 1, "partial reasoning settles when its stream dies")
  H.assert_eq(proposals, 0, "an unconfirmed interrupt never creates phantom review UI")
  H.assert_eq(problems, 0, "successful reconciliation does not fabricate a durable failure")
  H.assert_eq(state.get_transport_status("recover"), nil, "successful reconciliation clears the transport overlay")
  H.assert_eq(state.get_runtime_status("recover").lifecycle, "completed", "reconnected STATE remains runtime truth")

  -- A daemon that remains running through every bounded observation cannot be
  -- called recovered. It becomes explicitly stale until the same public action
  -- later supplies terminal truth.
  local stale_calls = 0
  state.set_worker_id("stale", 84)
  agui.run = function(_, run, on_event, on_done)
    prompts = prompts + (run.prompt ~= nil and 1 or 0)
    on_event({ type = "RUN_STARTED" })
    on_event({ type = "STATE_SNAPSHOT", snapshot = gauge("running", 1) })
    on_done(18, nil)
    return { kill = function() end }
  end
  agui.rpc = function(_, _, method, _, cb, on_event)
    H.assert_eq(method, "log.read", "stale recovery stays on the public action surface")
    stale_calls = stale_calls + 1
    on_event({ type = "STATE_SNAPSHOT", snapshot = gauge(stale_calls <= 3 and "running" or "failed", stale_calls) })
    cb({ state = "complete", result = { entries = {} }, code = 0 })
  end
  local stale_final
  bridge.run("stale", "one submission", { workerId = 84 }, function(status) stale_final = status end)
  H.wait_for(function() return stale_final ~= nil end, 3000, "bounded reconciliation exhausts")
  H.assert_eq(stale_calls, 3, "automatic reconciliation is bounded")
  H.assert_eq(stale_final, 502, "unreconciled stream is a client transport failure")
  H.assert_eq(state.get_transport_status("stale").phase, "stale", "failed recovery has explicit stale state")
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].plurnk_workspace = "stale"
  H.assert_eq(require("plurnk.statusline").text(), "⚠ stale", "stale state replaces the running spinner")
  H.assert_match(worker_tab.winbar_text("stale", 84), "stale", "the rich header names the connection failure")
  H.assert_eq(problems, 1, "exhaustion surfaces one durable Problem occurrence")

  local manual
  require("plurnk.recovery").reconcile("stale", { attempts = 1, delay_ms = 0 }, function(status) manual = status end)
  H.wait_for(function() return manual ~= nil end, 1000, "manual recovery")
  H.assert_eq(manual, 502, "manual recovery preserves the observed failed lifecycle")
  H.assert_eq(stale_calls, 4, "manual recovery performs one fresh public observation")
  H.assert_eq(state.get_transport_status("stale"), nil, "manual recovery clears stale connection state")
  H.assert_eq(state.get_runtime_status("stale").lifecycle, "failed", "manual recovery retains daemon lifecycle truth")

  agui.run = original_run
  agui.rpc = original_rpc
  dispatch.handle_notification = original_dispatch
  worker_tab.append_history = original_append
  worker_tab.begin_reasoning = original_begin
  worker_tab.append_reasoning_delta = original_delta
  worker_tab.end_reasoning = original_end
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
