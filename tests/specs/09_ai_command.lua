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

  -- :AI?? prompt → fresh session.create followed by loop.run.
  captured = {}
  ai({ args = "?? new chat", range = 0 })
  H.assert_eq(captured[1].method, "session.create", ":AI?? creates session")
  H.assert_eq(captured[2].method, "loop.run", ":AI?? then loop.run")
  H.assert_eq(captured[2].params.prompt, "new chat", ":AI?? carries prompt")

  -- :AI/stop with empty stack — must not error, must not call any RPC.
  captured = {}
  ai({ args = "/stop", range = 0 })
  H.assert_eq(#captured, 0, ":AI/stop on empty stack")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
