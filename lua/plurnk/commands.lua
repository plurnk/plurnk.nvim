-- User-facing commands. Plurnk doesn't have rummy's mode taxonomy
-- (ask/act/run) — the model decides which ops to emit based on the
-- prompt and sysprompt. So instead of three commands we have one:
-- :PlurnkPrompt {text}. Visual selection is prepended automatically.
--
-- Picker commands wrap providers.list / session.list / session.runs
-- via vim.ui.select; the buffer/tab association from rummy is kept
-- (`vim.b.plurnk_session` instead of `vim.b.plurnk_run`).

local M = {}

-- #249 — session-stable frontend id, set on every session.create and forwarded
-- by the daemon to the plurnk provider as Plurnk-Client (dropped by others).
local CLIENT_ID = "plurnk.nvim"

-- #132 — the per-session exec-policy layer: forward the PLURNK_EXECS_* grammar
-- (PLURNK_EXECS_ONLY allowlist, PLURNK_EXECS_<tag>=0 kill) so the daemon
-- intersects it with its own ceiling (subtractive — the client can narrow, never
-- re-enable). Forwarded VERBATIM; the daemon's execs Policy is the interpreter.
-- EXCLUDES PLURNK_EXECS_MCP_* — those are MCP SERVER configs (URLs, header bearer
-- tokens), not policy, and must never ride the wire. The bare PLURNK_EXECS_MCP
-- tag toggle (no trailing _) stays. nil when nothing is set.
function M.collect_execs_policy()
  local out, any = {}, false
  for key, val in pairs(vim.fn.environ()) do
    if key:match("^PLURNK_EXECS_") and not key:match("^PLURNK_EXECS_MCP_") and type(val) == "string" then
      out[key] = val
      any = true
    end
  end
  return any and out or nil
end

