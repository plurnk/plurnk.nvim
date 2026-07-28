-- Serialized branch batches stay compact while active, then append one terminal
-- or recovery line. The statusline mirrors the TUI's progress/recovery state.
local NAME = "38_branch_batch"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local dispatch = require("plurnk.dispatch")
  local state = require("plurnk.state")
  local worker_tab = require("plurnk.worker_tab")
  local workspace = "branches"
  state.set_workspace_id(workspace, 7)
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].plurnk_workspace = workspace

  local appended = {}
  worker_tab.append_line = function(_, line) appended[#appended + 1] = line end

  dispatch.handle_branch_batch({
    batchId = 4, state = "queued", completed = 0, total = 2,
  }, workspace)
  H.assert_eq(#appended, 0, "queued progress does not spam the waterfall")
  H.assert_match(require("plurnk.statusline").text(), "🌿 0%%", "queued progress appears in statusline")

  dispatch.handle_branch_batch({
    batchId = 4, state = "running", branch = "feature/two", completed = 1, total = 2,
  }, workspace)
  H.assert_eq(#appended, 0, "running progress does not spam the waterfall")
  H.assert_match(require("plurnk.statusline").text(), "🌿 50%%", "running progress advances")

  dispatch.handle_branch_batch({
    batchId = 4, state = "completed", completed = 2, total = 2,
  }, workspace)
  vim.wait(300, function() return #appended == 1 end)
  H.assert_match(appended[1], "branch batch 4 complete %(2/2%)", "completion appends one summary")
  H.assert_eq(state.get_branch_batch(workspace), nil, "completion clears compact state")

  dispatch.handle_branch_batch({
    batchId = 5, state = "recovery_required",
    problem = { detail = "checkout is dirty" },
  }, workspace)
  vim.wait(300, function() return #appended == 2 end)
  H.assert_match(appended[2], "requires recovery: checkout is dirty", "recovery condition is explicit")
  H.assert_match(require("plurnk.statusline").text(), "🌿 ❌", "recovery state remains visible")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
