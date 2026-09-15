-- {§nvim-conversation-requests}: asynchronous UI and cache work retain their destinations.
local NAME = "67_async_destinations"
local H = dofile(assert(os.getenv("PLURNK_NVIM_ROOT")) .. "/tests/helpers.lua")
H.setup()
local ok, err = pcall(function()
  local state, client = require("plurnk.state"), require("plurnk.client")
  local tabs = require("plurnk.worker_tab")
  state.set_workspace_id("shared", 1)
  state.set_worker_label("shared", 11, "alice")
  state.set_worker_label("shared", 12, "bob")
  local alice, bob = state.binding("shared", 11), state.binding("shared", 12)
  local calls = {}
  client.send = function(method, params, _, cb, options)
    calls[#calls + 1] = { method = method, params = params, cb = cb, binding = options and options.binding }
  end
  tabs.open("shared", 11)
  local choose
  vim.ui.select = function(_, _, callback) choose = callback end
  require("plurnk.generation").models("")
  calls[1].cb({ aliases = {} })
  calls[2].cb({ items = { { selector = "mock/selected" } } })
  tabs.open("shared", 12)
  choose({ selector = "mock/selected" })
  H.assert_eq(calls[3].method, "worker.model.set", "picker persists the selected model")
  H.assert_eq(calls[3].binding, alice, "picker remains Alice's after changing tabs")
  calls[3].cb({ provider = "mock", model = "selected" })
  H.assert_eq(state.get_model_selector("shared", 11), "mock/selected", "Alice owns the resulting policy")
  H.assert_eq(state.get_model_selector("shared", 12), nil, "Bob's policy is untouched")
  H.assert_eq(calls[4].binding, alice, "follow-up reasoning lookup stays with Alice")
  vim.cmd("enew")
  vim.b.plurnk_workspace = "another-workspace"
  H.assert_eq(require("plurnk.workspace_context").active(), "shared", "worker tab binding outranks a code buffer's old workspace association")
  H.assert_eq(require("plurnk.workspace_context").binding(), bob, "workspace and worker remain one coherent destination")

  local functionality = require("plurnk.functionality")
  functionality.remember_aliases("env", { { alias = "ALICE_ONLY" } }, alice)
  functionality.remember_aliases("env", { { alias = "BOB_ONLY" } }, bob)
  H.assert_eq(functionality.complete_aliases("env", "")[1], "BOB_ONLY", "Bob sees his own environment names")
  functionality.invalidate_aliases("env", alice)
  H.assert_eq(functionality.complete_aliases("env", "")[1], "BOB_ONLY", "Alice's late mutation does not invalidate Bob")

  local dispatch, shown = require("plurnk.dispatch"), 0
  require("plurnk.resolve").process = function() shown = shown + 1 end
  dispatch.handle_notification({ method = "loop/proposal", params = { binding = alice, workspaceName = "shared", logEntryId = 101 } })
  dispatch.handle_notification({ method = "interrupt/ended", params = { binding = alice, workspaceName = "shared", interruptId = "prop:101" } })
  vim.wait(20, function() return false end)
  H.assert_eq(shown, 0, "cancel before scheduled presentation does not open a dead review")
  dispatch.handle_notification({ method = "loop/proposal", params = { binding = alice, workspaceName = "shared", logEntryId = 101 } })
  H.wait_for(function() return shown == 1 end, 1000, "a newly pending occurrence can be presented")
end)
if ok then H.finish(NAME) else H.fail(NAME, err) end
