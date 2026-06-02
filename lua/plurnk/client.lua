-- Thin facade over state + transport.
-- Re-exports the public API so other modules can require("plurnk.client").

local M = {}
local state = require("plurnk.state")
local transport = require("plurnk.transport")

-- ── Re-export state (session-scoped) ────────────────────────────────

M.get_project_path = state.get_project_path
M.set_project_path = state.set_project_path

M.get_available_aliases = state.get_available_aliases
M.set_selected_alias = state.set_selected_alias
M.consume_selected_alias = state.consume_selected_alias

M.get_persona_path = state.get_persona_path
M.set_persona_path = state.set_persona_path

M.has_interacted = state.has_interacted
M.mark_interacted = state.mark_interacted

M.get_session_id = state.get_session_id
M.set_session_id = state.set_session_id

M.get_run_id = state.get_run_id
M.set_run_id = state.set_run_id

M.get_session_model = state.get_model_alias
M.set_session_model = state.set_model_alias
M.get_model_display = state.get_model_display
M.set_model_display = state.set_model_display

M.get_current_loop_id = state.get_current_loop_id
M.set_current_loop_id = state.set_current_loop_id
M.get_current_turn = state.get_current_turn
M.set_current_turn = state.set_current_turn
M.get_final_status = state.get_final_status
M.set_final_status = state.set_final_status
M.get_status_text = state.get_status_text
M.set_status_text = state.set_status_text
M.get_cost_pico = state.get_cost_pico
M.set_cost_pico = state.set_cost_pico

M.is_project_file = state.is_project_file
M.get_relative_path = state.get_relative_path
M.rename_session = state.rename_session

-- ── Re-export transport ─────────────────────────────────────────────

M.send = transport.send
M.send_async = transport.send_async
M.stop = transport.stop
M.flush_queue = transport.flush_queue
if transport.reset_connection then M.reset_connection = transport.reset_connection end

-- ── Client-level actions ────────────────────────────────────────────

-- A session-aware notification: prefixes the model display so the user
-- knows which session it's about.
M.notify = function(msg, level, session)
  state.mark_interacted()
  local prefix = state.get_model_display(session)
  vim.notify(prefix .. ": " .. msg, level or vim.log.levels.INFO)
  pcall(vim.cmd, "redrawstatus! | redrawtabline")
end

return M
