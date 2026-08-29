local NAME = "32_workspace_capabilities"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local context = require("plurnk.workspace_context")
  H.assert_eq(context.settings().capabilities, nil, "workspace capabilities are optional")
  H.assert_truthy(vim.json.encode(require("plurnk.policy").base()):match('"capabilities":{}') ~= nil,
    "the default CapabilityPolicy crosses JSON as an object, never an empty array")

  require("plurnk.config").setup({ workspace_capabilities = {} })
  H.assert_truthy(vim.json.encode(context.settings()):match('"capabilities":{}') ~= nil,
    "an empty configured workspace CapabilityPolicy retains object identity")

  require("plurnk.config").setup({
    workspace_capabilities = { deny = { { runtime = "sh" } } },
  })
  local settings = context.settings()
  H.assert_eq(settings.capabilities.deny[1].runtime, "sh", "canonical workspace policy reaches creation settings")

  vim.env.PLURNK_EXECS_ONLY = "python"
  vim.env.PLURNK_EXECS_ONLY = nil
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
