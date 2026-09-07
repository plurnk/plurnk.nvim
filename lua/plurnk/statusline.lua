-- Statusline component — the Neovim-native counterpart of the TUI's input
-- prompt slot. It presents one current activity: progress, active loop, or
-- idle YOLO. Rich identity and accounting remain in the waterfall winbar.
local M = {}
local state = require("plurnk.state")

local function active_activity(workspace)
  local runtime = state.get_runtime_status(workspace)
  if runtime and runtime.activity then
    return require("plurnk.runtime_status").activity_text(runtime.activity)
  end
  local search = state.get_search_progress(workspace)
  if search ~= nil then return tostring(search) .. "%" end
  local branch = state.get_branch_batch(workspace)
  if type(branch) ~= "table" then return nil end
  local completed, total = tonumber(branch.completed), tonumber(branch.total)
  if completed == nil or total == nil or total <= 0 then return nil end
  return tostring(math.floor((completed / total) * 100)) .. "%"
end

M.text = function()
  local buf = vim.api.nvim_get_current_buf()
  local workspace = vim.b[buf].plurnk_workspace
  if not workspace then return "" end

  local transport = state.get_transport_status(workspace)
  if transport and transport.phase == "reconnecting" then return "↻ reconnecting" end
  if transport and transport.phase == "stale" then return "⚠ stale" end

  local activity = active_activity(workspace)
  if activity ~= nil and activity ~= "100%" then return activity end
  local runtime = state.get_runtime_status(workspace)
  if runtime and runtime.lifecycle == "running" then return "⌛︎" end
  if runtime and runtime.lifecycle == "queued" then return "⏳" end
  local ok_diff, diff = pcall(require, "plurnk.diff")
  return ok_diff and diff.is_yolo and diff.is_yolo() and "🔥" or ""
end

M.setup_highlights = function() end
return M
