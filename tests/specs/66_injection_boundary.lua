-- {§nvim-conversation-requests}: injection admission and stream termination commute.
local NAME = "66_injection_boundary"
local H = dofile(assert(os.getenv("PLURNK_NVIM_ROOT")) .. "/tests/helpers.lua")
H.setup()
local ok, err = pcall(function()
  local bridge, agui = require("plurnk.bridge"), require("plurnk.agui")
  local state = require("plurnk.state")
  state.set_worker_label("boundary", 71, "alice")
  local binding = state.binding("boundary", 71)
  local streams, actions, completions, histories = {}, {}, 0, 0
  local gauge = { budget = {}, plurnk = { status = {
    lifecycle = "completed", model = vim.NIL, loopId = 10, packetCount = 1, activity = vim.NIL,
  } } }
  agui.run = function(_, run, event, done)
    streams[#streams + 1] = { run = run, event = event, done = done }
    return {}
  end
  agui.rpc = function(_, owner, method, params, done, event)
    actions[#actions + 1] = { owner = owner, method = method, params = params, done = done, event = event }
    return {}
  end
  require("plurnk.worker_tab").append_history = function(world, entries)
    H.assert_eq(world, "boundary", "late history keeps its workspace")
    H.assert_eq(entries[1].worker_id, 71, "late history keeps its worker")
    H.assert_eq(#entries, 1, "already streamed rows are not duplicated during reconciliation")
    histories = histories + 1
  end
  local function terminal(stream)
    stream.event({ type = "RUN_FINISHED", outcome = { type = "success" } })
    stream.done(0)
  end
  local function admit(action, disposition)
    action.done({ state = "complete", result = { action = disposition, loopId = 11, turnSeq = 1 } })
  end
  bridge.run(binding, "original", {}, function() completions = completions + 1 end)
  bridge.inject(binding, "first")
  bridge.inject(binding, "second")
  terminal(streams[1])
  H.assert_eq(completions, 0, "terminal stream waits for already-submitted injection acknowledgements")
  admit(actions[2], "enqueued_new_loop")
  H.assert_eq(#streams, 1, "one remaining acknowledgement cannot race the observer")
  admit(actions[1], "injected_next_turn")
  H.assert_eq(completions, 1, "original run completes once")
  H.assert_eq(#streams, 2, "one observer follows the newly admitted loop")
  local observer = streams[2]
  H.assert_eq(observer.run.forwardedProps.mode, "sync", "follow-up is standard inference-free observation")
  H.assert_eq(observer.run.prompt, nil, "observation never resubmits a prompt")
  H.assert_eq(observer.run.workspace, "boundary", "observer retains workspace")
  H.assert_eq(observer.run.threadId, "alice", "observer retains conversation")
  state.set_last_seen_log_id("boundary", 71, 21)
  terminal(observer)
  H.assert_eq(actions[3].method, "log.read", "observation restores the admission-to-attachment gap")
  H.assert_eq(actions[3].params.sinceId, 0, "new live rows cannot advance past the unobserved admission gap")
  actions[3].event({ type = "STATE_SNAPSHOT", snapshot = gauge })
  actions[3].done({ state = "complete", result = { entries = { { id = 20, worker_id = 71 }, { id = 21, worker_id = 71 } } } })
  H.assert_eq(histories, 1, "the durable gap is materialized")
  H.assert_eq(state.is_loop_inflight("boundary", 71), false, "observed completion releases only Alice")

  bridge.run(binding, "again", {}, function() completions = completions + 1 end)
  bridge.inject(binding, "same loop")
  admit(actions[4], "injected_next_turn")
  terminal(streams[3])
  H.assert_eq(#streams, 3, "ordinary injection needs no second observer")
  H.assert_eq(completions, 2, "ordinary run completes once")

  bridge.inject(binding, "after terminal")
  admit(actions[5], "enqueued_new_loop")
  H.assert_eq(#streams, 4, "idle explicit injection observes its admitted loop")
  H.assert_eq(streams[4].run.prompt, nil, "idle injection is not replayed as another prompt")
end)
if ok then H.finish(NAME) else H.fail(NAME, err) end
