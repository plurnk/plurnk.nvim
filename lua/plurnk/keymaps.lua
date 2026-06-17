-- Default keymaps. The layout mirrors rummy.nvim/main/lua/rummy/keymaps.lua
-- so muscle memory carries over. Plurnk-only differences:
--   * The `?` / `:` / `!` mode prefixes have no mode semantics (the model
--     decides what ops to emit) — they are stripped and the rest is sent
--     as a plain prompt. Users still get to type `<leader>a?` and have
--     things work.
--   * Skills, temperature, context-mgmt, fork, file-attribute commands are
--     dropped per AGENTS.md.

local M = {}

local function map_if_empty(modes, lhs, rhs, desc)
  if type(modes) == "string" then modes = { modes } end
  for _, m in ipairs(modes) do
    if vim.fn.mapcheck(lhs, m) ~= "" then return end
  end
  vim.keymap.set(modes, lhs, rhs, { silent = false, desc = desc })
end

M.setup = function()
  -- ── Prompt entry (rummy mode-prefix layout, plurnk strips the prefix) ──
  -- <leader>aa is normal-mode only: in visual mode it would drop the
  -- selection silently because `:AI` with no args opens the input buffer.
  -- Selection-aware prompts go through <leader>a? / a: / a! instead.
  map_if_empty("n",          "<leader>aa", ":AI<CR>",     "Plurnk: chat (open input)")
  map_if_empty({ "n", "x" }, "<leader>a?", ":AI? ",      "Plurnk: prompt (rummy: ask)")
  map_if_empty({ "n", "x" }, "<leader>a:", ":AI: ",      "Plurnk: prompt (rummy: act)")
  map_if_empty({ "n", "x" }, "<leader>a!", ":AI! ",      "Plurnk: prompt (rummy: run)")
  map_if_empty("n",          "<leader>aN", ":AI?? ",     "Plurnk: new session + prompt")
  map_if_empty("n",          "<leader>ax", ":AI/stop<CR>",  "Plurnk: cancel pending")
  map_if_empty("n",          "<leader>aX", ":AI/clear<CR>", "Plurnk: cancel pending")

  -- ── Pickers / settings ──
  map_if_empty("n", "<leader>am", ":PlurnkModels<CR>",       "Plurnk: Models")
  map_if_empty("n", "<leader>as", ":PlurnkSessions<CR>",     "Plurnk: Sessions")
  map_if_empty("n", "<leader>aR", ":PlurnkSessionRuns<CR>",  "Plurnk: Runs in session")
  map_if_empty("n", "<leader>aL", ":PlurnkLog<CR>",          "Plurnk: Log")
  map_if_empty("n", "<leader>aO", ":PlurnkOpen<CR>",         "Plurnk: Open session tab")
  map_if_empty("n", "<leader>aY", ":PlurnkYolo<CR>",         "Plurnk: Toggle YOLO")

  -- ── Membership overlay (svc#200) — keymap acts on the CURRENT file (one
  -- keystroke); `:PlurnkPick <glob>` takes a glob (native file completion). ──
  map_if_empty("n", "<leader>ap", ":PlurnkPick<CR>",        "Plurnk: pick (admit) this file")
  map_if_empty("n", "<leader>ah", ":PlurnkHide<CR>",        "Plurnk: hide this file")
  map_if_empty("n", "<leader>av", ":PlurnkView<CR>",        "Plurnk: view (read-only) this file")
  map_if_empty("n", "<leader>ad", ":PlurnkDrop<CR>",        "Plurnk: drop this file's constraints")
  map_if_empty("n", "<leader>aM", ":PlurnkMembers<CR>",     "Plurnk: list members")

  -- ── Proposal review (matches rummy a-y / a-e / a-n / a-] / a-[) ──
  map_if_empty("n", "<leader>ay", ":PlurnkAccept<CR>",       "Plurnk: Accept proposal")
  map_if_empty("n", "<leader>ae", ":PlurnkAcceptEdits<CR>",  "Plurnk: Accept with edits")
  map_if_empty("n", "<leader>an", ":PlurnkReject<CR>",       "Plurnk: Reject proposal")
  map_if_empty("n", "<leader>a]", ":PlurnkNext<CR>",         "Plurnk: Next proposal")
  map_if_empty("n", "<leader>a[", ":PlurnkPrev<CR>",         "Plurnk: Prev proposal")
end

return M
