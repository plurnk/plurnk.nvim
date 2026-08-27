-- Default keymaps for prompt entry, settings, membership, and proposal review.

local M = {}
local registry = require("plurnk.command_registry")

local function describe(command)
  return "Plurnk: " .. registry.summary(command)
end

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
  map_if_empty("n",          "<leader>aa", ":AI<CR>",     describe("open"))
  map_if_empty({ "n", "x" }, "<leader>a?", ":AI? ",      "Plurnk: ask prompt")
  map_if_empty({ "n", "x" }, "<leader>a:", ":AI: ",      "Plurnk: act prompt")
  map_if_empty({ "n", "x" }, "<leader>a!", ":AI! ",      "Plurnk: exec command")
  map_if_empty("n",          "<leader>aN", ":AI?? ",     describe("workspace"))
  map_if_empty("n",          "<leader>af", ":PlurnkFork<CR>", describe("worker"))
  map_if_empty("n",          "<leader>ax", ":AI/stop<CR>",  describe("stop"))
  map_if_empty("n",          "<leader>aX", ":AI/clear<CR>", describe("clear"))

  -- ── Pickers / settings ──
  map_if_empty("n", "<leader>am", ":PlurnkModels<CR>",       describe("models"))
  map_if_empty("n", "<leader>as", ":PlurnkWorkspaces<CR>",     describe("workspaces"))
  map_if_empty("n", "<leader>aR", ":PlurnkWorkspaceWorkers<CR>",  describe("workers"))
  map_if_empty("n", "<leader>aL", ":PlurnkLog<CR>",          describe("log"))
  map_if_empty("n", "<leader>aO", ":PlurnkOpen<CR>",         describe("open"))
  map_if_empty("n", "<leader>aY", ":PlurnkYolo<CR>",         describe("yolo"))

  -- ── Membership overlay — keymap acts on the CURRENT file (one
  -- keystroke); `:PlurnkPick <glob>` takes a glob (native file completion). ──
  map_if_empty("n", "<leader>ap", ":PlurnkPick<CR>",        describe("pick"))
  map_if_empty("n", "<leader>ah", ":PlurnkHide<CR>",        describe("hide"))
  map_if_empty("n", "<leader>av", ":PlurnkView<CR>",        describe("view"))
  map_if_empty("n", "<leader>ad", ":PlurnkDrop<CR>",        describe("drop"))
  map_if_empty("n", "<leader>aM", ":PlurnkMembers<CR>",     describe("members"))

  -- ── Proposal review ──
  map_if_empty("n", "<leader>ay", ":PlurnkAccept<CR>",       describe("accept"))
  map_if_empty("n", "<leader>ae", ":PlurnkAcceptEdits<CR>",  describe("edit"))
  map_if_empty("n", "<leader>an", ":PlurnkReject<CR>",       describe("reject"))
  map_if_empty("n", "<leader>a]", ":PlurnkNext<CR>",         describe("next"))
  map_if_empty("n", "<leader>a[", ":PlurnkPrev<CR>",         describe("prev"))
end

return M
