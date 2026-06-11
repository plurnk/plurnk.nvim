-- The :AI metacommand language (#16 phase 1): cmdline abbreviations
-- (`:AI?` without a space), scope prefixes (`???` headless session,
-- `????` fork-lite new run), full `/` routing, and `:AI` toggle.
-- Pure module path; stubs client.send + transport.stop.
local NAME = "15_ai_language"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local sent = {}
  local stops = 0
  require("plurnk.transport").stop = function() stops = stops + 1 end
  require("plurnk.client").send = function(method, params, _, cb)
    table.insert(sent, { method = method, params = params })
    if method == "session.create" and cb then cb({ id = 7, name = "lang-" .. #sent }) end
    if method == "session.attach" and cb then cb({ id = 7, runId = 42, runName = "auto-run" }) end
    if method == "session.runs" and cb then cb({ runs = { { id = 42, name = "auto-run" } } }) end
    if method == "loop.cancel" and cb then cb({ cancelled = true, runId = 9 }) end
  end
  local function find(list, method)
    for _, m in ipairs(list) do if m.method == method then return m end end
    return nil
  end
  require("plurnk.state").set_project_path("/tmp/lang-proj")

  -- ── Abbreviation: `:AI? hello` typed with NO space after AI ────────
  -- Without the cabbrev this is E492 (`?` can't be in a command name).
  vim.api.nvim_feedkeys(":AI? hello\r", "x", false)
  H.assert_eq(sent[1].method, "session.create", "abbrev :AI? creates session")
  local lr = find(sent, "loop.run")
  H.assert_truthy(lr, "abbrev :AI? runs loop")
  H.assert_eq(lr.params.prompt, "hello", "abbrev :AI? strips prefix")

  local ai = require("plurnk.commands").ai

  -- ── `???` — new HEADLESS session (no projectRoot) ──────────────────
  sent = {}
  ai({ args = "??? bare metal", range = 0 })
  H.assert_eq(stops, 1, ":AI??? drops the bound connection")
  H.assert_eq(sent[1].method, "session.create", ":AI??? creates a session")
  H.assert_eq(sent[1].params.projectRoot, nil, ":AI??? omits projectRoot")
  local lr3 = find(sent, "loop.run")
  H.assert_truthy(lr3, ":AI??? then loop.run")
  H.assert_eq(lr3.params.prompt, "bare metal", ":AI??? carries prompt")

  -- ── `????` — fork-lite: new run in the CURRENT session ─────────────
  sent = {}
  ai({ args = "???? take two", range = 0 })
  H.assert_eq(stops, 2, ":AI???? drops the connection")
  H.assert_eq(sent[1].method, "session.attach", ":AI???? re-attaches the session")
  H.assert_eq(sent[1].params.id, 7, ":AI???? attaches by current session id")
  H.assert_eq(sent[1].params.runName, nil, ":AI???? omits runName (daemon mints a fresh run)")
  H.assert_eq(sent[2].method, "loop.run", ":AI???? then loop.run")
  H.assert_eq(sent[2].params.prompt, "take two", ":AI???? carries prompt")

  -- ── `?` is ASK: flags.mode="ask" rides loop.run; `:` is act ────────
  sent = {}
  ai({ args = "? read only please", range = 0 })
  local ask = find(sent, "loop.run")
  H.assert_truthy(ask, ":AI? runs a loop")
  H.assert_eq(ask.params.flags and ask.params.flags.mode, "ask", ":AI? sends flags.mode=ask")

  sent = {}
  ai({ args = ": change things", range = 0 })
  local act = find(sent, "loop.run")
  H.assert_truthy(act, ":AI: runs a loop")
  H.assert_eq(act.params.flags, nil, ":AI: sends no flags (act is the daemon default)")

  -- ask survives scope repetition: `??` = new session, still ask
  sent = {}
  ai({ args = "?? fresh ask", range = 0 })
  local ask2 = find(sent, "loop.run")
  H.assert_eq(ask2.params.flags and ask2.params.flags.mode, "ask", ":AI?? carries ask into the new session")

  -- ── `/` routing ────────────────────────────────────────────────────
  sent = {}
  ai({ args = "/ping", range = 0 })
  H.assert_eq(sent[1].method, "ping", ":AI/ping routes to PlurnkPing")

  sent = {}
  ai({ args = "/models", range = 0 })
  H.assert_eq(sent[1].method, "providers.list", ":AI/models routes to PlurnkModels")

  sent = {}
  ai({ args = "/stop", range = 0 })
  H.assert_eq(sent[1].method, "loop.cancel", ":AI/stop sends loop.cancel")

  sent = {}
  ai({ args = "/bogus", range = 0 })
  H.assert_eq(#sent, 0, ":AI/bogus sends nothing")

  -- ── `...` — inject is blocked upstream; notify, no RPC ─────────────
  sent = {}
  ai({ args = "... remember the TOML", range = 0 })
  H.assert_eq(#sent, 0, ":AI... sends nothing until plurnk-service#193")

  -- ── `:AI` bare — toggle: session tab ⇄ origin ──────────────────────
  vim.cmd("tabnew")  -- a non-plurnk tab to come from
  local origin = vim.api.nvim_get_current_tabpage()
  ai({ args = "", range = 0 })
  local session_tab = vim.api.nvim_get_current_tabpage()
  H.assert_truthy(session_tab ~= origin, ":AI opens the session tab")
  H.assert_truthy(require("plurnk.run_tab").session_for_tabpage(session_tab),
    ":AI lands on a session tabpage")
  ai({ args = "", range = 0 })
  H.assert_eq(vim.api.nvim_get_current_tabpage(), origin, ":AI again returns to origin")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
