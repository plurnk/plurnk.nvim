-- Statusline component — the Neovim-native counterpart of the TUI's input
-- prompt slot. It presents one current activity: progress, active loop, or
-- idle YOLO. Rich identity and accounting remain in the waterfall winbar.
local M = {}
local state = require("plurnk.state")

local function active_percent(workspace)
  if state.is_embedding(workspace) then return state.get_embedding_progress(workspace) end
  local search = state.get_search_progress(workspace)
  if search ~= nil then return search end
  local branch = state.get_branch_batch(workspace)
  if type(branch) ~= "table" then return nil end
  local completed, total = tonumber(branch.completed), tonumber(branch.total)
  if completed == nil or total == nil or total <= 0 then return nil end
  return math.floor((completed / total) * 100)
end

M.text = function()
  local buf = vim.api.nvim_get_current_buf()
  local workspace = vim.b[buf].plurnk_workspace
  if not workspace then return "" end

  local percent = active_percent(workspace)
  if type(percent) == "number" and percent < 100 then return tostring(percent) .. "%" end
  if state.is_loop_inflight(workspace) or state.is_embedding(workspace) then return "⌛︎" end
  local ok_diff, diff = pcall(require, "plurnk.diff")
  return ok_diff and diff.is_yolo and diff.is_yolo() and "🔥" or ""
end

M.setup_highlights = function() end
return M
