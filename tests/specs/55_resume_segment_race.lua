-- {§nvim-agui-interrupt-resume} AG-UI terminate/resume is one logical model run carried by two transport
-- segments. The interrupted segment may deliver its scheduled completion after
-- the human has already started the resume segment; that stale completion must
-- not corrupt or terminate the continuation.
local NAME = "55_resume_segment_race"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local agui = require("plurnk.agui")
  local bridge = require("plurnk.bridge")
  local dispatch = require("plurnk.dispatch")
  local original_run = agui.run
  local original_resolve = agui.resolve
  local original_dispatch = dispatch.handle_notification

  dispatch.handle_notification = function() end

  local interrupted_done
  agui.run = function(_, _, on_event, on_done)
    on_event({ type = "TOOL_CALL_START", toolCallId = "prop:23", toolCallName = "request_approval" })
    on_event({ type = "TOOL_CALL_ARGS", toolCallId = "prop:23", delta = '{"op":"EXEC"}' })
    on_event({ type = "TOOL_CALL_END", toolCallId = "prop:23" })
    on_event({
      type = "RUN_FINISHED",
      outcome = { type = "interrupt", interrupts = { { id = "prop:23" } } },
    })
    interrupted_done = on_done
    return {}
  end

  local statuses = {}
  bridge.run("world", "make a reviewed change", {}, function(status)
    statuses[#statuses + 1] = status
  end)
  H.assert_truthy(type(interrupted_done) == "function", "the interrupted segment remains independently settleable")

  agui.resolve = function(_, _, on_event, on_done)
    -- vim.system schedules this after the already-scheduled event callbacks. A
    -- fast approval can nevertheless begin this segment before that callback
    -- itself runs.
    interrupted_done(0, nil)
    on_event({ type = "CUSTOM", name = "plurnk.terminated", value = {
      result = { status = 200 }, hitMaxTurns = false,
    } })
    on_event({ type = "RUN_FINISHED", outcome = { type = "success" } })
    on_done(0, nil)
    return {}
  end

  local resolve_code, resolve_problem
  bridge.resolve("world", { logEntryId = 23, decision = "accept" }, function(code, problem)
    resolve_code, resolve_problem = code, problem
  end)

  H.assert_eq(#statuses, 1, "only the resumed terminal settles the logical model run")
  H.assert_eq(statuses[1], 200, "the stale interrupted completion cannot invent a failure")
  H.assert_eq(resolve_code, 0, "the resume transport settles normally")
  H.assert_eq(resolve_problem, nil, "the resume invents no transport Problem")

  agui.run = original_run
  agui.resolve = original_resolve
  dispatch.handle_notification = original_dispatch
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
