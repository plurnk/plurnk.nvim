-- -- Model selection sticks (persists past one loop) + :AI cmdline completion.
local NAME = "28_model_completion"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local state = require("plurnk.state")
  local notices = {}
  require("plurnk.client").notify = function(message) notices[#notices + 1] = message end
  require("plurnk.client").check_daemon_once = function() end
  require("plurnk.worker_tab").current_alias = function() return nil end
  state.set_active_workspace_name("ms")
  state.set_workspace_id("ms", 1)

  local cmds = require("plurnk.commands")

  -- :AI/model <alias> sets the model DURABLY (not just the one-shot pick) so it
  -- survives past the next loop — the "selecting a model doesn't change it" bug.
  cmds.set_model("gpt4")
  H.assert_eq(state.get_model_alias("ms"), "gpt4", "set_model persists the workspace model (sticky)")
  H.assert_eq(state.consume_selected_alias(), "gpt4", "set_model also sets the one-shot pick")

  cmds.set_child("gpt3")
  H.assert_eq(state.get_child_alias("ms"), "gpt3", "set_child persists the workspace child policy")
  H.assert_eq(state.consume_selected_child_alias(), "gpt3", "set_child also sets the next-loop pick")
  cmds.set_child("inherit")
  H.assert_eq(state.get_child_alias("ms"), "inherit", "inherit is an explicit client policy")
  cmds.set_child("")
  H.assert_eq(notices[#notices], "Child alias: inherit", "bare child reports the current policy")

  -- Completion: alias names after `/model `
  state.set_available_aliases({ { alias = "gpt4" }, { alias = "gpt3" }, { alias = "claude" } })
  local m = cmds.ai_complete("", "AI /model gp", 0)
  table.sort(m)
  H.assert_eq(table.concat(m, ","), "gpt3,gpt4", "completes model aliases by prefix after /model")

  local c = cmds.ai_complete("", "AI /child in", 0)
  H.assert_eq(table.concat(c, ","), "inherit", "child completion includes the inherit policy")

  -- Completion: slash verbs after a bare `/`
  local v = cmds.ai_complete("", "AI /mo", 0)
  local has_model, has_models = false, false
  for _, c in ipairs(v) do
    if c == "/model" then has_model = true end
    if c == "/models" then has_models = true end
  end
  H.assert_truthy(has_model and has_models, "completes slash verbs (/model, /models) after /mo")
  H.assert_eq(cmds.ai_complete("", "AI /ch", 0)[1], "/child", "completes the child verb")

  -- Completion: nothing once past the verb into a (non-model) arg
  local none = cmds.ai_complete("", "AI /pick src", 0)
  H.assert_eq(#none, 0, "no verb completion once past the verb")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
