-- Pure state container. No side effects, no requires of plurnk modules.
-- Every accessor requires an explicit workspace name.
--
-- The terminal provider-accounting envelope
-- is cardinal daemon evidence and remains one opaque, read-only snapshot here.

local M = {}

local project_path = nil
local available_aliases = {}       -- small providers.list result
local selected_model_selector = nil -- user-picked, consumed when worker policy persists
local selected_child_selector = nil
local selected_reasoning_policy = nil
local interacted = false
local active_workspace_name = nil  -- most recently attached workspace on this connection

-- Per-workspace state buckets. Keyed by workspace name.
local workspace_states = {}

local function ensure_workspace(name)
  if not name then return nil end
  if not workspace_states[name] then
    workspace_states[name] = {
      id = nil,                -- daemon-side workspace id
      worker_id = nil,            -- attached worker id (per-connection)
      worker_name = nil,          -- attached worker name
      model_selector = nil,    -- daemon-resolved alias or exact provider/model route
      child_selector = nil,    -- durable spawn override, or "inherit"
      reasoning_policy = nil,  -- daemon-owned durable policy
      reasoning_policies = {}, -- daemon-supported choices for this worker
      model_display = nil,     -- "(no model)" or "alias=provider/model"
      runtime_gauge = nil,     -- exact latest AG-UI STATE snapshot after deltas
      transport_status = nil,  -- client-owned reconnecting/stale overlay; nil means connected
      last_seen_log_ids = {}, -- worker id → highest durable row observed
      pending_proposals = {},  -- keyed by logEntryId
      search_progress = nil,   -- aggregate page acquisition percent; nil when idle
      branch_batch = nil,      -- active serialized branch-batch lifecycle
    }
  end
  return workspace_states[name]
end

-- ── Project ─────────────────────────────────────────────────────────

-- Default to the editor's cwd when no root was explicitly set. Co-location
-- makes nvim's cwd the daemon's workspace, and getcwd() is absolute (valid for
-- the daemon). Without this, project_path stays nil and EVERY workspace.create
-- goes out headless — projectRoot omitted → daemon stores null → file ops 400,
-- no git substrate. nvim intends non-headless (`:AI???` is the explicit headless).
local function resolved_root() return project_path or vim.fn.getcwd() end
M.get_project_path = function() return resolved_root() end
M.set_project_path = function(p) project_path = p end

-- ── Models / aliases (providers.list) ───────────────────────────────

M.get_available_aliases = function() return available_aliases end
local worker_names = {}              -- per workspace: conversation names for /attach completion
M.get_worker_names = function(name) return worker_names[name] or {} end
M.set_worker_names = function(name, names) worker_names[name] = names or {} end
M.set_available_aliases = function(aliases) available_aliases = aliases or {} end

M.set_selected_model_selector = function(selector) selected_model_selector = selector end
M.get_selected_child_selector = function() return selected_child_selector end
M.set_selected_child_selector = function(selector) selected_child_selector = selector end
M.set_selected_reasoning_policy = function(policy) selected_reasoning_policy = policy end

M.get_active_workspace_name = function() return active_workspace_name end
M.set_active_workspace_name = function(name) active_workspace_name = name end
M.consume_selected_model_selector = function()
  local out = selected_model_selector
  selected_model_selector = nil
  return out
end
M.consume_selected_child_selector = function()
  local out = selected_child_selector
  selected_child_selector = nil
  return out
end
M.consume_selected_reasoning_policy = function()
  local out = selected_reasoning_policy
  selected_reasoning_policy = nil
  return out
end

-- ── Interaction marker ──────────────────────────────────────────────

M.has_interacted = function() return interacted end
M.mark_interacted = function() interacted = true end

-- ── Workspace-scoped accessors ────────────────────────────────────────

M.get_workspace_id = function(name) local s = ensure_workspace(name); return s and s.id end
M.set_workspace_id = function(name, id) local s = ensure_workspace(name); if s then s.id = id end end

M.get_worker_id = function(name) local s = ensure_workspace(name); return s and s.worker_id end
M.set_worker_id = function(name, id) local s = ensure_workspace(name); if s then s.worker_id = id end end

M.get_worker_name = function(name) local s = ensure_workspace(name); return s and s.worker_name end
M.set_worker_name = function(name, worker) local s = ensure_workspace(name); if s then s.worker_name = worker end end

-- Per-worker display labels (worker_id → name) for waterfall titles/winbars —
-- the current worker_name only covers the bound worker.
M.get_worker_label = function(name, worker_id)
  local s = ensure_workspace(name)
  return s and s.worker_labels and s.worker_labels[worker_id]
end
M.set_worker_label = function(name, worker_id, label)
  local s = ensure_workspace(name)
  if not s or type(worker_id) ~= "number" or not label then return end
  s.worker_labels = s.worker_labels or {}
  s.worker_labels[worker_id] = label
end

M.model_route_selector = function(route)
  if type(route) ~= "table" then return nil end
  if type(route.alias) == "string" and route.alias ~= "" then return route.alias end
  if type(route.provider) == "string" and route.provider ~= ""
      and type(route.model) == "string" and route.model ~= "" then
    return route.provider .. "/" .. route.model
  end
  return nil
