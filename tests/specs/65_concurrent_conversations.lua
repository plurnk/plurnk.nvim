-- {§nvim-conversation-requests}: concurrent streams and interrupts retain their owners.
local NAME = "65_concurrent_conversations"
local H = dofile(assert(os.getenv("PLURNK_NVIM_ROOT")) .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local agui, bridge = require("plurnk.agui"), require("plurnk.bridge")
  local state, dispatch = require("plurnk.state"), require("plurnk.dispatch")
  local streams, actions, notifications, statuses = {}, {}, {}, {}
  local function binding(world, id, name)
    state.set_worker_label(world, id, name)
    return state.binding(world, id)
  end
  local alice = binding("shared", 11, "alice")
  local bob = binding("shared", 12, "bob")
  local other_alice = binding("other", 13, "alice")
  dispatch.handle_notification = function(n) notifications[#notifications + 1] = n end
  agui.run = function(target, run, event, done)
    local stream = { target = target, run = run, event = event, done = done }
    streams[#streams + 1] = stream
    return { kill = function() stream.killed = true end }
  end
  agui.rpc = function(target, owner, method, params, done, event)
    actions[#actions + 1] = { target = target, owner = owner, method = method, params = params, done = done, event = event }
    return {}
  end
  agui.action_segment = function(target, run, done, event)
    actions[#actions + 1] = { target = target, run = run, done = done, event = event }
    return {}
  end
  for _, owner in ipairs({ alice, bob, other_alice }) do
    bridge.run(owner, "prompt for " .. owner.workspace .. "/" .. owner.threadId, { review = owner == alice },
      function(status) statuses[owner] = status end)
  end
  H.assert_eq(#streams, 3, "equal names in different workspaces are independent")
  for i, owner in ipairs({ alice, bob, other_alice }) do
    local wire = agui.input(streams[i].run)
    H.assert_eq(wire.threadId, owner.threadId, "model request names its conversation")
    H.assert_eq(wire.forwardedProps.plurnk.workspace, owner.workspace, "model request names its workspace")
  end
  local function proposal(stream, id)
    stream.event({ type = "TOOL_CALL_START", toolCallId = "prop:" .. id, toolCallName = "request_approval" })
    stream.event({ type = "TOOL_CALL_ARGS", toolCallId = "prop:" .. id, delta = '{"op":"sh"}' })
    stream.event({ type = "TOOL_CALL_END", toolCallId = "prop:" .. id })
    stream.event({ type = "RUN_FINISHED", outcome = { type = "interrupt", interrupts = { { id = "prop:" .. id } } } })
  end
  proposal(streams[1], 101)
  proposal(streams[2], 102)
  H.assert_eq(notifications[#notifications].params.binding, bob, "Bob's proposal keeps its origin")
  H.assert_eq(notifications[#notifications].params.reviewRequested, false, "Alice's explicit review does not leak")
  state.set_active_workspace_name("other")
  state.set_worker_id("other", 13)
  bridge.resolve(bob, { logEntryId = 102, decision = "accept" })
  local resumed = streams[4]
  H.assert_eq(resumed.run.threadId, "bob", "approval does not follow current selection")
  H.assert_eq(resumed.run.workspace, "shared", "approval retains the workspace")
  H.assert_eq(resumed.run.resume[1].interruptId, "prop:102", "approval retains the exact interrupt")
  streams[2].done(0) -- delayed completion of Bob's interrupted segment
  H.assert_eq(statuses[bob], nil, "stale segment cannot settle Bob")
  resumed.event({ type = "CUSTOM", name = "plurnk.terminated", value = { result = { status = 200 } } })
  resumed.event({ type = "RUN_FINISHED", outcome = { type = "success" } })
  resumed.done(0)
  H.assert_eq(statuses[bob], 200, "only Bob concludes")
  H.assert_eq(statuses[alice], nil, "Alice remains paused")
  H.assert_truthy(bridge.active(other_alice), "other workspace remains observed")

  local one, two
  bridge.rpc(alice, "op.exec", { command = "first" }, function(value) one = value end)
  bridge.rpc(alice, "ping", {}, function(value) two = value end)
  H.assert_eq(#actions, 2, "independent action is admitted immediately")
  proposal(actions[1], 103)
  actions[1].done({ state = "interrupted", outcome = { type = "interrupt", interrupts = { { id = "prop:103" } } } })
  actions[2].done({ state = "complete", result = { pong = true } })
  H.assert_truthy(two.pong, "inspection is not blocked by approval")
  H.assert_eq(one, nil, "inspection cannot settle the proposed action")
  bridge.cancel(alice)
  H.assert_eq(actions[3].method, "loop.cancel", "cancel goes to the daemon")
  H.assert_eq(actions[3].owner, alice, "cancel targets Alice")
  actions[3].done({ state = "complete", result = { cancelled = true } })
  H.assert_eq(statuses[alice], 499, "paused model request settles after cancellation")
  H.assert_eq(one, nil, "model cancellation leaves the human action alone")
  bridge.resolve(alice, { logEntryId = 103, decision = "accept" })
  H.assert_eq(actions[4].run.resume[1].interruptId, "prop:103", "human action can still resume")
  actions[4].done({ state = "complete", result = { accepted = true } })
  H.assert_truthy(one.accepted, "human action completes independently")
  local stale
  bridge.resolve(alice, { logEntryId = 101, decision = "accept" }, function(_, failure) stale = failure end)
  H.assert_eq(stale.kind, "interrupt-not-pending", "late approval of cancelled work cannot restart it")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
