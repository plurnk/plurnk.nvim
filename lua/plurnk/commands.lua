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

-- This buffer's session name, or nil. The buffer-local variable is the
-- one source of truth; rummy's URL-parse fallback (`plurnk://input/<x>`)
-- is unsafe here because `:AI` with no args opens `plurnk://input/scratch`
-- where "scratch" is a sentinel, not a real session.
local function active_session()
  local tab = require("plurnk.run_tab").current_alias()
  if tab then return tab end
  if vim.b.plurnk_session then return vim.b.plurnk_session end
  return require("plurnk.state").get_active_session_name()
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
    require("plurnk.state").set_active_session_name(name)
    associate_buffer(origin_buf, name)
    local model = client.consume_selected_alias()
    callback(name, model)
  end)
end

-- ── Connection switching ────────────────────────────────────────────

-- The wire binds a connection to ONE session forever: session.create AND
-- session.attach both throw once ctx.session is set (plurnk-service
-- session_create.ts / session_attach.ts). Switching session or run
-- therefore means dropping the background connection; the next send
-- boots a fresh one (transport.start on demand). In-flight requests on
-- the old connection are abandoned deliberately — the user asked to
-- switch.
local function fresh_connection()
  require("plurnk.transport").stop()
end

-- Create a session (optionally named / headless) and bind it to the
-- calling buffer. Drops the connection first if one is already bound.
-- headless = no projectRoot → file ops 400; rummy's "no repo context".
local function create_session_then(copts, callback)
  local client = require("plurnk.client")
  if active_session() then fresh_connection() end
  local params = {}
  if not copts.headless then params.projectRoot = client.get_project_path() end
  if copts.name and copts.name ~= "" then params.name = copts.name end
  local origin_buf = vim.api.nvim_get_current_buf()
  client.send("session.create", params, false, function(result)
    if type(result) ~= "table" or not result.name then return end
    local state = require("plurnk.state")
    state.set_session_id(result.name, result.id)
    state.set_active_session_name(result.name)
    associate_buffer(origin_buf, result.name)
    callback(result.name)
  end)
end

-- Fork-lite: re-attach the current session on a fresh connection with no
-- runName — the daemon mints a fresh auto-named run (§13.5).
local function fork_run_then(session_name, callback)
  local state = require("plurnk.state")
  local id = state.get_session_id(session_name)
  if not id then
    require("plurnk.client").notify("Session " .. session_name .. " not resolved", vim.log.levels.WARN)
    return
  end
  fresh_connection()
  require("plurnk.client").send("session.attach", { id = id }, false, function(att)
    if type(att) ~= "table" then return end
    state.set_run_id(session_name, att.runId)
    state.set_run_name(session_name, att.runName)
    callback(session_name)
  end)
end

-- ── op.exec helper (`:AI!`) ─────────────────────────────────────────

-- Raw selection text mirroring wrap_with_selection's two entry paths
-- (live visual marks vs a :{range} command).
local function selection_text(opts)
  local sel = require("plurnk.selection")
  if vim.fn.mode():match("[vV\22]") then return sel.get_selection_text() end
  if opts and opts.range and opts.range > 0 then
    return sel.get_selection_text({ 0, opts.line1, 1, 0 }, { 0, opts.line2, 1000, 0 }, "V")
  end
  return nil
end

-- Run a shell command through the engine (§6.8): the exec scheme spawns
-- it, output streams over stream/event into the stream split, and the
-- model learns the outcome over the wire — rummy's Run mode, daemon-owned.
local function send_exec(command)
  local client = require("plurnk.client")
  client.send("op.exec", { command = command }, false, function(result)
    if type(result) == "table" and type(result.status) == "number" and result.status >= 400 then
      client.notify("exec rejected: " .. tostring(result.status), vim.log.levels.WARN)
    end
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
      -- Bind the connection to the chosen session for real — state alone
      -- isn't enough; loop.run goes wherever the connection is attached.
      fresh_connection()
      require("plurnk.client").send("session.attach", { id = choice.id }, false, function(att)
        if type(att) ~= "table" then return end
        local state = require("plurnk.state")
        state.set_session_id(choice.name, choice.id)
        state.set_active_session_name(choice.name)
        state.set_run_id(choice.name, att.runId)
        state.set_run_name(choice.name, att.runName)
        associate_buffer(vim.api.nvim_get_current_buf(), choice.name)
        require("plurnk.run_tab").open(choice.name)
      end)
    end)
  end)
end

