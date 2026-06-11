-- Pure state container. No side effects, no requires of plurnk modules.
-- Every accessor requires an explicit session name.
--
-- Concept mapping from rummy → plurnk:
--   rummy "run alias" → plurnk "session name" (long-lived agent state).
--   rummy "turn"      → plurnk loop turn (within current loop).
--   rummy "cost"      → plurnk `cost_pico` from session.list / session.runs.
--
-- Dropped from rummy: context_max/effective, budget_*, tokens_in/out
-- (plurnk wire does not expose these per-loop; the model's packet.system
-- carries token budgets but they're not surfaced as a discrete RPC).

local M = {}

local project_path = nil
local available_aliases = {}  -- providers.list result
local selected_alias = nil    -- user-picked, consumed by next loop.run
local interacted = false
local persona_path = nil      -- absolute path passed as --persona
local active_session_name = nil  -- most recently attached session on this connection

-- Per-session state buckets. Keyed by session name.
local session_states = {}

local function ensure_session(name)
  if not name then return nil end
  if not session_states[name] then
    session_states[name] = {
      id = nil,                -- daemon-side session id
      run_id = nil,            -- attached run id (per-connection)
      run_name = nil,          -- attached run name
      model_alias = nil,       -- alias passed on most recent loop.run
      model_display = nil,     -- "(no model)" or "alias=provider/model"
      current_loop_id = nil,
      current_turn = nil,
      final_status = nil,
      status_text = nil,
      cost_pico = 0,
      last_seen_log_id = 0,
      pending_proposals = {},  -- keyed by logEntryId
    }
  end
  return session_states[name]
end

-- ── Project ─────────────────────────────────────────────────────────

M.get_project_path = function() return project_path end
M.set_project_path = function(p) project_path = p end

-- ── Models / aliases (providers.list) ───────────────────────────────

M.get_available_aliases = function() return available_aliases end
M.set_available_aliases = function(aliases) available_aliases = aliases or {} end

M.set_selected_alias = function(alias) selected_alias = alias end

M.get_active_session_name = function() return active_session_name end
M.set_active_session_name = function(name) active_session_name = name end
M.consume_selected_alias = function()
  local out = selected_alias
  selected_alias = nil
  return out
end

-- ── Persona file path ───────────────────────────────────────────────

M.get_persona_path = function() return persona_path end
M.set_persona_path = function(p) persona_path = p end

-- ── Interaction marker ──────────────────────────────────────────────

M.has_interacted = function() return interacted end
M.mark_interacted = function() interacted = true end

-- ── Session-scoped accessors ────────────────────────────────────────

M.get_session_id = function(name) local s = ensure_session(name); return s and s.id end
M.set_session_id = function(name, id) local s = ensure_session(name); if s then s.id = id end end

M.get_run_id = function(name) local s = ensure_session(name); return s and s.run_id end
M.set_run_id = function(name, id) local s = ensure_session(name); if s then s.run_id = id end end

M.get_run_name = function(name) local s = ensure_session(name); return s and s.run_name end
M.set_run_name = function(name, run) local s = ensure_session(name); if s then s.run_name = run end end

M.get_model_alias = function(name) local s = ensure_session(name); return s and s.model_alias end
M.set_model_alias = function(name, alias) local s = ensure_session(name); if s then s.model_alias = alias end end

M.get_model_display = function(name)
  local s = name and session_states[name]
  if s and s.model_display then return s.model_display end
  return "plurnk"
end
M.set_model_display = function(name, display)
  local s = ensure_session(name); if s then s.model_display = display end
end

M.get_current_loop_id = function(name) local s = ensure_session(name); return s and s.current_loop_id end
M.set_current_loop_id = function(name, lid) local s = ensure_session(name); if s then s.current_loop_id = lid end end

M.get_current_turn = function(name) local s = ensure_session(name); return s and s.current_turn end
M.set_current_turn = function(name, t) local s = ensure_session(name); if s then s.current_turn = t end end

M.get_final_status = function(name) local s = ensure_session(name); return s and s.final_status end
M.set_final_status = function(name, st) local s = ensure_session(name); if s then s.final_status = st end end

M.get_status_text = function(name) local s = ensure_session(name); return s and s.status_text end
M.set_status_text = function(name, text) local s = ensure_session(name); if s then s.status_text = text end end

M.get_cost_pico = function(name) local s = ensure_session(name); return s and s.cost_pico or 0 end
M.set_cost_pico = function(name, c) local s = ensure_session(name); if s then s.cost_pico = c or 0 end end

M.get_last_seen_log_id = function(name) local s = ensure_session(name); return s and s.last_seen_log_id or 0 end
M.set_last_seen_log_id = function(name, id)
  local s = ensure_session(name); if s and id and id > s.last_seen_log_id then s.last_seen_log_id = id end
end

-- ── Proposal tracking ───────────────────────────────────────────────

M.add_proposal = function(name, log_entry_id, proposal)
  local s = ensure_session(name); if s then s.pending_proposals[log_entry_id] = proposal end
end
M.remove_proposal = function(name, log_entry_id)
  local s = ensure_session(name); if s then s.pending_proposals[log_entry_id] = nil end
end
M.get_proposal = function(name, log_entry_id)
  local s = name and session_states[name]
  return s and s.pending_proposals[log_entry_id] or nil
end

-- ── Session/buffer helpers ──────────────────────────────────────────

M.is_project_file = function(path)
  if not project_path or not path then return false end
  return vim.startswith(path, project_path)
end

M.get_relative_path = function(path)
  if not project_path or not path then return path end
  if vim.startswith(path, project_path .. "/") then
    return path:sub(#project_path + 2)
  end
  return path
end

M.rename_session = function(old_name, new_name)
  if not old_name or not new_name or old_name == new_name then return end
  if session_states[old_name] then
    session_states[new_name] = session_states[old_name]
    session_states[old_name] = nil
  end
end

M.all_session_names = function()
  local names = {}
  for k in pairs(session_states) do names[#names+1] = k end
  table.sort(names)
  return names
end

-- Reverse lookup for notification routing: the daemon stamps sessionId
-- on every notification (plurnk-service #191); we key state by name.
M.session_name_for_id = function(id)
  if type(id) ~= "number" then return nil end
  for name, s in pairs(session_states) do
    if s.id == id then return name end
  end
  return nil
end

return M
