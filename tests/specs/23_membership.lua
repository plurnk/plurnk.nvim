-- Membership overlay commands (svc#200), converged with the TUI's
-- /pick /hide /view /drop /members. Service vocabulary; live via
-- session.constrain / unconstrain / constraints. Pure module path; no daemon.
local NAME = "23_membership"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local sent = {}
  require("plurnk.client").send = function(method, params, _, cb)
    table.insert(sent, { method = method, params = params })
    if method == "session.constraints" and cb then
      cb({ constraints = { { effect = "hide", glob = "*.lock" }, { effect = "pick", glob = "docs/**" } } })
    end
  end
  require("plurnk.client").check_daemon_once = function() end
  -- An active session → resolve_session_then short-circuits straight to the send.
  require("plurnk.state").set_active_session_name("memb")

  local cmds = require("plurnk.commands")
  local function last(method)
    for i = #sent, 1, -1 do if sent[i].method == method then return sent[i] end end
    return nil
  end

  -- /pick /hide /view → session.constrain with the SERVICE vocabulary
  cmds.pick({ args = "src/**" })
  H.assert_eq(last("session.constrain").params.effect, "pick", "/pick → effect=pick")
  H.assert_eq(last("session.constrain").params.glob, "src/**", "/pick carries the glob")
  cmds.hide({ args = "*.lock" })
  H.assert_eq(last("session.constrain").params.effect, "hide", "/hide → effect=hide")
  cmds.view({ args = "vendor/**" })
  H.assert_eq(last("session.constrain").params.effect, "view", "/view → effect=view")

  -- no arg + a real file buffer → picks the CURRENT file (the one-keystroke
  -- vim move). The glob is the buffer's workspace-relative path.
  sent = {}
  vim.api.nvim_buf_set_name(0, "src/widget.lua")
  cmds.pick({ args = "" })
  local cur = last("session.constrain")
  H.assert_truthy(cur ~= nil and cur.params.glob:match("widget%.lua"), "no-arg pick uses the current file")
  H.assert_eq(cur.params.effect, "pick", "current-file pick → effect=pick")

  -- no arg in a non-file (scheme://) buffer → nothing sent
  sent = {}
  vim.api.nvim_buf_set_name(0, "plurnk://session/x")
  cmds.pick({ args = "" })
  H.assert_eq(#sent, 0, "no-arg in a non-file buffer sends nothing")

  -- /drop → list, then unconstrain the matching glob (any effect)
  sent = {}
  cmds.drop({ args = "*.lock" })
  H.assert_eq(sent[1].method, "session.constraints", "/drop lists constraints first")
  local un = last("session.unconstrain")
  H.assert_truthy(un and un.params.effect == "hide" and un.params.glob == "*.lock",
    "/drop unconstrains the matching hide *.lock")

  -- /drop with no match → no unconstrain
  sent = {}
  cmds.drop({ args = "nomatch/**" })
  H.assert_truthy(last("session.unconstrain") == nil, "/drop with no match unconstrains nothing")

  -- /members → list
  sent = {}
  cmds.members()
  H.assert_eq(sent[1].method, "session.constraints", "/members lists constraints")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
