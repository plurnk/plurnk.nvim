-- [§nvim-ai-language][§nvim-scope-repetition]
-- The :AI metacommand language (#16 phase 1): cmdline abbreviations
-- (`:AI?` without a space), scope prefixes (`???` headless workspace,
-- `????` fork-lite new worker), full `/` routing, and `:AI` toggle.
-- Pure module path; stubs client.send + transport.stop.
local NAME = "15_ai_language"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local sent = {}
  require("plurnk.bridge").run = function(_t, prompt, opts, on_done)
    local fwd = (opts and opts.forwardedProps) or {}
    table.insert(sent, { method = "loop.run", params = vim.tbl_extend("force", { prompt = prompt }, fwd) })
    if on_done then on_done(200) end
    return nil
  end
  -- Rebind in place (§13.5, v0.17.0): switching never drops the socket.
  local stops = 0
  require("plurnk.client").send = function(method, params, _, cb)
    table.insert(sent, { method = method, params = params })
    -- workspace.create returns the worker identity directly (§13.5-workspace-create).
    if method == "workspace.create" and cb then cb({ id = 7, name = "lang-" .. #sent, workerId = 42, workerName = "auto-run" }) end
    if method == "workspace.attach" and cb then cb({ id = 7, workerId = 42, workerName = "auto-run" }) end
    if method == "loop.cancel" and cb then cb({ cancelled = true, workerId = 9 }) end
    if method == "worker.fork" and cb then cb({ workerId = 99, workerName = "fork-run" }) end
  end
  local function find(list, method)
    for _, m in ipairs(list) do if m.method == method then return m end end
    return nil
  end
  require("plurnk.state").set_project_path("/tmp/lang-proj")

  -- ── Abbreviation: `:AI? hello` typed with NO space after AI ────────
  -- Without the cabbrev this is E492 (`?` can't be in a command name).
  vim.api.nvim_feedkeys(":AI? hello\r", "x", false)
  H.assert_eq(sent[1].method, "workspace.create", "abbrev :AI? creates workspace")
  local lr = find(sent, "loop.run")
  H.assert_truthy(lr, "abbrev :AI? runs loop")
  H.assert_eq(lr.params.prompt, "hello", "abbrev :AI? strips prefix")

  local ai = require("plurnk.commands").ai

  -- ── `???` — new HEADLESS workspace (no projectRoot) ──────────────────
  sent = {}
  ai({ args = "??? bare metal", range = 0 })
  H.assert_eq(sent[1].method, "workspace.create", ":AI??? creates a workspace")
  H.assert_eq(sent[1].params.projectRoot, nil, ":AI??? omits projectRoot")
  local lr3 = find(sent, "loop.run")
  H.assert_truthy(lr3, ":AI??? then loop.run")
  H.assert_eq(lr3.params.prompt, "bare metal", ":AI??? carries prompt")

  -- ── `????` — conversation fork (worker.fork, svc#248, now wired) ──────
  -- Branch the model worker, bind the connection to the fork, then speak the
  -- prompt into it: worker.fork → workspace.attach(workerId) → loop.run.
  sent = {}
  ai({ args = "???? take two", range = 0 })
  H.assert_truthy(find(sent, "worker.fork"), ":AI???? forks via worker.fork")
  local lrf = find(sent, "loop.run")
  H.assert_truthy(lrf, ":AI???? runs a loop in the fork")
  H.assert_eq(lrf.params.prompt, "take two", ":AI???? carries the prompt into the fork")

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

  -- ask survives scope repetition: `??` = new workspace, still ask
  sent = {}
  ai({ args = "?? fresh ask", range = 0 })
  local ask2 = find(sent, "loop.run")
  H.assert_eq(ask2.params.flags and ask2.params.flags.mode, "ask", ":AI?? carries ask into the new workspace")

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

  -- ── `/script <path>` — read a .plk file, ship its DSL to op.parse ──
  -- The client never parses the file; it feeds the raw text verbatim.
  sent = {}
  local plk = vim.fn.tempname() .. ".plk"
  vim.fn.writefile({ "<<EDIT(known://x/a):hi:EDIT", "<<READ(known://x/a):READ" }, plk)
  ai({ args = "/script " .. plk, range = 0 })
  H.assert_eq(sent[1].method, "op.parse", ":AI/script routes to op.parse")
  H.assert_truthy(sent[1].params.text:match("<<EDIT%(known://x/a%)"), ":AI/script ships raw file text")
  H.assert_truthy(sent[1].params.text:match("\n"), ":AI/script ships all statements (multiline)")

  sent = {}
  ai({ args = "/script /no/such/file.plk", range = 0 })
  H.assert_eq(#sent, 0, ":AI/script on a missing file sends nothing")

  sent = {}
  ai({ args = "/script", range = 0 })
  H.assert_eq(#sent, 0, ":AI/script with no path sends nothing")

  -- ── `...` — inject into the running model loop (loop.inject, #193) ──
  sent = {}
  ai({ args = "... remember the TOML", range = 0 })
  H.assert_eq(sent[1].method, "loop.inject", ":AI... sends loop.inject")
  H.assert_eq(sent[1].params.prompt, "remember the TOML", ":AI... carries the message")

  -- ── `:AI` bare — toggle: workspace tab ⇄ origin ──────────────────────
  vim.cmd("tabnew")  -- a non-plurnk tab to come from
  local origin = vim.api.nvim_get_current_tabpage()
  ai({ args = "", range = 0 })
  local workspace_tab = vim.api.nvim_get_current_tabpage()
  H.assert_truthy(workspace_tab ~= origin, ":AI opens the workspace tab")
  H.assert_truthy(require("plurnk.worker_tab").workspace_for_tabpage(workspace_tab),
    ":AI lands on a workspace tabpage")
  ai({ args = "", range = 0 })
  H.assert_eq(vim.api.nvim_get_current_tabpage(), origin, ":AI again returns to origin")

  -- Rebind in place: across every workspace/worker switch above, the socket
  -- was never dropped (§13.5-rebind).
  H.assert_eq(stops, 0, "switching never reconnects the transport")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
