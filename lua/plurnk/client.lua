-- Thin facade over state + transport.
-- Re-exports the public API so other modules can require("plurnk.client").

local M = {}
local state = require("plurnk.state")

-- ── Re-export state (workspace-scoped) ────────────────────────────────

M.get_project_path = state.get_project_path
M.set_project_path = state.set_project_path

M.get_available_aliases = state.get_available_aliases
M.set_selected_model_selector = state.set_selected_model_selector
M.consume_selected_model_selector = state.consume_selected_model_selector
M.get_selected_child_selector = state.get_selected_child_selector
M.set_selected_child_selector = state.set_selected_child_selector
M.consume_selected_child_selector = state.consume_selected_child_selector
M.consume_selected_reasoning_policy = state.consume_selected_reasoning_policy

M.has_interacted = state.has_interacted
M.mark_interacted = state.mark_interacted

M.get_workspace_id = state.get_workspace_id
M.set_workspace_id = state.set_workspace_id

M.get_worker_id = state.get_worker_id
M.set_worker_id = state.set_worker_id

M.get_workspace_model = state.get_model_selector
M.set_workspace_model = state.set_model_selector
M.get_workspace_child = state.get_child_selector
M.set_workspace_child = state.set_child_selector
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

M.is_project_file = state.is_project_file
M.get_relative_path = state.get_relative_path
M.rename_workspace = state.rename_workspace

-- ── Re-export transport ─────────────────────────────────────────────

-- The single send point — AG-UI+ is the only transport. Verbs ride action runs;
-- loop.resolve rides the terminate-resume
-- tool-result run; loop.run never reaches here (send_loop_run drives bridge.run).
M.send = function(method, params, _is_notification, callback)
  local bridge = require("plurnk.bridge")
  local thread = state.get_active_workspace_name() or "nvim"
  if method == "loop.resolve" then
    bridge.resolve(thread, params or {}, function(_, problem)
      if callback then callback(problem == nil and {} or nil, problem) end
    end)
  else
    -- FAIL-HARD ACROSS LAYERS (the 2026-07-10 rule): a failed action delivers NIL —
    -- bridge.rpc has already surfaced the error. `result or {}` here converted every
    -- contract violation into silent half-behavior; that fallback shipped the
    -- workspace-door disaster and is permanently banned.
    bridge.rpc(thread, method, params, function(result, problem)
      if callback then callback(result, problem) end
    end)
  end
end

-- ── Client-level actions ────────────────────────────────────────────

-- A workspace-aware notification: prefixes the model display so the user
-- knows which workspace it's about.
M.notify = function(msg, level, workspace)
  state.mark_interacted()
  local prefix = state.get_model_display(workspace)
  vim.notify(prefix .. ": " .. msg, level or vim.log.levels.INFO)
  pcall(vim.cmd, "redrawstatus! | redrawtabline")
end

-- Daemon compatibility check, once per nvim instance. Probe `discover` for
-- capabilities this client depends on and surface an incompatible daemon.
local daemon_checked = false
M.check_daemon_once = function()
  if daemon_checked then return end
  daemon_checked = true
  M.send("discover", {}, false, function(result)
    if type(result) ~= "table" or type(result.methods) ~= "table" then return end
    local missing = {}
    -- AG-UI+ markers this client depends on (cancellation is SSE hangup now, not a method).
    for _, m in ipairs({ "op.exec", "op.look" }) do
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
