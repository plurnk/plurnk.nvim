-- -- Default keymaps converge the verb set into nvim with user-facing language,
-- not internal topology or membership implementation terms.
local NAME = "30_keymaps"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  vim.g.mapleader = ","                       -- expanded into the lhs at set time
  require("plurnk").apply_default_keymaps()
  local function rhs(lhs) return vim.fn.maparg(lhs, "n") end
  local function desc(lhs) return vim.fn.maparg(lhs, "n", false, true).desc end

  H.assert_match(rhs(",af"), "PlurnkFork", "<leader>af → fork (new worker) — the added shortcut")
  -- a representative slice of the already-converged set, as a regression guard
  H.assert_match(rhs(",ap"), "PlurnkPick", "<leader>ap → pick")
  H.assert_match(rhs(",aM"), "PlurnkMembers", "<leader>aM → members")
  H.assert_match(rhs(",am"), "PlurnkModels", "<leader>am → models")
  H.assert_match(rhs(",aY"), "PlurnkYolo", "<leader>aY → yolo")
  H.assert_match(desc(",af"), "new worker$", "fork description omits the inert topology mnemonic")
  H.assert_match(desc(",ap"), "pick — track file%(s%)$", "pick description uses the settled language")
  H.assert_match(desc(",ah"), "hide — hide file%(s%)$", "hide description uses the settled language")
  H.assert_match(desc(",av"), "view — track file%(s%) %(read%-only%)$", "view description uses the settled language")
  H.assert_match(desc(",ad"), "drop — no longer pick file%(s%)$", "drop description uses the settled language")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
