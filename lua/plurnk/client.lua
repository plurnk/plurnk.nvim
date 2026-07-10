-- Thin facade over state + transport.
-- Re-exports the public API so other modules can require("plurnk.client").

local M = {}
local state = require("plurnk.state")

-- ── Re-export state (session-scoped) ────────────────────────────────

M.get_project_path = state.get_project_path
M.set_project_path = state.set_project_path

M.get_available_aliases = state.get_available_aliases
M.set_selected_alias = state.set_selected_alias
M.consume_selected_alias = state.consume_selected_alias

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

-- The single send point — AG-UI+ is the ONLY transport (the WS background client
-- is deleted). Verbs ride §3 action runs; loop.resolve rides the terminate-resume
-- tool-result run; loop.run never reaches here (send_loop_run drives bridge.run).
M.send = function(method, params, _is_notification, callback)
  local bridge = require("plurnk.bridge")
  local thread = state.get_active_session_name() or "nvim"
  if method == "loop.resolve" then
    bridge.resolve(thread, params or {}, function() if callback then callback({}) end end)
  else
    -- FAIL-HARD ACROSS LAYERS (the 2026-07-10 rule): a failed action delivers NIL —
    -- bridge.rpc has already surfaced the error. `result or {}` here converted every
    -- contract violation into silent half-behavior; that fallback shipped the
    -- session-door disaster and is permanently banned.
    bridge.rpc(thread, method, params, function(result) if callback then callback(result) end end)
  end
end

-- ── Client-level actions ────────────────────────────────────────────

-- A session-aware notification: prefixes the model display so the user
-- knows which session it's about.
M.notify = function(msg, level, session)
  state.mark_interacted()
  local prefix = state.get_model_display(session)
  vim.notify(prefix .. ": " .. msg, level or vim.log.levels.INFO)
  pcall(vim.cmd, "redrawstatus! | redrawtabline")
end

-- Daemon staleness check, once per nvim instance. Clients track HEAD
-- (service SPEC §13.9); a silently-old daemon produced 10 days of
-- confusion once. Probe `discover` for wire markers this client depends
-- on and warn bluntly when one is missing.
local daemon_checked = false
M.check_daemon_once = function()
  if daemon_checked then return end
  daemon_checked = true
  M.send("discover", {}, false, function(result)
    if type(result) ~= "table" or type(result.methods) ~= "table" then return end
    local missing = {}
    for _, m in ipairs({ "loop.cancel", "op.exec" }) do
      if result.methods[m] == nil then missing[#missing + 1] = m end
    end
    local notifs = result.notifications
    if type(notifs) ~= "table" or notifs["stream/concluded"] == nil then
      missing[#missing + 1] = "stream/concluded"
    end
    if #missing > 0 then
      M.notify("daemon looks OLDER than this client (missing: "
        .. table.concat(missing, ", ")
        .. ") — restart plurnk-service from a current checkout", vim.log.levels.WARN)
    end
  end)
  -- Warm the alias cache once, so the header/statusline can name the daemon's
  -- active default before any pick or loop (the picker resolves it lazily
  -- otherwise). Cheap, boot-time-constant; statusline reactively repaints.
  M.send("providers.list", {}, false, function(result)
    if type(result) == "table" and type(result.aliases) == "table" then
      state.set_available_aliases(result.aliases)
      pcall(vim.cmd, "redrawstatus!")
    end
  end)
end

return M