end
M.get_model_selector = function(name) local s = ensure_workspace(name); return s and s.model_selector end
M.set_model_selector = function(name, selector) local s = ensure_workspace(name); if s then s.model_selector = selector end end
M.set_model_route = function(name, route) M.set_model_selector(name, M.model_route_selector(route)) end
M.get_child_selector = function(name) local s = ensure_workspace(name); return s and s.child_selector end
M.set_child_selector = function(name, selector) local s = ensure_workspace(name); if s then s.child_selector = selector end end
M.set_child_route = function(name, route) M.set_child_selector(name, M.model_route_selector(route)) end
M.get_reasoning_policy = function(name) local s = ensure_workspace(name); return s and s.reasoning_policy end
M.get_reasoning_policies = function(name) local s = ensure_workspace(name); return s and s.reasoning_policies or {} end
M.set_reasoning = function(name, reasoning)
  local s = ensure_workspace(name)
  if not s or type(reasoning) ~= "table" then return end
  s.reasoning_policy = reasoning.policy
  s.reasoning_policies = type(reasoning.supportedPolicies) == "table" and reasoning.supportedPolicies or {}
end

-- The durable model selector in effect, else the daemon's active alias from the
-- small providers.list directory, else nil. Shared
-- by the winbar (the header) and the statusline so both name the same model the
-- TUI header does. Converges with @plurnk/plurnk buildHeader's resolution.
M.get_active_model = function(name)
  local s = name and workspace_states[name]
  if s and s.model_selector then return s.model_selector end
  for _, a in ipairs(available_aliases) do
    if a.active then return a.alias end
  end
  return nil
end

M.get_model_display = function(name)
  local s = name and workspace_states[name]
  if s and s.model_display then return s.model_display end
  return "plurnk"
end
M.set_model_display = function(name, display)
  local s = ensure_workspace(name); if s then s.model_display = display end
end

M.get_runtime_gauge = function(name)
  local s = ensure_workspace(name)
  return s and s.runtime_gauge or nil
end
M.set_runtime_gauge = function(name, gauge)
  local s = ensure_workspace(name)
  if s then s.runtime_gauge = gauge end
end
M.get_runtime_status = function(name)
  local gauge = M.get_runtime_gauge(name)
  return gauge and require("plurnk.runtime_status").project(gauge) or nil
end
M.get_transport_status = function(name)
  local s = ensure_workspace(name)
  return s and s.transport_status or nil
end
M.set_transport_status = function(name, status)
  local s = ensure_workspace(name)
  if s then s.transport_status = type(status) == "table" and status or nil end
end

-- The exact usage/accounting envelope from the last plurnk.terminated event.
M.get_usage = function(name) local s = ensure_workspace(name); return s and s.usage end
-- Record one complete snapshot. Do not rename fields, sum requests, convert exact
-- decimal strings, or retain pieces from a prior loop: those would establish a
-- second accounting representation in the client.
M.record_loop_usage = function(name, u)
  if type(u) ~= "table" then return end
  local s = ensure_workspace(name)
  if not s then return end
  s.usage = u
end

-- True between loop.run dispatch and loop/terminated — drives the
-- "switching away from a live loop" notify.
M.is_loop_inflight = function(name) local s = ensure_workspace(name); return s and s.loop_inflight or false end
M.set_loop_inflight = function(name, v) local s = ensure_workspace(name); if s then s.loop_inflight = not not v end end

M.get_search_progress = function(name) local s = ensure_workspace(name); return s and s.search_progress or nil end
M.set_search_progress = function(name, percent)
  local s = ensure_workspace(name)
  if s then s.search_progress = type(percent) == "number" and math.max(0, math.min(100, math.floor(percent))) or nil end
end
M.get_branch_batch = function(name) local s = ensure_workspace(name); return s and s.branch_batch or nil end
M.set_branch_batch = function(name, batch)
  local s = ensure_workspace(name)
  if s then s.branch_batch = type(batch) == "table" and batch or nil end
end

M.get_last_seen_log_id = function(name, worker_id)
  local s = ensure_workspace(name)
  if not s then return 0 end
  local key = worker_id or s.worker_id
  return key and (s.last_seen_log_ids[key] or 0) or 0
end
M.set_last_seen_log_id = function(name, worker_id, id)
  local s = ensure_workspace(name)
  local key = worker_id or (s and s.worker_id)
  if s and key and type(id) == "number" and id > (s.last_seen_log_ids[key] or 0) then
    s.last_seen_log_ids[key] = id
  end
end

-- ── Proposal tracking ───────────────────────────────────────────────

M.add_proposal = function(name, log_entry_id, proposal)
  local s = ensure_workspace(name); if s then s.pending_proposals[log_entry_id] = proposal end
end
M.remove_proposal = function(name, log_entry_id)
  local s = ensure_workspace(name); if s then s.pending_proposals[log_entry_id] = nil end
end
M.get_proposal = function(name, log_entry_id)
  local s = name and workspace_states[name]
  return s and s.pending_proposals[log_entry_id] or nil
end

-- ── Workspace/buffer helpers ──────────────────────────────────────────

M.is_project_file = function(path)
  local root = resolved_root()
  if not root or not path then return false end
  return vim.startswith(path, root)
end

M.get_relative_path = function(path)
  local root = resolved_root()
  if not root or not path then return path end
  if vim.startswith(path, root .. "/") then
    return path:sub(#root + 2)
  end
  return path
end

M.rename_workspace = function(old_name, new_name)
  if not old_name or not new_name or old_name == new_name then return end
  if workspace_states[old_name] then
    workspace_states[new_name] = workspace_states[old_name]
    workspace_states[old_name] = nil
  end
end

M.all_workspace_names = function()
  local names = {}
  for k in pairs(workspace_states) do names[#names+1] = k end
  table.sort(names)
  return names
end

-- Reverse lookup for notification routing: the daemon stamps workspaceId
-- on every notification (plurnk-service #191); we key state by name.
M.workspace_name_for_id = function(id)
  if type(id) ~= "number" then return nil end
  for name, s in pairs(workspace_states) do
    if s.id == id then return name end
  end
  return nil
end

return M
