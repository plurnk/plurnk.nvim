-- Default keymaps. Plurnk doesn't have rummy's ask/act/run mode taxonomy,
-- so the keymap set is much smaller: one prompt key, a few pickers, yolo
-- toggle. Users override via require("plurnk").apply_default_keymaps or
-- by wiring their own.

local M = {}

-- mapcheck() requires a string mode; accept a table here and check each.
local function map_if_empty(modes, lhs, rhs, desc)
  if type(modes) == "string" then modes = { modes } end
  for _, m in ipairs(modes) do
    if vim.fn.mapcheck(lhs, m) ~= "" then return end
  end
  vim.keymap.set(modes, lhs, rhs, { silent = false, desc = desc })
end

M.setup = function()
  -- Plurnk prompt key — works in normal AND visual modes.
  map_if_empty({ "n", "x" }, "<leader>aa", ":PlurnkPrompt ", "Plurnk: Prompt")

  -- Pickers.
  map_if_empty("n", "<leader>am", ":PlurnkModels<CR>",       "Plurnk: Models")
  map_if_empty("n", "<leader>as", ":PlurnkSessions<CR>",     "Plurnk: Sessions")
  map_if_empty("n", "<leader>aR", ":PlurnkSessionRuns<CR>",  "Plurnk: Runs in session")

  -- Toggles.
  map_if_empty("n", "<leader>aY", ":PlurnkYolo<CR>",         "Plurnk: Toggle YOLO")
  map_if_empty("n", "<leader>aP", ":PlurnkPersona ",         "Plurnk: Persona file")

  -- New session.
  map_if_empty("n", "<leader>aN", ":PlurnkSessionNew<CR>",   "Plurnk: New session")

  -- Buffer/log inspection.
  map_if_empty("n", "<leader>aL", ":PlurnkLog<CR>",          "Plurnk: Log")
  map_if_empty("n", "<leader>aO", ":PlurnkOpen<CR>",         "Plurnk: Open session tab")
end

return M
