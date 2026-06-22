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

-- Default to the editor's cwd when no root was explicitly set. Co-location
-- makes nvim's cwd the daemon's workspace, and getcwd() is absolute (valid for
-- the daemon). Without this, project_path stays nil and EVERY session.create
-- goes out headless — projectRoot omitted → daemon stores null → file ops 400,
-- no git substrate. nvim intends non-headless (`:AI???` is the explicit headless).
local function resolved_root() return project_path or vim.fn.getcwd() end
M.get_project_path = function() return resolved_root() end
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

-- Per-run display labels (run_id → name) for waterfall titles/winbars —
-- the current run_name only covers the bound run.
M.get_run_label = function(name, run_id)
  local s = ensure_session(name)
  return s and s.run_labels and s.run_labels[run_id]
end
M.set_run_label = function(name, run_id, label)
  local s = ensure_session(name)
  if not s or type(run_id) ~= "number" or not label then return end
  s.run_labels = s.run_labels or {}
  s.run_labels[run_id] = label
end

M.get_model_alias = function(name) local s = ensure_session(name); return s and s.model_alias end
M.set_model_alias = function(name, alias) local s = ensure_session(name); if s then s.model_alias = alias end end

-- The model alias in effect: the one last sent on this session's loop.run,
-- else the daemon's active default (providers.list `active`), else nil. Shared
-- by the winbar (the header) and the statusline so both name the same model the
-- TUI header does. Converges with @plurnk/plurnk buildHeader's resolution.
M.get_active_model = function(name)
  local s = name and session_states[name]
  if s and s.model_alias then return s.model_alias end
  for _, a in ipairs(available_aliases) do
    if a.active then return a.alias end
  end
  return nil
end

-- The active model's context window (svc#263) — the context-gauge denominator.
-- Only the daemon's active default carries contextSize on providers.list (a
-- session-pinned non-active model reports null), so this is the active default's
-- window; approximate if a session pins a different model.
M.get_active_context_size = function()
  for _, a in ipairs(available_aliases) do
    if a.active then return a.contextSize end
  end
  return nil
end

M.get_model_display = function(name)
  local s = name and session_states[name]
  if s and s.model_display then return s.model_display end
  return "🐹"
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

-- Real provider usage (plurnk-service #197), accumulated per session
-- from loop/terminated — the ONE accumulation point (loop.run's result
-- carries the same numbers; adding both would double-count).
M.get_usage = function(name) local s = ensure_session(name); return s and s.usage end
-- Record the LAST loop's usage — a snapshot, NOT a running total. The session
-- lifetime cost is the daemon's to aggregate (svc#254): runs spawn/fork and
-- multiple clients drive one session, so no client sees every turn; a
-- client-side tally only sums the loops THIS client witnessed — a lie about
-- money. We show only "what the last loop cost" + account balance (svc#252).
M.record_loop_usage = function(name, u)
  if type(u) ~= "table" then return end
  local s = ensure_session(name)
  if not s then return end
  s.usage = s.usage or { prompt = 0, completion = 0 }
  if type(u.promptTokens) == "number" then s.usage.prompt = u.promptTokens end
  if type(u.completionTokens) == "number" then s.usage.completion = u.completionTokens end
  -- context occupancy (svc#263) — the gauge numerator, the daemon's figure
  -- (NOT the double-counting promptTokens sum).
  if type(u.contextTokens) == "number" then s.usage.context_tokens = u.contextTokens end
  if type(u.costPico) == "number" then s.cost_pico = u.costPico end  -- last loop's cost, not a total
  -- sessionCostPico = the DAEMON's authoritative cumulative session total
  -- (svc#254), pushed on the wire — NOT a client tally. We only render it.
  if type(u.sessionCostPico) == "number" then s.session_cost_pico = u.sessionCostPico end
  if type(u.balancePico) == "number" then s.balance_pico = u.balancePico end  -- account balance snapshot
end

-- True between loop.run dispatch and loop/terminated — drives the
-- "switching away from a live loop" notify.
M.is_loop_inflight = function(name) local s = ensure_session(name); return s and s.loop_inflight or false end
M.set_loop_inflight = function(name, v) local s = ensure_session(name); if s then s.loop_inflight = not not v end end

M.get_status_text = function(name) local s = ensure_session(name); return s and s.status_text end
M.set_status_text = function(name, text) local s = ensure_session(name); if s then s.status_text = text end end

-- The LAST loop's cost (snapshot), not a session total — the lifetime total is
-- the daemon's (svc#254), surfaced in `session list`, never reconstructed here.
M.get_cost_pico = function(name) local s = ensure_session(name); return s and s.cost_pico or 0 end
M.set_cost_pico = function(name, c) local s = ensure_session(name); if s then s.cost_pico = c or 0 end end

-- Daemon's authoritative session total (svc#254); nil until the wire carries
-- sessionCostPico. Rendered, never reconstructed.
M.get_session_cost_pico = function(name) local s = ensure_session(name); return s and s.session_cost_pico end

-- Account balance snapshot (svc#252); nil until the wire carries balancePico.
M.get_balance_pico = function(name) local s = ensure_session(name); return s and s.balance_pico end

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
