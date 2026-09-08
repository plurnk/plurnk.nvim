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

-- {§nvim-active-worker} — `~recheck`: the worker a plurnk command issued from this buffer speaks
-- to, so a code buffer shows where `:AI?` goes without switching tabs.
local function destination(workspace)
  local worker_id = state.get_worker_id(workspace)
  if not worker_id then return nil end
  local label = state.get_worker_label(workspace, worker_id)
  return "~" .. (label or ("worker#" .. worker_id))
end

local function activity_glyph(workspace)
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

M.text = function()
  local buf = vim.api.nvim_get_current_buf()
  local workspace = vim.b[buf].plurnk_workspace or state.get_active_workspace_name()
  if not workspace then return "" end
  -- A broken transport is the whole story; no destination is offered for a worker unreachable.
  local transport = state.get_transport_status(workspace)
  if transport and (transport.phase == "reconnecting" or transport.phase == "stale") then return activity_glyph(workspace) end
  local parts = {}
  -- Inside a worker tab the winbar already leads with the lineage; elsewhere the destination
  -- is the one fact the user needs before typing a command.
  local bound = require("plurnk.worker_tab").binding_for_tabpage(vim.api.nvim_get_current_tabpage())
  if not bound then
    local where = destination(workspace)
    if where then parts[#parts + 1] = where end
  end
  local glyph = activity_glyph(workspace)
  if glyph ~= "" then parts[#parts + 1] = glyph end
  return table.concat(parts, " ")
end

M.setup_highlights = function() end
return M
