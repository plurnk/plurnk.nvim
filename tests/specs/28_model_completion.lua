-- -- {§worker-model-selection} — server-backed selectors persist exact routes or
-- aliases on the conversation worker; child inherit is selector null. The model
-- picker lazily combines the small alias directory with bounded models.list pages.
local NAME = "28_model_completion"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local state = require("plurnk.state")
  local notices = {}
  local calls = {}
  local pages = {
    [0] = {
      items = { {
        selector = "google/gemini-3-flash",
        provider = "google",
        model = "gemini-3-flash",
        modelName = "Gemini 3 Flash",
      } },
      offset = 0,
      total = 2,
      nextOffset = 1,
    },
    [1] = {
      items = { {
        selector = "google/gemini-3-pro",
        provider = "google",
        model = "gemini-3-pro",
        modelName = "Gemini 3 Pro",
      } },
      offset = 1,
      total = 2,
    },
  }
  require("plurnk.client").notify = function(message) notices[#notices + 1] = message end
  require("plurnk.client").check_daemon_once = function() end
  require("plurnk.client").send = function(method, params, _n, callback)
    calls[#calls + 1] = { method = method, params = params }
    if not callback then return end
    if method == "providers.list" then
      callback({ aliases = { { alias = "gemini-local", provider = "openai", model = "x", active = true } } })
    elseif method == "models.list" then
      callback(pages[params.offset or 0])
    elseif method == "worker.model.set" then
      if params.selector == "broken/model" then
        callback(nil, {
          type = "https://problems.plurnk.dev/daemon/provider/unavailable",
          title = "Provider unavailable",
          status = 503,
          detail = "The selected provider is unavailable.",
        })
      elseif params.selector:find("/", 1, true) then
        local provider, model = params.selector:match("^([^/]+)/(.+)$")
        callback({ provider = provider, model = model })
      else
        callback({ alias = params.selector, provider = "openai", model = "x" })
      end
    elseif method == "worker.reasoning.get" then
      callback({ policy = "adaptive", supportedPolicies = { "off", "adaptive", "high" } })
    elseif method == "worker.child.set" then
      if params.selector == vim.NIL then callback(nil)
      elseif params.selector:find("/", 1, true) then
        local provider, model = params.selector:match("^([^/]+)/(.+)$")
        callback({ provider = provider, model = model })
      else callback({ alias = params.selector, provider = "openai", model = "child" }) end
    end
  end
  require("plurnk.worker_tab").current_alias = function() return nil end
  state.set_active_workspace_name("ms")
  state.set_workspace_id("ms", 1)

  local cmds = require("plurnk.commands")

  cmds.set_model("google/gemini-3-flash")
  H.assert_eq(calls[1].method, "worker.model.set", "set_model persists server-side")
  H.assert_eq(calls[1].params.selector, "google/gemini-3-flash", "the exact selector is the parameter")
  H.assert_eq(calls[2].method, "worker.reasoning.get", "model change refreshes supported reasoning choices")
  H.assert_eq(state.get_model_selector("ms"), "google/gemini-3-flash", "an exact route remains alias-free in display state")
  H.assert_eq(state.consume_selected_model_selector(), nil, "an attached workspace leaves no pending pick")

  cmds.set_model("gpt4")
  H.assert_eq(state.get_model_selector("ms"), "gpt4", "an alias keeps its provenance after server resolution")

  cmds.set_child("google/gemini-3-pro")
  H.assert_eq(calls[#calls].method, "worker.child.set", "set_child persists server-side")
  H.assert_eq(calls[#calls].params.selector, "google/gemini-3-pro")
  H.assert_eq(state.get_child_selector("ms"), "google/gemini-3-pro", "an exact child route remains exact")
  cmds.set_child("inherit")
  H.assert_eq(calls[#calls].params.selector, vim.NIL, "inherit clears the override (selector null)")
  H.assert_eq(state.get_child_selector("ms"), "inherit")
  cmds.set_child("")
  H.assert_eq(notices[#notices], "Child model: inherit", "bare child reports the current policy")

  -- No workspace yet → the selector is held only until workspace creation can
  -- persist it on the new conversation worker.
  state.set_active_workspace_name(nil)
  cmds.set_model("openai/gpt-5")
  H.assert_eq(state.consume_selected_model_selector(), "openai/gpt-5", "no workspace yet → pending selector until create")
  state.set_active_workspace_name("ms")

  -- The picker is lazy and bounded. Page one contains aliases + exact routes;
  -- choosing the continuation sentinel requests page two, then selects its route.
  local selections = 0
  vim.ui.select = function(items, _, callback)
    selections = selections + 1
    if selections == 1 then
      H.assert_eq(items[1].selector, "gemini-local", "declared aliases remain available for alias-scoped routes")
      H.assert_eq(items[2].selector, "google/gemini-3-flash", "the first bounded catalog page follows aliases")
      H.assert_eq(items[3].next_offset, 1, "the picker exposes a continuation sentinel")
      callback(items[3])
    else
      H.assert_eq(items[1].selector, "google/gemini-3-pro", "the next bounded page is materialized on demand")
      callback(items[1])
    end
  end
  calls = {}
  cmds.models("gemini")
  H.assert_eq(calls[1].method, "providers.list", "the alias directory is fetched only when the picker opens")
  H.assert_eq(calls[2].method, "models.list", "the model catalog is lazy")
  H.assert_eq(calls[2].params.search, "gemini", "picker search reaches the daemon")
  H.assert_eq(calls[2].params.limit, 50, "catalog requests are bounded")
  H.assert_eq(calls[3].method, "models.list", "the continuation fetches the next page")
  H.assert_eq(calls[3].params.offset, 1, "continuation preserves the daemon offset")
  H.assert_eq(calls[4].method, "worker.model.set", "a catalog choice uses the ordinary durable selector action")
  H.assert_eq(calls[4].params.selector, "google/gemini-3-pro")

  -- A pending deliberate selection is invocation admission. If the daemon
  -- rejects it, the prompt does not run on stale/default policy and the user's
  -- selection remains available to retry.
  local model_runs = 0
  local original_run = require("plurnk.bridge").run
  require("plurnk.bridge").run = function() model_runs = model_runs + 1 end
  state.set_selected_model_selector("broken/model")
  cmds.prompt({ args = "must not run", range = 0 })
  H.assert_eq(model_runs, 0, "a rejected pending model selection prevents inference")
  H.assert_eq(state.consume_selected_model_selector(), "broken/model", "the rejected selection remains pending")
  H.assert_match(notices[#notices], "prompt was not submitted", "the admission failure explains the prompt outcome")
  require("plurnk.bridge").run = original_run

  -- Completion stays intentionally small: aliases only. Exact catalog discovery
  -- is explicit through /models, never a startup-sized completion cache.
  state.set_available_aliases({ { alias = "gpt4" }, { alias = "gpt3" }, { alias = "claude" } })
  local m = cmds.ai_complete("", "AI /model gp", 0)
  table.sort(m)
  H.assert_eq(table.concat(m, ","), "gpt3,gpt4", "completes declared aliases by prefix after /model")

  local c = cmds.ai_complete("", "AI /child in", 0)
  H.assert_eq(table.concat(c, ","), "inherit", "child completion includes the inherit policy")

  local v = cmds.ai_complete("", "AI /mo", 0)
  local has_model, has_models = false, false
  for _, completion in ipairs(v) do
    if completion == "/model" then has_model = true end
    if completion == "/models" then has_models = true end
  end
  H.assert_truthy(has_model and has_models, "completes slash verbs (/model, /models) after /mo")
  H.assert_eq(cmds.ai_complete("", "AI /ch", 0)[1], "/child", "completes the child verb")

  local none = cmds.ai_complete("", "AI /pick src", 0)
  H.assert_eq(#none, 0, "no verb completion once past the verb")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
