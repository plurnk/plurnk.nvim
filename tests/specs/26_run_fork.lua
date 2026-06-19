-- run.fork (svc#248): :PlurnkFork / :AI???? branch the conversation into a new
-- run, optionally named at instantiation (immutable after), then bind to it.
local NAME = "26_run_fork"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local sent = {}
  require("plurnk.client").send = function(method, params, _, cb)
    sent[#sent + 1] = { method = method, params = params }
    if method == "run.fork" and cb then cb({ runId = 42, runName = params.name or "main-fork" }) end
    if method == "session.attach" and cb then cb({ runId = 42, runName = "main-fork" }) end
  end
  require("plurnk.client").check_daemon_once = function() end
  require("plurnk.client").consume_selected_alias = function() return nil end
  require("plurnk.client").get_session_model = function() return nil end
  local rt = require("plurnk.run_tab")
  rt.open = function() end
  rt.note_run_resolved = function() end
  rt.current_alias = function() return nil end

  local state = require("plurnk.state")
  state.set_active_session_name("s")
  state.set_session_id("s", 9)
  state.set_run_id("s", 5)  -- a model run exists to fork

  local cmds = require("plurnk.commands")

  -- named fork → run.fork {name}, then attach binds the new run
  cmds.fork({ args = "branch-a" })
  local fork, attach
  for _, e in ipairs(sent) do
    if e.method == "run.fork" then fork = e end
    if e.method == "session.attach" then attach = e end
  end
  H.assert_truthy(fork ~= nil, "run.fork was sent")
  H.assert_eq(fork.params.name, "branch-a", "fork carries the name (named at instantiation)")
  H.assert_truthy(attach ~= nil, "binds to the forked run")
  H.assert_eq(attach.params.runId, 42, "attach targets the forked runId")

  -- no-name fork → run.fork with no name (daemon auto-names <parent>-fork)
  sent = {}
  cmds.fork({ args = "" })
  local f2
  for _, e in ipairs(sent) do if e.method == "run.fork" then f2 = e end end
  H.assert_truthy(f2 ~= nil and f2.params.name == nil, "no-name fork omits name (auto <parent>-fork)")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
