-- [§nvim-worker-fork]
-- worker.fork (svc#248): :PlurnkFork / :AI???? branch the conversation into a new
-- run, optionally named at instantiation (immutable after), then bind to it.
local NAME = "26_worker_fork"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local sent = {}
  require("plurnk.client").send = function(method, params, _, cb)
    sent[#sent + 1] = { method = method, params = params }
    if method == "worker.fork" and cb then cb({ workerId = 42, workerName = params.name or "main-fork" }) end
    if method == "workspace.attach" and cb then cb({ workerId = 42, workerName = "main-fork" }) end
  end
  require("plurnk.client").check_daemon_once = function() end
  require("plurnk.client").consume_selected_alias = function() return nil end
  require("plurnk.client").get_workspace_model = function() return nil end
  local rt = require("plurnk.worker_tab")
  rt.open = function() end
  rt.note_run_resolved = function() end
  rt.current_alias = function() return nil end

  local state = require("plurnk.state")
  state.set_active_workspace_name("s")
  state.set_workspace_id("s", 9)
  state.set_worker_id("s", 5)  -- a model worker exists to fork

  local cmds = require("plurnk.commands")

  -- named fork → worker.fork {name}, then attach binds the new run
  cmds.fork({ args = "branch-a" })
  local fork, attach
  for _, e in ipairs(sent) do
    if e.method == "worker.fork" then fork = e end
    if e.method == "workspace.attach" then attach = e end
  end
  H.assert_truthy(fork ~= nil, "worker.fork was sent")
  H.assert_eq(fork.params.name, "branch-a", "fork carries the name (named at instantiation)")
  H.assert_truthy(attach ~= nil, "binds to the forked run")
  H.assert_eq(attach.params.workerId, 42, "attach targets the forked workerId")

  -- no-name fork → worker.fork with no name (daemon auto-names <parent>-fork)
  sent = {}
  cmds.fork({ args = "" })
  local f2
  for _, e in ipairs(sent) do if e.method == "worker.fork" then f2 = e end end
  H.assert_truthy(f2 ~= nil and f2.params.name == nil, "no-name fork omits name (auto <parent>-fork)")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
