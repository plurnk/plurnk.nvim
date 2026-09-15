-- {§nvim-active-worker}: a selected conversation must be the actual action owner.
local NAME = "64_conversation_binding"
local H = dofile(assert(os.getenv("PLURNK_NVIM_ROOT")) .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local state = require("plurnk.state")
  local context = require("plurnk.workspace_context")
  local world = H.call("workspace.create", { name = NAME, projectRoot = vim.fn.getcwd() })
  H.assert_type(world, "table", "create workspace")
  state.set_workspace_id(world.name, world.id)
  state.set_active_workspace_name(world.name)
  local first = H.call("run.fork", { name = "alice" })
  context.note_model_worker(world.name, first.workerId, first.workerName)
  local second = H.call("run.fork", { name = "bob" })
  H.assert_eq(second.parentWorkerId, first.workerId, "fork acts on selected Alice, not the world's default")
  context.note_model_worker(world.name, second.workerId, second.workerName)
  local third = H.call("run.fork", { name = "carol" })
  H.assert_eq(third.parentWorkerId, second.workerId, "Bob remains an independently addressable conversation")
  require("plurnk.worker_tab").open(world.name, first.workerId)
  local fourth = H.call("run.fork", { name = "dave" })
  H.assert_eq(fourth.parentWorkerId, first.workerId, "native tab selection changes the wire destination")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
