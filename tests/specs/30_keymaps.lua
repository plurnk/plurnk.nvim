-- [§nvim-vim-conventions]
-- Default keymaps converge the verb set into nvim. Verifies the set is applied,
-- including the new fork shortcut (run > loop > turn > op).
local NAME = "30_keymaps"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  vim.g.mapleader = ","                       -- expanded into the lhs at set time
  require("plurnk").apply_default_keymaps()
  local function rhs(lhs) return vim.fn.maparg(lhs, "n") end

  H.assert_match(rhs(",af"), "PlurnkFork", "<leader>af → fork (new run) — the added shortcut")
  -- a representative slice of the already-converged set, as a regression guard
  H.assert_match(rhs(",ap"), "PlurnkPick", "<leader>ap → pick")
  H.assert_match(rhs(",aM"), "PlurnkMembers", "<leader>aM → members")
  H.assert_match(rhs(",am"), "PlurnkModels", "<leader>am → models")
  H.assert_match(rhs(",aY"), "PlurnkYolo", "<leader>aY → yolo")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