-- :PlurnkSessionNew [name]
M.session_new = function(opts)
  create_session_then({ name = opts.args }, function(name)
    require("plurnk.run_tab").open(name)
    require("plurnk.client").notify("Session created: " .. name, vim.log.levels.INFO)
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
      -- session.attach throws on a bound connection — switch runs on a
      -- fresh one (see fresh_connection).
      fresh_connection()
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

-- :PlurnkAccept / :PlurnkAcceptEdits / :PlurnkReject / :PlurnkNext / :PlurnkPrev
-- Buffer-agnostic proposal review — the same semantics as the in-buffer
-- <localleader>a / e / r / c, but reachable from anywhere via <leader>a*.
M.accept       = function() require("plurnk.resolve").accept() end
M.accept_edits = function() require("plurnk.resolve").accept_edits() end
M.reject       = function() require("plurnk.resolve").reject() end
M.next         = function() require("plurnk.resolve").next() end
M.prev         = function() require("plurnk.resolve").prev() end

-- :PlurnkStop — abort the run's active loop (loop.cancel) and dismiss
-- any pending proposal review UI. The daemon closes cancelled loops at
-- 499; queued loops stay enqueued (§13.5).
M.stop = function()
  local n = require("plurnk.resolve").cancel_all()
  local client = require("plurnk.client")
  if not active_session() then
    client.notify(string.format("Cancelled %d pending proposal%s (no active session)",
      n, n == 1 and "" or "s"), vim.log.levels.INFO)
    return
  end
  client.send("loop.cancel", { reason = "user_stop" }, false, function(result)
    if type(result) == "table" and result.cancelled then
      client.notify("Loop cancelled", vim.log.levels.INFO)
    else
      client.notify(string.format("No loop in flight; cancelled %d proposal%s",
        n, n == 1 and "" or "s"), vim.log.levels.INFO)
    end
  end)
end

-- :PlurnkClear — stop + close the session tab.
M.clear = function()
  local session = active_session()
  M.stop()
  if session then require("plurnk.run_tab").close(session) end
end

-- :AI (no args) — toggle between the session tab and wherever you came
-- from. One-level memory, rummy's RummyToggle semantics.
local return_tabpage = nil
M.toggle = function()
  local run_tab = require("plurnk.run_tab")
  if run_tab.session_for_tabpage(vim.api.nvim_get_current_tabpage()) then
    if return_tabpage and vim.api.nvim_tabpage_is_valid(return_tabpage) then
      vim.api.nvim_set_current_tabpage(return_tabpage)
    else
      pcall(vim.cmd, "tabprevious")
    end
    return_tabpage = nil
    return
  end
  return_tabpage = vim.api.nvim_get_current_tabpage()
  local existing = active_session()
  if existing then
    require("plurnk.run_tab").open(existing)
    return
  end
  resolve_session_then(function(session_name)
    require("plurnk.run_tab").open(session_name)
  end)
end

-- `/` subcommand routing — rummy's full surface, plurnk verbs. Wrapped
-- as functions so the M.* lookups resolve at call time.
local SLASH = {
  stop     = function() M.stop() end,
  clear    = function() M.clear() end,
  abort    = function() M.stop() end,
  models   = function() M.models() end,
  model    = function() M.models() end,
  sessions = function() M.sessions() end,
  runs     = function() M.session_runs() end,
  new      = function(args) M.session_new({ args = args }) end,
  persona  = function(args) M.persona({ args = args }) end,
  log      = function(args) M.log({ args = args }) end,
  yolo     = function() M.yolo() end,
  ping     = function() M.ping() end,
  open     = function() M.toggle() end,
  accept   = function() M.accept() end,
  reject   = function() M.reject() end,
  next     = function() M.next() end,
  prev     = function() M.prev() end,
}

-- :AI — the central user command. Rummy's metacommand language, adapted
-- to the daemon-owned loop (no client-side mode taxonomy):
--
--   :AI                 → toggle: session tab ⇄ where you came from
--   :AI <text>          → loop.run with prompt (visual selection prepended)
--   :AI? / :AI: <text>  → same; prefix is rummy flavor, stripped
--   :AI! <cmd>          → op.exec — daemon-owned shell, output streams
--                         into the stream split; no <cmd> execs the
--                         visual selection verbatim
--   :AI?? <text>        → NEW session, then prompt
--   :AI??? <text>       → new HEADLESS session (no projectRoot), then prompt
--   :AI???? <text>      → new RUN in the current session (fork-lite)
--   :AI... <text>       → mid-loop inject; blocked on plurnk-service#193
--   :AI/<sub> [args]    → route to the Plurnk* surface (see SLASH)
--
-- Cmdline abbreviations (M.setup) make the no-space forms work: `:AI?? hi`.
M.ai = function(opts)
  local raw = (opts.args or ""):gsub("^%s+", "")

  -- `:AI!cmd` parses as bang=true args="cmd" (the abbrev only catches
  -- the spaced form) — fold the bang back into the prefix language.
  if opts.bang then raw = "!" .. raw end

  if raw == "" then return M.toggle() end

  if raw:sub(1, 3) == "..." then
    -- BTW inject: Daemon.inject() exists but has no RPC yet.
    require("plurnk.client").notify(
      ":AI... (mid-loop inject) needs plurnk-service#193 — not wired yet",
      vim.log.levels.WARN)
    return
  end

  if raw:sub(1, 1) == "/" then
    local sub, sub_args = raw:match("^/(%S+)%s*(.*)$")
    local handler = sub and SLASH[sub]
    if handler then return handler(sub_args or "") end
    require("plurnk.client").notify(":AI/" .. tostring(sub) .. " is unknown", vim.log.levels.WARN)
    return
  end

  -- Count leading prefix chars (?, :, !) — repetition carries scope.
  local first = raw:sub(1, 1)
  local prefix_len = 0
  if first == "?" or first == ":" or first == "!" then
    while raw:sub(prefix_len + 1, prefix_len + 1) == first do
      prefix_len = prefix_len + 1
    end
  end
  local rest = raw:sub(prefix_len + 1):gsub("^%s+", "")

  if first == "!" then
    -- Command text wins; bare `:AI!` over a visual selection execs the
    -- selected lines verbatim. Captured before any async hop.
    local command = rest ~= "" and rest or selection_text(opts)
    if not command or command == "" then
      require("plurnk.client").notify(":AI! needs a command (text or visual selection)", vim.log.levels.WARN)
      return
    end
    local go = function(session_name)
      require("plurnk.run_tab").open(session_name)
      send_exec(command)
    end
    if prefix_len >= 4 then
      local session = active_session()
      if session then return fork_run_then(session, go) end
      return create_session_then({}, go)
    end
    if prefix_len >= 2 then
      return create_session_then({ headless = prefix_len == 3 }, go)
    end
    return resolve_session_then(function(session_name) go(session_name) end)
  end

  if prefix_len >= 2 then
    -- Wrap selection NOW (before any async hop) — the marks still hold
    -- here; they may not after a round-trip.
    local wrapped = wrap_with_selection(rest, opts)
    local after = function(session_name)
      require("plurnk.run_tab").open(session_name)
      if wrapped ~= "" then
        send_loop_run(session_name, wrapped, require("plurnk.client").consume_selected_alias())
      end
    end
    if prefix_len >= 4 then
      -- `????` — fork-lite: new run in the current session.
      local session = active_session()
      if session then return fork_run_then(session, after) end
      return create_session_then({}, after)
    end
    -- `??` new session / `???` new headless session.
    return create_session_then({ headless = prefix_len == 3 }, after)
  end

  -- Single-prefix (`?`, `:`, `!`) or bare text — plain prompt.
  M.prompt({ args = rest, range = opts.range or 0,
    line1 = opts.line1, line2 = opts.line2 })
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
  cmd("PlurnkStop",        M.stop,         {})
  cmd("PlurnkClear",       M.clear,        {})

  -- Proposal review.
  cmd("PlurnkAccept",      M.accept,       {})
  cmd("PlurnkAcceptEdits", M.accept_edits, {})
  cmd("PlurnkReject",      M.reject,       {})
  cmd("PlurnkNext",        M.next,         {})
  cmd("PlurnkPrev",        M.prev,         {})

  -- :AI — central user command (rummy-style surface; plurnk semantics).
  cmd("AI", M.ai, { nargs = "*", range = true, bang = true })

  -- Cmdline abbreviations so the no-space forms work (`:AI?? hi` would
  -- otherwise be E492 — `?` can't be part of a command name). Rewrites
  -- `AI<prefix>` → `AI <prefix>` only when it IS the whole command line,
  -- so `PlurnkAI?` or search patterns are untouched. Ported from rummy's
  -- RummyAIAbbrev (rummy.nvim commands.lua).
  vim.cmd([[
    function! PlurnkAIAbbrev(chars)
      if getcmdtype() == ':' && getcmdline() ==# 'AI' . a:chars
        return 'AI ' . a:chars
      endif
      return 'AI' . a:chars
    endfunction

    cabbrev <expr> AI?    PlurnkAIAbbrev('?')
    cabbrev <expr> AI??   PlurnkAIAbbrev('??')
    cabbrev <expr> AI???  PlurnkAIAbbrev('???')
    cabbrev <expr> AI???? PlurnkAIAbbrev('????')
    cabbrev <expr> AI:    PlurnkAIAbbrev(':')
    cabbrev <expr> AI::   PlurnkAIAbbrev('::')
    cabbrev <expr> AI:::  PlurnkAIAbbrev(':::')
    cabbrev <expr> AI:::: PlurnkAIAbbrev('::::')
    cabbrev <expr> AI!    PlurnkAIAbbrev('!')
    cabbrev <expr> AI!!   PlurnkAIAbbrev('!!')
    cabbrev <expr> AI!!!  PlurnkAIAbbrev('!!!')
    cabbrev <expr> AI!!!! PlurnkAIAbbrev('!!!!')
    cabbrev <expr> AI...  PlurnkAIAbbrev('...')
    cabbrev <expr> AI/    PlurnkAIAbbrev('/')
  ]])

  -- Convenience: a single-buffer scratch transcript without binding to
  -- a file. Useful for "just talk to the model" sessions.
  cmd("PlurnkOpen", function()
    local session = active_session()
    if session then require("plurnk.run_tab").open(session); return end
    M.session_new({ args = "" })
  end, {})
end

return M