-- Settings every session.create carries: the client id (#249), an optional
-- AGENTS-auto-load override (#268, pure passthrough — the daemon does the
-- picking/reading; config.auto_read_agents nil ⇒ the daemon's env default), and
-- the exec-policy layer (#132).
local function session_settings()
  local s = { client = CLIENT_ID }
  local ar = require("plurnk.config").get("auto_read_agents")
  if type(ar) == "boolean" then s.autoReadAgents = ar end
  local execs = M.collect_execs_policy()
  if execs then s.execs = execs end
  -- #346 — enable model→user SEND[300] questions (also gates the daemon's
  -- questions.md teaching). config wins; else the shared PLURNK_QUESTIONS env.
  local cfg_q = require("plurnk.config").get("questions")
  local env_q = ({ ["1"] = true, ["true"] = true, ["yes"] = true, ["on"] = true })[(vim.env.PLURNK_QUESTIONS or ""):lower()]
  if cfg_q == true or (cfg_q == nil and env_q) then s.questions = true end
  return s
end

-- @file refs (#260) → loop.run.openPaths. The daemon foists turn-0 READs of
-- these workspace paths (no client-side inlining). The @ must START a token
-- (the leading space we prepend makes `%s@` catch a line-initial ref too) so an
-- email's user@host isn't a ref; trailing sentence punctuation trimmed; deduped.
local function extract_open_paths(prompt)
  local seen, out = {}, {}
  for path in (" " .. tostring(prompt)):gmatch("%s@(%S+)") do
    path = path:gsub("[%.,;:!?%)]+$", "")
    if #path > 0 and not seen[path] then seen[path] = true; out[#out + 1] = path end
  end
  return out
end

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

-- Forward declaration — defined with the connection helpers below,
-- referenced from resolve_session_then's create path above it.
local note_model_run

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
    client.check_daemon_once()
    -- A picked alias wins once; then it STICKS — persist it as the session's
    -- model so every later loop keeps it (else it reverts to the daemon default
    -- after one loop). consume clears the one-shot pick; set_model_alias makes
    -- the choice durable (and lights it in the statusbar/winbar).
    local model = client.consume_selected_alias() or client.get_session_model(session)
    if model then require("plurnk.state").set_model_alias(session, model) end
    callback(session, model)
    return
  end
  local origin_buf = vim.api.nvim_get_current_buf()
  -- Bridge mode: no session.create — the threadId IS the session identity (the
  -- bridge lazy-creates agui-<threadId> on the first run, applying forwardedProps).
  -- A stable default thread; the daemon id is bridge-created (0 here).
  if require("plurnk.bridge").enabled() then
    local name = "nvim"
    require("plurnk.state").set_session_id(name, 0)
    require("plurnk.state").set_active_session_name(name)
    associate_buffer(origin_buf, name)
    local model = client.consume_selected_alias()
    if model then require("plurnk.state").set_model_alias(name, model) end
    callback(name, model)
    return
  end
  -- No session attached — create a fresh one. We let the daemon name it;
  -- the response handler captures the name and binds it to the origin buf.
  client.send("session.create", { projectRoot = client.get_project_path(), settings = session_settings() }, false, function(result)
    if type(result) ~= "table" or not result.name then return end
    local name = result.name
    require("plurnk.state").set_session_id(name, result.id)
    require("plurnk.state").set_active_session_name(name)
    associate_buffer(origin_buf, name)
    -- session.create returns the CLIENT run; the conversation lives in the
    -- MODEL run (run-split, §13.7). Don't set a conversation run here — the
    -- first model-run log/entry adopts it, and loop.run confirms modelRunId.
    client.check_daemon_once()
    local model = client.consume_selected_alias()
    if model then require("plurnk.state").set_model_alias(name, model) end
    callback(name, model)
  end)
end

-- ── Connection switching ────────────────────────────────────────────

-- The connection rebinds in place: session.create/attach on a bound
-- connection switch the binding, releasing the prior client loop
-- (plurnk-service §13.5-rebind, v0.17.0). No reconnect. We warn only
-- when a loop is draining on the session we're leaving: after the
-- rebind we stop receiving that session's notifications, so its live
-- view goes stale here even though the loop completes on the daemon.
local function warn_if_switching_live()
  local state = require("plurnk.state")
  local session = state.get_active_session_name()
  if session and state.is_loop_inflight(session) then
    local run = state.get_run_name(session)
    require("plurnk.client").notify(
      "switching away — the running loop in " .. session .. (run and ("·" .. run) or "")
      .. " continues on the daemon; reopen the run to catch up",
      vim.log.levels.WARN)
  end
end

-- Adopt the MODEL run as this session's conversation run (the waterfall
-- shows it). The model run is authoritative from loop.run's modelRunId or
-- session.runs (origin="model") — never from session.create (that's the
-- client run; run-split §13.7). Idempotent: the first model-run log/entry
-- may have adopted it already; this confirms and labels it.
note_model_run = function(session_name, run_id, run_name)
  if type(run_id) ~= "number" then return end
  local state = require("plurnk.state")
  state.set_run_id(session_name, run_id)
  if run_name then
    state.set_run_name(session_name, run_name)
    state.set_run_label(session_name, run_id, run_name)
  end
  require("plurnk.run_tab").note_run_resolved(session_name)
end

-- Create a session (optionally named / headless) and bind it to the
-- calling buffer. The connection rebinds in place if one is already
-- bound. headless = no projectRoot → file ops 400; rummy's "no repo".
local function create_session_then(copts, callback)
  local client = require("plurnk.client")
  -- v1 model (operator-ratified 2026-06-11): ONE live session per nvim
  -- instance. Switching moves liveness; old session tabs become static.
  local prev = active_session()
  warn_if_switching_live()
  local params = { settings = session_settings() }
  if not copts.headless then params.projectRoot = client.get_project_path() end
  if copts.name and copts.name ~= "" then params.name = copts.name end
  local origin_buf = vim.api.nvim_get_current_buf()
  client.send("session.create", params, false, function(result)
    if type(result) ~= "table" or not result.name then return end
    local state = require("plurnk.state")
    state.set_session_id(result.name, result.id)
    state.set_active_session_name(result.name)
    associate_buffer(origin_buf, result.name)
    -- No conversation run from create (client run; see resolve_session_then).
    if prev and prev ~= result.name then
      client.notify("live session: " .. result.name .. " — tabs for " .. prev .. " are now static", vim.log.levels.INFO)
    end
    client.check_daemon_once()
    callback(result.name)
  end)
end

-- Conversation fork (`????`): branch the model run, carrying its history —
-- run.fork (svc#248, now wired). Optional `name` names the branch at
-- instantiation (immutable after; reserved/taken rejected; defaults
-- `<parent>-fork`). Forks the session's current model run, binds this
-- connection to the new run so the next loop.run lands there, then continues.
local function fork_run_then(session_name, callback, name)
  local client = require("plurnk.client")
  local params = {}
  if name and name ~= "" then params.name = name end
  client.send("run.fork", params, false, function(result)
    if type(result) ~= "table" or not result.runId then
      client.notify("run.fork failed (need a model run to fork — start a loop first)", vim.log.levels.WARN)
      return
    end
    local sid = require("plurnk.state").get_session_id(session_name)
    client.send("session.attach", { id = sid, runId = result.runId }, false, function(att)
      local rid = (type(att) == "table" and att.runId) or result.runId
      local rname = (type(att) == "table" and att.runName) or result.runName
      note_model_run(session_name, rid, rname)
      callback(session_name)
    end)
  end)
end

-- Rebind the connection to a specific run and adopt it as the conversation
-- run (the run picker hands a model run; submitting in a historical run's
-- input means "switch there, then speak").
M.switch_run = function(session_name, run_id, callback)
  local state = require("plurnk.state")
  if state.get_run_id(session_name) == run_id then return callback() end
  local id = state.get_session_id(session_name)
  if not id then
    require("plurnk.client").notify("Session " .. session_name .. " not resolved", vim.log.levels.WARN)
    return
  end
  warn_if_switching_live()
  require("plurnk.client").send("session.attach", { id = id, runId = run_id }, false, function(att)
    if type(att) ~= "table" then return end
    note_model_run(session_name, att.runId, att.runName)
    callback()
  end)
end

-- :PlurnkFork [name] — branch the current conversation into a new run
-- (run.fork, svc#248), optionally named at instantiation (immutable after).
-- Switches to the fork; the next prompt speaks into it. No prompt of its own —
-- `:AI???? <text>` is the fork-and-speak form.
M.fork = function(opts)
  local name = (opts.args or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local session = active_session()
  if not session then
    require("plurnk.client").notify("No active session to fork", vim.log.levels.WARN)
    return
  end
  resolve_session_then(function()
    fork_run_then(session, function(s)
      require("plurnk.run_tab").open(s)
      require("plurnk.client").notify("forked" .. (name ~= "" and (" → " .. name) or ""), vim.log.levels.INFO)
    end, name ~= "" and name or nil)
  end)
end

-- Repaint the conversation waterfall from the canonical log. log.read
-- defaults to the CLIENT run (run-split); pass runId to read the model
-- run (§214). Used when opening a historical conversation.
local function hydrate_current_run(session_name)
  local state = require("plurnk.state")
  local run_id = state.get_run_id(session_name)
  if not run_id then return end
  require("plurnk.client").send("log.read", { runId = run_id, limit = 500 }, false, function(result)
    if type(result) ~= "table" or type(result.entries) ~= "table" then return end
    require("plurnk.run_tab").hydrate(session_name, run_id, result.entries)
  end)
end

-- Find the session's model run (the conversation) via session.runs and
-- adopt it as the conversation run. session.create makes the model run
-- lazily on the first loop.run, so a never-driven session has none yet —
-- then we leave the run pending and the first prompt adopts it. Calls
-- on_done after the lookup (whether or not a model run was found).
local function adopt_model_run(session_name, on_done)
  local id = require("plurnk.state").get_session_id(session_name)
  if not id then if on_done then on_done() end return end
  require("plurnk.client").send("session.runs", { id = id }, false, function(result)
    if type(result) == "table" and type(result.runs) == "table" then
      for _, run in ipairs(result.runs) do  -- most-recent first
        if run.origin == "model" then
          note_model_run(session_name, run.id, run.name)
          break
        end
      end
    end
    if on_done then on_done() end
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

-- #90 — resolve a model alias to "<provider>/<model>" from nvim's OWN (always
-- fresh) env, so a long-lived daemon launched before PLURNK_MODEL_<alias> was
-- exported doesn't reject loop.run with "unknown alias" (the daemon's launch env
-- is frozen; ours isn't). The env value is already "<provider>/<model>" — return
-- it verbatim; the daemon does the first-slash split. Alias suffix is case-folded
-- (PLURNK_MODEL_opus == _OPUS, per the JS parser). nil → send bare {alias}.
function M.resolve_model_spec(alias)
  if not alias or alias == "" then return nil end
  local want = alias:lower()
  for key, val in pairs(vim.fn.environ()) do
    local suffix = key:match("^PLURNK_MODEL_(.+)$")
    if suffix and suffix:lower() == want and type(val) == "string" and val:find("/", 2, true) then
      return val
    end
  end
  return nil
end

local function send_loop_run(session_name, prompt, model_alias, flags)
  -- Bridge mode: the run streams through the portal (agui.run → un-project →
  -- dispatch, so the run-tab renders identically to WS). Per-run knobs (model/
  -- alias/flags/openPaths) ride forwardedProps (agui 0.2.4+; openPaths pending a
  -- bridge run-endpoint read). on_done clears inflight — the terminated event
  -- (dispatched) drives the rest. WS path unchanged (the else below).
  local bridge = require("plurnk.bridge")
  if bridge.enabled() then
    local fwd = {}
    if model_alias then
      local spec = M.resolve_model_spec(model_alias)
      if spec then fwd.model = spec end
      fwd.alias = model_alias
    end
    if flags then fwd.flags = flags end
    local open_paths = extract_open_paths(prompt)
    if #open_paths > 0 then fwd.openPaths = open_paths end
    require("plurnk.state").set_loop_inflight(session_name, true)
    bridge.run(session_name, prompt, { forwardedProps = next(fwd) ~= nil and fwd or nil }, function(_final)
      require("plurnk.state").set_loop_inflight(session_name, false)
      require("plurnk.run_tab").update_status(session_name)
      pcall(vim.cmd, "redrawstatus! | redrawtabline")
    end)
    return
  end
  local client = require("plurnk.client")
  local params = { prompt = prompt }
  if model_alias then
    -- Prefer client-resolved routing (staleness-proof); fall back to the bare
    -- alias (daemon resolves, or errors) when this env declares no such alias.
    local spec = M.resolve_model_spec(model_alias)
    if spec then params.model = spec end   -- "<provider>/<model>"
    params.alias = model_alias             -- always sent, for display
  end
  if flags then params.flags = flags end
  local open_paths = extract_open_paths(prompt)   -- @file refs → daemon turn-0 READs (#260)
  if #open_paths > 0 then params.openPaths = open_paths end
  require("plurnk.state").set_loop_inflight(session_name, true)
  client.send("loop.run", params, false, function(result)
    if type(result) ~= "table" then
      require("plurnk.state").set_loop_inflight(session_name, false)
      return
    end
    -- The conversation lives in the model run (run-split §13.7); loop.run
    -- returns its id. Authoritative — confirms the run the first event's
    -- run_id already adopted, and covers the no-events edge.
    note_model_run(session_name, result.modelRunId)
    -- loop.run is fire-and-forget (svc 0.45+): a finalStatus-100 ack means the
    -- loop is draining ASYNC — stay in-flight; loop/terminated (dispatch.lua)
    -- clears it and carries the real {finalStatus, usage}. A non-100 ack or an
    -- `error` IS terminal (no terminated follows), so settle it here.
    local fs = result.finalStatus
    if result.error ~= nil or (type(fs) == "number" and fs ~= 100) then
      require("plurnk.state").set_loop_inflight(session_name, false)
      local terminal = type(fs) == "number" and fs or result.status
      if type(terminal) == "number" then
        require("plurnk.state").set_final_status(session_name, terminal)
      end
      -- #120: a 501 = no model configured. The daemon's boot-time pointer is easy
      -- to miss under a supervisor; surface the ~/.plurnk/.env pointer here, where
      -- the user is looking (converges the client's no-model hint).
      if terminal == 501 then
        require("plurnk.client").notify(
          "no model configured — edit ~/.plurnk/.env and uncomment one option (local / cloud / plurnk.ai)",
          vim.log.levels.ERROR, session_name)
      end
    end
    require("plurnk.run_tab").update_status(session_name)
    vim.cmd("redrawstatus! | redrawtabline")
  end)
end

-- ── Public command entry points ────────────────────────────────────

-- :PlurnkPrompt {text}. opts.flags rides loop.run verbatim (LoopRunFlags;
-- ask mode arrives here from the `:AI?` prefix).
M.prompt = function(opts)
  local text = wrap_with_selection(opts.args, opts)
  if not text or text == "" then
    require("plurnk.client").notify("PlurnkPrompt: no prompt text", vim.log.levels.WARN)
    return
  end
  resolve_session_then(function(session_name, model_alias)
    require("plurnk.run_tab").open(session_name)
    send_loop_run(session_name, text, model_alias, opts.flags)
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
      warn_if_switching_live()
      require("plurnk.client").send("session.attach", { id = choice.id }, false, function(att)
        if type(att) ~= "table" then return end
        local state = require("plurnk.state")
        state.set_session_id(choice.name, choice.id)
        state.set_active_session_name(choice.name)
        associate_buffer(vim.api.nvim_get_current_buf(), choice.name)
        -- The conversation is the model run, not the client run this attach
        -- bound; find it and hydrate (§214).
        adopt_model_run(choice.name, function()
          require("plurnk.run_tab").open(choice.name)
          hydrate_current_run(choice.name)
        end)
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

-- :PlurnkSessionRename <newname> — rename the active session (session.rename,
-- svc#248). A session's name is a mutable handle on the world; a run's is
-- immutable. Rekeys local state + the run tab in place.
M.session_rename = function(opts)
  local new_name = (opts.args or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if new_name == "" then
    require("plurnk.client").notify(":AI/rename needs a new name", vim.log.levels.WARN)
    return
  end
  local session = active_session()
  if not session then
    require("plurnk.client").notify("No active session to rename", vim.log.levels.WARN)
    return
  end
  resolve_session_then(function()
    require("plurnk.client").send("session.rename", { name = new_name }, false, function(result)
      if type(result) ~= "table" or not result.name then return end
      local state = require("plurnk.state")
      local sid = state.get_session_id(session)
      state.rename_session(session, result.name)
      if sid then state.set_session_id(result.name, sid) end
      state.set_active_session_name(result.name)
      require("plurnk.run_tab").rename(session, result.name)
      associate_buffer(vim.api.nvim_get_current_buf(), result.name)
      require("plurnk.client").notify("renamed " .. session .. " → " .. result.name, vim.log.levels.INFO)
    end)
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
    -- Conversations are model runs; the client/plurnk runs are housekeeping.
    local runs = {}
    for _, r in ipairs(result.runs) do if r.origin == "model" then runs[#runs+1] = r end end
    if #runs == 0 then
      client.notify("No conversations in " .. session, vim.log.levels.INFO)
      return
    end
    vim.ui.select(runs, {
      prompt = "Plurnk conversation (session " .. session .. ")",
      format_item = function(r) return r.name .. "  (" .. (r.created_at or "?") .. ")" end,
    }, function(choice)
      if not choice then return end
      M.switch_run(session, choice.id, function()
        require("plurnk.run_tab").open(session)
        hydrate_current_run(session)
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
      M.set_model(choice.alias)
    end)
  end)
end

-- :AI/model <alias> — set the model directly (sticky); bare opens the picker.
-- Sets the one-shot pick AND the durable session model so it survives past the
-- next loop, and lights immediately in the statusbar/winbar.
M.set_model = function(args)
  local alias = (args or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if alias == "" then M.models() return end
  local state = require("plurnk.state")
  state.set_selected_alias(alias)
  local session = active_session()
  if session then state.set_model_alias(session, alias) end
  require("plurnk.client").notify("Model alias: " .. alias, vim.log.levels.INFO)
  pcall(vim.cmd, "redrawstatus!")
end

-- Membership overlay (svc#200) — service vocabulary, converged with the TUI:
-- pick tracks file(s) in manifest, hide blocks them, view tracks
-- read-only. Live via session.constrain (session-scoped, re-resolved now).
-- Native vim file completion supplies an explicit glob (no bespoke completer).

-- Resolve the membership glob: an explicit arg, else the current buffer's
-- workspace-relative path — the addictive vim move, pick/hide/view THIS file
-- with one keystroke (<leader>ap/ah/av). A non-file buffer with no arg → nil.
local function membership_glob(arg)
  arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if arg ~= "" then return arg end
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or name:match("^%a[%w+.-]*://") then return nil end
  return vim.fn.fnamemodify(name, ":.")  -- cwd-relative == workspace-relative (co-location law)
end

local function constrain(effect, arg)
  local glob = membership_glob(arg)
  if not glob then
    require("plurnk.client").notify(":AI/" .. effect .. " needs a glob, or run it in a file buffer", vim.log.levels.WARN)
    return
  end
  resolve_session_then(function(session_name)
    require("plurnk.client").send("session.constrain", { effect = effect, glob = glob }, false, function()
      require("plurnk.client").notify(effect .. ": " .. glob, vim.log.levels.INFO)
      require("plurnk.signs").refresh(session_name)
    end)
  end)
end

M.pick = function(opts) constrain("pick", opts.args) end
M.hide = function(opts) constrain("hide", opts.args) end
M.view = function(opts) constrain("view", opts.args) end

-- :PlurnkRepo [dir] — track a git repo in selected folder (svc#242): its ls-files
-- join membership, addressed relative to the project root. repo is a
-- DIRECTORY, not a file — the current-file default would be wrong, so with
-- no arg we default to the current buffer's DIRECTORY (`%:h`), not the file.
M.repo = function(opts)
  local arg = (opts.args or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local dir = arg
  if dir == "" then
    local name = vim.api.nvim_buf_get_name(0)
    if name == "" or name:match("^%a[%w+.-]*://") then
      require("plurnk.client").notify(":AI/repo needs a directory, or run it in a file buffer", vim.log.levels.WARN)
      return
    end
    dir = vim.fn.fnamemodify(name, ":.:h")  -- workspace-relative dir of the current file
  end
  resolve_session_then(function(session_name)
    require("plurnk.client").send("session.constrain", { effect = "repo", glob = dir }, false, function()
      require("plurnk.client").notify("repo: " .. dir, vim.log.levels.INFO)
      require("plurnk.signs").refresh(session_name)
    end)
  end)
end

-- :PlurnkDrop [glob] — remove the constraint(s) matching the glob (any effect);
-- no arg drops the current file's constraints.
M.drop = function(opts)
  local glob = membership_glob(opts.args)
  if not glob then
    require("plurnk.client").notify(":AI/drop needs a glob, or run it in a file buffer", vim.log.levels.WARN)
    return
  end
  resolve_session_then(function(session_name)
    require("plurnk.client").send("session.constraints", {}, false, function(result)
      local constraints = type(result) == "table" and result.constraints or {}
      local matches = vim.tbl_filter(function(c) return c.glob == glob end, constraints)
      if #matches == 0 then
        require("plurnk.client").notify("no constraint matching " .. glob, vim.log.levels.WARN)
        return
      end
      for _, c in ipairs(matches) do
        require("plurnk.client").send("session.unconstrain", { effect = c.effect, glob = c.glob }, false)
      end
      require("plurnk.client").notify("dropped " .. #matches .. " constraint(s): " .. glob, vim.log.levels.INFO)
      require("plurnk.signs").refresh(session_name)
    end)
  end)
end

-- :PlurnkMembers — the model's RESOLVED file universe (svc#243), daemon-
-- resolved (ls-files ∪ pick) − hide. NOT the rule globs: showing the rules
-- here would misinform — they're the deltas, not what the model sees. The
-- constraint list rides along as a footer (it's what /drop targets).
M.members = function()
  resolve_session_then(function()
    local client = require("plurnk.client")
    client.send("session.members", {}, false, function(result)
      local members = type(result) == "table" and result.members or {}
      local hidden = type(result) == "table" and result.hidden or {}
      local editable, view = {}, {}
      for _, m in ipairs(members) do
        if m.effect == "view" then view[#view + 1] = m.path else editable[#editable + 1] = m.path end
      end
      local lines = {}
      if #members == 0 and #hidden == 0 then
        lines[1] = "the model's universe is empty — no members (/pick a file or /repo a folder)"
      else
        lines[1] = string.format("the model's universe: %d file%s — %d editable, %d read-only%s",
          #members, #members == 1 and "" or "s", #editable, #view,
          #hidden > 0 and (", " .. #hidden .. " hidden") or "")
        for _, p in ipairs(view) do lines[#lines + 1] = "  view    " .. p end
        for _, p in ipairs(hidden) do lines[#lines + 1] = "  hidden  " .. p end
        if #editable <= 40 then
          for _, p in ipairs(editable) do lines[#lines + 1] = "  member  " .. p end
        else
          lines[#lines + 1] = string.format("  member  …%d editable files (git-tracked); listing suppressed", #editable)
        end
      end
      -- the rules that produced this — also what /drop targets; NOT the universe
      client.send("session.constraints", {}, false, function(cres)
        local constraints = type(cres) == "table" and cres.constraints or {}
        if #constraints == 0 then
          lines[#lines + 1] = "rules: none (git-tracked files only)"
        else
          local parts = {}
          for _, c in ipairs(constraints) do parts[#parts + 1] = c.effect .. " " .. c.glob end
          lines[#lines + 1] = "rules: " .. table.concat(parts, ", ")
        end
        client.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
      end)
    end)
  end)
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

-- :PlurnkAuth <target> — OAuth an auth-protected exec (e.g. notion) via the
-- device grant (#116): prints a URL + code, polls to authorized. No browser
-- open, no local callback — works over a remote daemon / jumpbox.
M.auth = function(opts)
  require("plurnk.auth").run(opts and opts.args)
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

-- `:AI/` bare (or /help) — the whole language on one screen. This is
-- the entire discoverability budget: no menus, no tutorial mode.
local HELP = table.concat({
  ":AI                toggle session tab ⇄ where you came from",
  ":AI <text>         prompt (act)",
  ":AI? <text>        ASK — read-only loop; edits/exec 403 at dispatch",
  ":AI: <text>        act (the default)",
  ":AI! <cmd>         exec via the daemon; bare ! execs the visual selection",
  ":AI?? / ::         new session    ??? headless    ???? new run (fork)",
  ":AI... <text>      inject into the running model loop (loop.inject)",
  ":AI/<verb>         models sessions runs session run rename log yolo ping",
  "                   pick hide view repo drop members (membership overlay)",
  "                   script <path> (run a .plk file via op.parse)",
  "                   open accept reject next prev stop clear",
  "visual             '<,'>AI? … prepends the selection",
  "input buffer       ? ask · : act · ! exec · << raw DSL · <CR> submits",
}, "\n")

local function show_help()
  vim.api.nvim_echo({ { HELP, "None" } }, false, {})
end

-- :AI/script <path> (:PlurnkScript) — run a .plk file: read its DSL, ship the
-- text to op.parse, let the daemon parse + dispatch each statement. Op traces
-- arrive as log/entry (rendered in the waterfall); the callback reports the op
-- count + worst status. The client never parses the file — the daemon owns the
-- grammar, so the .plk language can grow without touching this surface.
M.script = function(opts)
  local client = require("plurnk.client")
  local path = vim.fn.trim((opts and opts.args) or "")
  if path == "" then
    client.notify(":AI/script needs a path to a .plk file", vim.log.levels.WARN)
    return
  end
  local abs = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  if vim.fn.filereadable(abs) == 0 then
    client.notify(":AI/script — file not readable: " .. abs, vim.log.levels.WARN)
    return
  end
  local text = table.concat(vim.fn.readfile(abs), "\n")
  client.send("op.parse", { text = text }, false, function(result)
    if type(result) ~= "table" or type(result.results) ~= "table" then return end
    local worst = 0
    for _, r in ipairs(result.results) do
      if type(r.status) == "number" and r.status > worst then worst = r.status end
    end
    local n = #result.results
    local msg = string.format("script: %d op%s", n, n == 1 and "" or "s")
    if worst >= 400 then
      client.notify(msg .. ", worst status " .. worst, vim.log.levels.WARN)
    else
      client.notify(msg .. " ok", vim.log.levels.INFO)
    end
  end)
end

-- `/` subcommand routing — rummy's full surface, plurnk verbs. Wrapped
-- as functions so the M.* lookups resolve at call time.
local SLASH = {
  stop     = function() M.stop() end,
  clear    = function() M.clear() end,
  abort    = function() M.stop() end,
  models   = function() M.models() end,
  -- `/model <alias>` sets it directly (converged with the TUI); bare `/model`
  -- opens the picker. Completion offers aliases (see ai_complete).
  model    = function(args) M.set_model(args) end,
  -- Singular CREATEs, plural LISTs (converged with the TUI): /session opens a
  -- fresh session, /sessions lists; /run forks a new run, /runs lists. The old
  -- ambiguous /new (session or run?) is gone.
  sessions = function() M.sessions() end,
  runs     = function() M.session_runs() end,
  session  = function(args) M.session_new({ args = args }) end,
  rename   = function(args) M.session_rename({ args = args }) end,
  run      = function(args) M.fork({ args = args }) end,
  log      = function(args) M.log({ args = args }) end,
  pick     = function(args) M.pick({ args = args }) end,
  hide     = function(args) M.hide({ args = args }) end,
  view     = function(args) M.view({ args = args }) end,
  repo     = function(args) M.repo({ args = args }) end,
  drop     = function(args) M.drop({ args = args }) end,
  members  = function() M.members() end,
  script   = function(args) M.script({ args = args }) end,
  yolo     = function() M.yolo() end,
  ping     = function() M.ping() end,
  open     = function() M.toggle() end,
  accept   = function() M.accept() end,
  reject   = function() M.reject() end,
  next     = function() M.next() end,
  prev     = function() M.prev() end,
}

-- Cmdline completion for :AI — alias names after `/model `, slash verbs after a
-- bare `/`. customlist (we filter ourselves; vim doesn't). available_aliases is
-- warmed by check_daemon_once / :PlurnkModels; fire a background fetch if cold.
M.ai_complete = function(_arglead, cmdline, _)
  local state = require("plurnk.state")
  local model_partial = cmdline:match("/model%s+(%S*)$")
  if model_partial then
    local aliases = state.get_available_aliases()
    if #aliases == 0 then
      pcall(function()
        require("plurnk.client").send("providers.list", {}, false, function(r)
          if type(r) == "table" and type(r.aliases) == "table" then state.set_available_aliases(r.aliases) end
        end)
      end)
    end
    local out = {}
    for _, a in ipairs(aliases) do
      if vim.startswith(a.alias, model_partial) then out[#out + 1] = a.alias end
    end
    table.sort(out)
    return out
  end
  -- `/script <path>` — file completion (mirrors :PlurnkScript's complete="file").
  local script_partial = cmdline:match("/script%s+(%S*)$")
  if script_partial then
    return vim.fn.getcompletion(script_partial, "file")
  end
  local verb_partial = cmdline:match("/(%S*)$")
  if verb_partial and not cmdline:match("/%S+%s") then
    local out = {}
    for verb in pairs(SLASH) do
      if vim.startswith(verb, verb_partial) then out[#out + 1] = "/" .. verb end
    end
    table.sort(out)
    return out
  end
  return {}
end

-- :AI — the central user command. Rummy's metacommand language, adapted
-- to the daemon-owned loop (no client-side mode taxonomy):
--
--   :AI                 → toggle: session tab ⇄ where you came from
--   :AI <text>          → loop.run with prompt (visual selection prepended)
--   :AI? <text>         → ASK: loop.run with flags.mode="ask" — schemes
--                         declaring excludedInAsk (file edits, exec, …)
--                         403 at dispatch; read-only conversation
--   :AI: <text>         → act (the default posture)
--   :AI! <cmd>          → op.exec — daemon-owned shell, output streams
--                         into the stream split; no <cmd> execs the
--                         visual selection verbatim
--   :AI?? <text>        → NEW session, then prompt
--   :AI??? <text>       → new HEADLESS session (no projectRoot), then prompt
--   :AI???? <text>      → new RUN in the current session (fork-lite)
--   :AI... <text>       → mid-loop inject into the model run (loop.inject)
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
    -- BTW inject (plurnk-service#193): speak into the running model loop.
    -- The daemon targets the session's model run (ctx.session.modelRunId)
    -- — there must be one (start a loop first).
    local msg = raw:sub(4):gsub("^%s+", "")
    if msg == "" then
      require("plurnk.client").notify(":AI... needs a message to inject", vim.log.levels.WARN)
      return
    end
    require("plurnk.client").send("loop.inject", { prompt = msg }, false, function(result)
      if type(result) == "table" and type(result.status) == "number" and result.status >= 400 then
        require("plurnk.client").notify("inject rejected: " .. tostring(result.error or result.status), vim.log.levels.WARN)
      end
    end)
    return
  end

  if raw:sub(1, 1) == "/" then
    local sub, sub_args = raw:match("^/(%S+)%s*(.*)$")
    if sub == nil or sub == "help" then return show_help() end
    local handler = SLASH[sub]
    if handler then return handler(sub_args or "") end
    require("plurnk.client").notify(":AI/" .. tostring(sub) .. " is unknown — :AI/ for the language", vim.log.levels.WARN)
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

  -- `?` is ASK — the engine enforces it (#checkFlagsGate: schemes with
  -- excludedInAsk go 403 under flags.mode="ask"); the client just
  -- states the posture. `:` is act, the daemon default — send nothing.
  local flags = first == "?" and { mode = "ask" } or nil

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
        send_loop_run(session_name, wrapped, require("plurnk.client").consume_selected_alias(), flags)
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

  -- Single-prefix (`?`, `:`) or bare text — prompt, with ask flags when
  -- the prefix says so.
  M.prompt({ args = rest, range = opts.range or 0,
    line1 = opts.line1, line2 = opts.line2, flags = flags })
end

-- ── Setup ──────────────────────────────────────────────────────────

M.setup = function()
  local cmd = vim.api.nvim_create_user_command

  cmd("PlurnkPrompt",      M.prompt,       { nargs = "*", range = true })
  cmd("PlurnkSessions",    M.sessions,     {})
  cmd("PlurnkSessionNew",  M.session_new,  { nargs = "?" })
  cmd("PlurnkSessionRename", M.session_rename, { nargs = "?" })
  cmd("PlurnkFork",        M.fork,         { nargs = "?" })
  cmd("PlurnkSessionRuns", M.session_runs, {})
  cmd("PlurnkModels",      M.models,       {})
  cmd("PlurnkLog",         M.log,          { nargs = "?" })
  cmd("PlurnkPick",        M.pick,         { nargs = "?", complete = "file" })
  cmd("PlurnkHide",        M.hide,         { nargs = "?", complete = "file" })
  cmd("PlurnkView",        M.view,         { nargs = "?", complete = "file" })
  cmd("PlurnkRepo",        M.repo,         { nargs = "?", complete = "dir" })
  cmd("PlurnkDrop",        M.drop,         { nargs = "?", complete = "file" })
  cmd("PlurnkMembers",     M.members,      {})
  cmd("PlurnkScript",      M.script,       { nargs = 1, complete = "file" })
  cmd("PlurnkYolo",        M.yolo,         {})
  cmd("PlurnkAuth",        M.auth,         { nargs = 1 })
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
  cmd("AI", M.ai, { nargs = "*", range = true, bang = true, complete = M.ai_complete })

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
