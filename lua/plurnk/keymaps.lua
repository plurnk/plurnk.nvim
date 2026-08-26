-- Default keymaps for prompt entry, settings, membership, and proposal review.

local M = {}

local function map_if_empty(modes, lhs, rhs, desc)
  if type(modes) == "string" then modes = { modes } end
  for _, m in ipairs(modes) do
    if vim.fn.mapcheck(lhs, m) ~= "" then return end
  end
  vim.keymap.set(modes, lhs, rhs, { silent = false, desc = desc })
end

M.setup = function()
  -- ── Prompt entry ──
  -- <leader>aa is normal-mode only: in visual mode it would drop the
  -- selection silently because `:AI` with no args opens the input buffer.
  -- Selection-aware prompts go through <leader>a? / a: / a! instead.
  map_if_empty("n",          "<leader>aa", ":AI<CR>",     "Plurnk: chat (open input)")
  map_if_empty({ "n", "x" }, "<leader>a?", ":AI? ",      "Plurnk: ask prompt")
  map_if_empty({ "n", "x" }, "<leader>a:", ":AI: ",      "Plurnk: act prompt")
  map_if_empty({ "n", "x" }, "<leader>a!", ":AI! ",      "Plurnk: exec command")
  map_if_empty("n",          "<leader>aN", ":AI?? ",     "Plurnk: new workspace + prompt")
  map_if_empty("n",          "<leader>af", ":PlurnkFork<CR>", "Plurnk: fork — new worker (workspace>worker>loop>turn>op)")
  map_if_empty("n",          "<leader>ax", ":AI/stop<CR>",  "Plurnk: cancel pending")
  map_if_empty("n",          "<leader>aX", ":AI/clear<CR>", "Plurnk: cancel pending")

  -- ── Pickers / settings ──
  map_if_empty("n", "<leader>am", ":PlurnkModels<CR>",       "Plurnk: Models")
  map_if_empty("n", "<leader>as", ":PlurnkWorkspaces<CR>",     "Plurnk: Workspaces")
  map_if_empty("n", "<leader>aR", ":PlurnkWorkspaceWorkers<CR>",  "Plurnk: Runs in workspace")
  map_if_empty("n", "<leader>aL", ":PlurnkLog<CR>",          "Plurnk: Log")
  map_if_empty("n", "<leader>aO", ":PlurnkOpen<CR>",         "Plurnk: Open workspace tab")
  map_if_empty("n", "<leader>aY", ":PlurnkYolo<CR>",         "Plurnk: Toggle YOLO")

  -- ── Membership overlay (svc#200) — keymap acts on the CURRENT file (one
  -- keystroke); `:PlurnkPick <glob>` takes a glob (native file completion). ──
  map_if_empty("n", "<leader>ap", ":PlurnkPick<CR>",        "Plurnk: pick — track file(s) in manifest")
  map_if_empty("n", "<leader>ah", ":PlurnkHide<CR>",        "Plurnk: hide this file")
  map_if_empty("n", "<leader>av", ":PlurnkView<CR>",        "Plurnk: view (read-only) this file")
  map_if_empty("n", "<leader>ad", ":PlurnkDrop<CR>",        "Plurnk: drop this file's constraints")
  map_if_empty("n", "<leader>aM", ":PlurnkMembers<CR>",     "Plurnk: list members")

  -- ── Proposal review ──
  map_if_empty("n", "<leader>ay", ":PlurnkAccept<CR>",       "Plurnk: Accept proposal")
  map_if_empty("n", "<leader>ae", ":PlurnkAcceptEdits<CR>",  "Plurnk: Accept with edits")
  map_if_empty("n", "<leader>an", ":PlurnkReject<CR>",       "Plurnk: Reject proposal")
  map_if_empty("n", "<leader>a]", ":PlurnkNext<CR>",         "Plurnk: Next proposal")
  map_if_empty("n", "<leader>a[", ":PlurnkPrev<CR>",         "Plurnk: Prev proposal")
end

return M
