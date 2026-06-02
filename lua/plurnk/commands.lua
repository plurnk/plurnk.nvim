-- User-facing commands. Plurnk doesn't have rummy's mode taxonomy
-- (ask/act/run) — the model decides which ops to emit based on the
-- prompt and sysprompt. So instead of three commands we have one:
-- :PlurnkPrompt {text}. Visual selection is prepended automatically.
--
-- Picker commands wrap providers.list / session.list / session.runs
-- via vim.ui.select; the buffer/tab association from rummy is kept
-- (`vim.b.plurnk_session` instead of `vim.b.plurnk_run`).

local M = {}

-- ── Buffer helpers ──────────────────────────────────────────────────

-- This buffer's session name, or nil.
local function active_session()
  local tab = require("plurnk.run_tab").current_alias()
  if tab then return tab end
  if vim.b.plurnk_session then return vim.b.plurnk_session end
  local name = vim.api.nvim_buf_get_name(0)
  return name:match("^plurnk://input/(.+)$")
end

local function is_real_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return false end
  if name:match("^plurnk://") then return false end
  if vim.bo[buf].buftype ~= "" then return false end
  return true
end

local function associate_buffer(bufnr, session_name)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.b[bufnr].plurnk_session = session_name
  end
end

local function wrap_with_selection(prompt, opts)
  local mode = vim.fn.mode()
  local selection = nil
  if mode:match("[vV\22]") then
    selection = require("plurnk.selection").get_selection()
  elseif opts and opts.range and opts.range > 0 then
    local start_pos = { 0, opts.line1, 1, 0 }
    local end_pos   = { 0, opts.line2, 1000, 0 }
    selection = require("plurnk.selection").get_selection(start_pos, end_pos, "V")
  end
  if selection then return selection .. (prompt or "") end
  return prompt or ""
end

-- ── Session resolution ─────────────────────────────────────────────

-- Resolve this buffer's session and invoke callback(session_name, model_alias).
-- If no session is attached, create one and bind it to the calling buffer.
local function resolve_session_then(callback)
  local client = require("plurnk.client")
  local session = active_session()
  if session then
    local model = client.consume_selected_alias() or client.get_session_model(session)
    callback(session, model)
    return
  end
  -- No session attached — create a fresh one. We let the daemon name it;
  -- the response handler captures the name and binds it to the origin buf.
  local origin_buf = vim.api.nvim_get_current_buf()
  client.send("session.create", { projectRoot = client.get_project_path() }, false, function(result)
    if type(result) ~= "table" or not result.name then return end
    local name = result.name
    require("plurnk.state").set_session_id(name, result.id)
    associate_buffer(origin_buf, name)
    local model = client.consume_selected_alias()
    callback(name, model)
  end)
end

-- ── loop.run helper ────────────────────────────────────────────────

local function send_loop_run(session_name, prompt, model_alias)
  local client = require("plurnk.client")
  local persona_path = client.get_persona_path()
  local params = { prompt = prompt }
  if model_alias then params.alias = model_alias end
  if persona_path then
    local ok, contents = pcall(function() return vim.fn.readfile(persona_path, "", 1024) end)
    if ok and type(contents) == "table" then params.persona = table.concat(contents, "\n") end
  end
  client.send("loop.run", params, false, function(result)
    if type(result) ~= "table" then return end
    if type(result.finalStatus) == "number" then
      require("plurnk.state").set_final_status(session_name, result.finalStatus)
    end
    require("plurnk.run_tab").update_status(session_name)
    vim.cmd("redrawstatus! | redrawtabline")
  end)
end

-- ── Public command entry points ────────────────────────────────────

-- :PlurnkPrompt {text}
M.prompt = function(opts)
  local text = wrap_with_selection(opts.args, opts)
  if not text or text == "" then
    require("plurnk.client").notify("PlurnkPrompt: no prompt text", vim.log.levels.WARN)
    return
  end
  resolve_session_then(function(session_name, model_alias)
    require("plurnk.run_tab").open(session_name)
    send_loop_run(session_name, text, model_alias)
  end)
end

-- :PlurnkSessions  → vim.ui.select over session.list, attach to selection.
M.sessions = function()
  local client = require("plurnk.client")
  client.send("session.list", {}, false, function(result)
    if type(result) ~= "table" or type(result.sessions) ~= "table" then return end
    local items = result.sessions
    if #items == 0 then
      client.notify("No sessions on the daemon", vim.log.levels.INFO)
      return
    end
    vim.ui.select(items, {
      prompt = "Plurnk session",
      format_item = function(s)
        return string.format("%s  (%s)", s.name, s.project_root or "(headless)")
      end,
    }, function(choice)
      if not choice then return end
      require("plurnk.state").set_session_id(choice.name, choice.id)
      associate_buffer(vim.api.nvim_get_current_buf(), choice.name)
      require("plurnk.run_tab").open(choice.name)
    end)
  end)
end

-- :PlurnkSessionNew [name]
M.session_new = function(opts)
  local client = require("plurnk.client")
  local params = { projectRoot = client.get_project_path() }
  if opts.args and opts.args ~= "" then params.name = opts.args end
  client.send("session.create", params, false, function(result)
    if type(result) ~= "table" or not result.name then return end
    require("plurnk.state").set_session_id(result.name, result.id)
    associate_buffer(vim.api.nvim_get_current_buf(), result.name)
    require("plurnk.run_tab").open(result.name)
    client.notify("Session created: " .. result.name, vim.log.levels.INFO)
  end)
