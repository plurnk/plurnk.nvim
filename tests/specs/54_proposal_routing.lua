-- {§nvim-agui-interrupt-resume} A model-loop proposal is owned by its interrupt identity, not merely by its
-- thread. An unrelated management action may still be draining on that thread
-- when the human resolves the model's proposal; it must neither steal nor block
-- the loop's resume run.
local NAME = "54_proposal_routing"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local agui = require("plurnk.agui")
  local bridge = require("plurnk.bridge")
  local dispatch = require("plurnk.dispatch")
  local original_rpc = agui.rpc
  local original_run = agui.run
  local original_resolve = agui.resolve
  local original_dispatch = dispatch.handle_notification

  local finish_action
  local action_result
  agui.rpc = function(_, _, _, _, callback)
    finish_action = callback
    return {}
  end
  bridge.rpc("world", "providers.list", {}, function(result) action_result = result end)
  H.assert_truthy(type(finish_action) == "function", "the unrelated action owns the management lane")

  dispatch.handle_notification = function() end
  local loop_status
  agui.run = function(_, _, on_event, on_done)
    on_event({ type = "TOOL_CALL_START", toolCallId = "prop:17", toolCallName = "request_approval" })
    on_event({ type = "TOOL_CALL_ARGS", toolCallId = "prop:17", delta = '{"op":"EXEC"}' })
    on_event({ type = "TOOL_CALL_END", toolCallId = "prop:17" })
    on_event({
      type = "RUN_FINISHED",
      outcome = { type = "interrupt", interrupts = { { id = "prop:17" } } },
    })
    on_done(0, nil)
    return {}
  end
  bridge.run("world", "make a reviewed change", {}, function(status) loop_status = status end)
  H.assert_eq(loop_status, nil, "the model loop remains paused at review")

  local resumed, resolve_code, resolve_problem
  agui.resolve = function(_, resolution, on_event, on_done)
    resumed = resolution
    on_event({ type = "CUSTOM", name = "plurnk.terminated", value = {
      result = { status = 200 }, hitMaxTurns = false,
    } })
    on_event({ type = "RUN_FINISHED", outcome = { type = "success" } })
    on_done(0, nil)
    return {}
  end
  bridge.resolve("world", { logEntryId = 17, decision = "accept" }, function(code, problem)
    resolve_code, resolve_problem = code, problem
  end)

  H.assert_eq(resumed.logEntryId, 17, "interrupt identity routes resolution to the model loop")
  H.assert_eq(loop_status, 200, "the model loop settles from its resumed stream")
  H.assert_eq(resolve_code, 0, "the model-loop resolution is acknowledged")
  H.assert_eq(resolve_problem, nil, "the unrelated action invents no mismatch Problem")
  H.assert_eq(action_result, nil, "resolving the model loop does not settle the unrelated action")

  finish_action({ state = "complete", result = { aliases = {} }, code = 0 })
  H.wait_for(function() return action_result ~= nil end, 1000, "unrelated action completes independently")

  agui.rpc = original_rpc
  agui.run = original_run
  agui.resolve = original_resolve
  dispatch.handle_notification = original_dispatch
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
