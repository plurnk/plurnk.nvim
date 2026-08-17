-- -- {§worker-model-selection} — server-backed model selection: /model persists
-- via worker.model.set onto the conversation worker and lights the statusline
-- from the resolved spec; /child persists via worker.child.set (inherit = alias
-- null); a bare /child reports the persisted policy. The one-shot pick applies
-- only before a workspace exists. Plus :AI cmdline completion.
local NAME = "28_model_completion"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local state = require("plurnk.state")
  local notices = {}
  local calls = {}
  require("plurnk.client").notify = function(message) notices[#notices + 1] = message end
  require("plurnk.client").check_daemon_once = function() end
  require("plurnk.client").send = function(method, params, _n, callback)
    calls[#calls + 1] = { method = method, params = params }
    if callback then
      if method == "worker.model.set" then
        callback({ alias = params.alias, provider = "openai", model = "x" })
      elseif method == "worker.child.set" then
        if params.alias == vim.NIL then callback(nil) else callback({ alias = params.alias }) end
      end
    end
  end
  require("plurnk.worker_tab").current_alias = function() return nil end
  state.set_active_workspace_name("ms")
  state.set_workspace_id("ms", 1)

  local cmds = require("plurnk.commands")

  -- :AI/model <alias> persists onto the worker server-side and mirrors the
  -- resolved spec; an attached workspace leaves no one-shot pick.
  cmds.set_model("gpt4")
  H.assert_eq(calls[#calls].method, "worker.model.set", "set_model persists server-side")
  H.assert_eq(calls[#calls].params.alias, "gpt4", "the alias is the parameter")
  H.assert_eq(state.get_model_alias("ms"), "gpt4", "the resolved alias lights the statusline")
  H.assert_eq(state.consume_selected_alias(), nil, "an attached workspace leaves no one-shot pick")

  cmds.set_child("gpt3")
  H.assert_eq(calls[#calls].method, "worker.child.set", "set_child persists server-side")
  H.assert_eq(calls[#calls].params.alias, "gpt3")
  H.assert_eq(state.get_child_alias("ms"), "gpt3", "the persisted override lights the statusline")
  cmds.set_child("inherit")
  H.assert_eq(calls[#calls].params.alias, vim.NIL, "inherit clears the override (alias null)")
  H.assert_eq(state.get_child_alias("ms"), "inherit")
  cmds.set_child("")
  H.assert_eq(notices[#notices], "Child alias: inherit", "bare child reports the current policy")

  -- No workspace yet → the pick is one-shot, seeded once at creation.
  state.set_active_workspace_name(nil)
  cmds.set_model("gpt5")
  H.assert_eq(state.consume_selected_alias(), "gpt5", "no workspace yet → one-shot pick until create")
  state.set_active_workspace_name("ms")

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
