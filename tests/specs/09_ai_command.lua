-- :AI command — prefix-stripping, /stop, ??-new-session.
-- Pure module path; stubs client.send so no daemon round-trip.
local NAME = "09_ai_command"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local captured = {}
  require("plurnk.client").send = function(method, params, _, cb)
    table.insert(captured, { method = method, params = params })
    -- For session.create called by `??`, fire the callback (returning the
    -- run identity directly, §13.5-session-create) so the second send
    -- (loop.run) actually happens.
    if method == "session.create" and cb then
      cb({ id = 99, name = "ai-test-session", runId = 7, runName = "auto-run" })
    end
  end
  local function find(list, method)
    for _, m in ipairs(list) do if m.method == method then return m end end
    return nil
  end

  -- Bind a session so prompt() can resolve.
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].plurnk_session = "smoke"
  require("plurnk.state").set_session_id("smoke", 1)

  local ai = require("plurnk.commands").ai

  -- :AI: Hello, world.
  ai({ args = ": Hello, world.", range = 0 })
  H.assert_eq(captured[#captured].method, "loop.run", ":AI: routes to loop.run")
  H.assert_eq(captured[#captured].params.prompt, "Hello, world.", ":AI: strips colon")

  -- :AI? plain
  captured = {}
  ai({ args = "? what is france", range = 0 })
  H.assert_eq(captured[1].params.prompt, "what is france", ":AI? strips ?")

  -- :AI! cmd → op.exec (daemon-owned Run mode, #16 phase 2)
  captured = {}
  ai({ args = "! git status", range = 0 })
  H.assert_eq(captured[1].method, "op.exec", ":AI! routes to op.exec")
  H.assert_eq(captured[1].params.command, "git status", ":AI! carries the command")

  -- :AI!cmd via bang (the unabbreviated parse: bang=true, args="cmd")
  captured = {}
  ai({ args = "git diff", bang = true, range = 0 })
  H.assert_eq(captured[1].method, "op.exec", ":AI! bang form routes to op.exec")
  H.assert_eq(captured[1].params.command, "git diff", ":AI! bang form carries the command")

  -- :AI no prefix
  captured = {}
  ai({ args = "plain", range = 0 })
  H.assert_eq(captured[1].params.prompt, "plain", ":AI plain text")

  -- :AI with @file refs → loop.run.openPaths (daemon foists turn-0 READs, #260)
  captured = {}
  ai({ args = ": summarize @src/a.ts and @docs/b.md", range = 0 })
  H.assert_eq(captured[1].method, "loop.run", "@file: routes to loop.run")
  H.assert_truthy(captured[1].params.openPaths, "@file: openPaths present")
  H.assert_eq(captured[1].params.openPaths[1], "src/a.ts", "@file: first ref")
  H.assert_eq(captured[1].params.openPaths[2], "docs/b.md", "@file: second ref")

  -- :AI?? on a session-attached buffer: drops the bound connection and
  -- creates a NEW session by rebinding the connection in place
  -- (§13.5-rebind, v0.17.0 — no reconnect).
  local stops = 0
  require("plurnk.transport").stop = function() stops = stops + 1 end
  captured = {}
  ai({ args = "?? new chat", range = 0 })
  H.assert_eq(stops, 0, ":AI?? rebinds in place, never drops the socket")
  H.assert_eq(captured[1].method, "session.create", ":AI?? creates a new session")
  H.assert_eq(captured[1].params.settings.client, "plurnk.nvim", ":AI?? session.create carries the client id (#249)")
  local lr = find(captured, "loop.run")
  H.assert_truthy(lr, ":AI?? then loop.run")
  H.assert_eq(lr.params.prompt, "new chat", ":AI?? carries prompt")

  -- :AI?? on a fresh buffer with no session: session.create then loop.run.
  -- Move to a fresh empty buffer so no plurnk_session is bound here.
  vim.cmd("enew")
  require("plurnk.state").set_active_session_name(nil)
  captured = {}
  ai({ args = "?? fresh chat", range = 0 })
  H.assert_eq(captured[1].method, "session.create", ":AI?? creates session when none attached")
  local lr2 = find(captured, "loop.run")
  H.assert_truthy(lr2, ":AI?? then loop.run")
  H.assert_eq(lr2.params.prompt, "fresh chat", ":AI?? carries prompt after session.create")

  -- :AI/stop with an active session — cancels the run's loop over the
  -- wire (loop.cancel landed in plurnk-service 0.8.0).
  captured = {}
  ai({ args = "/stop", range = 0 })
  H.assert_eq(captured[1].method, "loop.cancel", ":AI/stop sends loop.cancel")

  -- :AI/stop with NO session — proposal cleanup only, no RPC.
  vim.cmd("enew")
  require("plurnk.state").set_active_session_name(nil)
  vim.b.plurnk_session = nil
  captured = {}
  ai({ args = "/stop", range = 0 })
  H.assert_eq(#captured, 0, ":AI/stop without session sends nothing")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