end

-- :PlurnkSessionRuns  → list runs in the active session.
M.session_runs = function()
  local session = active_session()
  if not session then
    require("plurnk.client").notify("No active session", vim.log.levels.WARN)
    return
  end
  local id = require("plurnk.state").get_session_id(session)
  if not id then
    require("plurnk.client").notify("Session " .. session .. " not resolved", vim.log.levels.WARN)
    return
  end
  local client = require("plurnk.client")
  client.send("session.runs", { id = id }, false, function(result)
    if type(result) ~= "table" or type(result.runs) ~= "table" then return end
    if #result.runs == 0 then
      client.notify("No runs in " .. session, vim.log.levels.INFO)
      return
    end
    vim.ui.select(result.runs, {
      prompt = "Plurnk run (session " .. session .. ")",
      format_item = function(r) return r.name .. "  (" .. (r.created_at or "?") .. ")" end,
    }, function(choice)
      if not choice then return end
      -- Attach a fresh connection's worth of state to this run via
      -- session.attach — see §1.1.
      client.send("session.attach", { id = id, runName = choice.name }, false, function(att)
        if type(att) == "table" then
          require("plurnk.state").set_run_id(session, att.runId)
          require("plurnk.state").set_run_name(session, att.runName)
        end
      end)
    end)
  end)
end

-- :PlurnkModels  → providers.list picker; selection feeds the next loop.run.
M.models = function()
  local client = require("plurnk.client")
  client.send("providers.list", {}, false, function(result)
    if type(result) ~= "table" or type(result.aliases) ~= "table" then return end
    require("plurnk.state").set_available_aliases(result.aliases)
    vim.ui.select(result.aliases, {
      prompt = "Plurnk model alias",
      format_item = function(a)
        return string.format("%s%s  %s/%s", a.alias, a.active and " *" or "", a.provider, a.model)
      end,
    }, function(choice)
      if not choice then return end
      require("plurnk.state").set_selected_alias(choice.alias)
      client.notify("Model alias: " .. choice.alias, vim.log.levels.INFO)
    end)
  end)
end

-- :PlurnkPersona {path}  — set the persona file used on subsequent loop.run.
M.persona = function(opts)
  if not opts.args or opts.args == "" then
    require("plurnk.state").set_persona_path(nil)
    require("plurnk.client").notify("Persona cleared", vim.log.levels.INFO)
    return
  end
  local path = vim.fn.fnamemodify(opts.args, ":p")
  if vim.fn.filereadable(path) ~= 1 then
    require("plurnk.client").notify("Persona file not readable: " .. path, vim.log.levels.ERROR)
    return
  end
  require("plurnk.state").set_persona_path(path)
  require("plurnk.client").notify("Persona: " .. path, vim.log.levels.INFO)
end

-- :PlurnkLog [limit]
M.log = function(opts)
  local session = active_session()
  if not session then
    require("plurnk.client").notify("No active session", vim.log.levels.WARN)
    return
  end
  local params = {}
  if opts.args and tonumber(opts.args) then params.limit = tonumber(opts.args) end
  require("plurnk.client").send("log.read", params, false, function(result)
    if type(result) ~= "table" then return end
    local entries = result.entries or {}
    require("plurnk.run_tab").open(session)
    require("plurnk.run_tab").append_history(session, entries)
  end)
end

-- :PlurnkYolo  — toggle client-side auto-accept.
M.yolo = function()
  local diff = require("plurnk.diff")
  diff.toggle_yolo()
  require("plurnk.client").notify("YOLO " .. (diff.is_yolo() and "ON" or "OFF"), vim.log.levels.INFO)
end

-- :PlurnkPing  — sanity check the wire.
M.ping = function()
  require("plurnk.client").send("ping", {}, false, function(_)
    require("plurnk.client").notify("pong", vim.log.levels.INFO)
  end)
end

-- ── Setup ──────────────────────────────────────────────────────────

M.setup = function()
  local cmd = vim.api.nvim_create_user_command

  cmd("PlurnkPrompt",      M.prompt,       { nargs = "*", range = true })
  cmd("PlurnkSessions",    M.sessions,     {})
  cmd("PlurnkSessionNew",  M.session_new,  { nargs = "?" })
  cmd("PlurnkSessionRuns", M.session_runs, {})
  cmd("PlurnkModels",      M.models,       {})
  cmd("PlurnkPersona",     M.persona,      { nargs = "?", complete = "file" })
  cmd("PlurnkLog",         M.log,          { nargs = "?" })
  cmd("PlurnkYolo",        M.yolo,         {})
  cmd("PlurnkPing",        M.ping,         {})

  -- Convenience: a single-buffer scratch transcript without binding to
  -- a file. Useful for "just talk to the model" sessions.
  cmd("PlurnkOpen", function()
    local session = active_session()
    if session then require("plurnk.run_tab").open(session); return end
    M.session_new({ args = "" })
  end, {})
end

return M
