-- [§nvim-alias-resolution]
-- #90: client-side alias resolution — resolve PLURNK_MODEL_<alias> to
-- "<provider>/<model>" from nvim's fresh env, sent as loop.run.model so a stale
-- long-lived daemon can't reject "unknown alias". Case-folded suffix; the model
-- id may itself contain "/"; nil when this env declares no such alias.
local NAME = "31_model_spec_resolution"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local commands = require("plurnk.commands")
  vim.env.PLURNK_MODEL_ccp = "anthropic/claude-x"
  vim.env.PLURNK_MODEL_OR = "openrouter/anthropic/claude-sonnet"  -- model id contains "/"
  H.assert_eq(commands.resolve_model_spec("ccp"), "anthropic/claude-x", "resolves to provider/model")
  H.assert_eq(commands.resolve_model_spec("CCP"), "anthropic/claude-x", "alias suffix is case-folded")
  H.assert_eq(commands.resolve_model_spec("or"), "openrouter/anthropic/claude-sonnet", "model id containing / stays verbatim")
  H.assert_eq(commands.resolve_model_spec("nope"), nil, "undeclared alias → nil (fall back to bare alias)")
  H.assert_eq(commands.resolve_model_spec(""), nil, "empty alias → nil")
  vim.env.PLURNK_MODEL_ccp = nil
  vim.env.PLURNK_MODEL_OR = nil
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
