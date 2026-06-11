-- :AI command — prefix-stripping, /stop, ??-new-session.
-- Pure module path; stubs client.send so no daemon round-trip.
local NAME = "09_ai_command"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local captured = {}
  require("plurnk.client").send = function(method, params, _, cb)
    table.insert(captured, { method = method, params = params })
    -- For session.create called by `??`, fire the callback so the
    -- second send (loop.run) actually happens.
    if method == "session.create" and cb then
      cb({ id = 99, name = "ai-test-session" })
    end
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

  -- :AI! cmd
  captured = {}
  ai({ args = "! show repo", range = 0 })
  H.assert_eq(captured[1].params.prompt, "show repo", ":AI! strips !")

  -- :AI no prefix
  captured = {}
  ai({ args = "plain", range = 0 })
  H.assert_eq(captured[1].params.prompt, "plain", ":AI plain text")

  -- :AI?? on a session-attached buffer: drops the bound connection and
  -- creates a NEW session (the wire allows one session per connection;
  -- switching = reconnect).
  local stops = 0
  require("plurnk.transport").stop = function() stops = stops + 1 end
  captured = {}
  ai({ args = "?? new chat", range = 0 })
  H.assert_eq(stops, 1, ":AI?? on attached buffer drops the connection")
  H.assert_eq(captured[1].method, "session.create", ":AI?? creates a new session")
  H.assert_eq(captured[2].method, "loop.run", ":AI?? then loop.run")
  H.assert_eq(captured[2].params.prompt, "new chat", ":AI?? carries prompt")

  -- :AI?? on a fresh buffer with no session: session.create then loop.run.
  -- Move to a fresh empty buffer so no plurnk_session is bound here.
  vim.cmd("enew")
  require("plurnk.state").set_active_session_name(nil)
  captured = {}
  ai({ args = "?? fresh chat", range = 0 })
  H.assert_eq(captured[1].method, "session.create", ":AI?? creates session when none attached")
  H.assert_eq(captured[2].method, "loop.run", ":AI?? then loop.run")
  H.assert_eq(captured[2].params.prompt, "fresh chat", ":AI?? carries prompt after session.create")

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
