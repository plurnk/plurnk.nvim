-- -- {§nvim-generation-policy-admission}: the real AG-UI action surface persists
-- a resolved route on the conversation worker. This is control-plane only; the
-- local test provider is never asked to generate.
local NAME = "47_model_selection_live"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local workspace = "nvim-model-" .. tostring(vim.uv.hrtime())
  local created = H.call("workspace.create", { name = workspace })
  H.assert_type(created, "table", "workspace.create result")
  H.assert_eq(created.name, workspace, "the named workspace is stable")

  local state = require("plurnk.state")
  state.set_active_workspace_name(workspace)
  state.set_workspace_id(workspace, created.id)

  local commands = require("plurnk.commands")
  local selector = "nvimtest"
  commands.set_model(selector)
  H.wait_for(function() return state.get_model_selector(workspace) == selector end, 5000, "model selection persisted")

  local durable = H.call("worker.model.get", {})
  H.assert_type(durable, "table", "worker.model.get result")
  H.assert_eq(durable.model.provider, "lmstudio", "the durable route retains its provider")
  H.assert_eq(durable.model.model, "nvim-family/selected", "the model id retains embedded path segments")
  H.assert_eq(durable.model.alias, "nvimtest", "the alias remains durable provenance")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
