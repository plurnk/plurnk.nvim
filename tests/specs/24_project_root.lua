-- [§nvim-project-root]
-- Project root defaults to the editor cwd, so session.create is NOT headless.
-- Regression: set_project_path was never called → project_path nil →
-- session.create sent no projectRoot → daemon stored null → file ops 400.
local NAME = "24_project_root"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local state = require("plurnk.state")

  -- With no explicit set_project_path, the root resolves to the editor cwd —
  -- never nil (nil is what made every session headless).
  H.assert_eq(state.get_project_path(), vim.fn.getcwd(), "unset project root defaults to cwd")
  H.assert_truthy(state.get_project_path() ~= nil, "project root is never nil")

  -- The create flow carries that root on the wire (not headless).
  local sent = {}
  require("plurnk.client").send = function(method, params, _, cb)
    sent[#sent + 1] = { method = method, params = params }
    if method == "session.create" and cb then cb({ id = 1, name = "s", runId = 2, runName = "r" }) end
  end
  require("plurnk.client").check_daemon_once = function() end
  require("plurnk.commands").session_new({ args = "" })
  local create
  for _, s in ipairs(sent) do if s.method == "session.create" then create = s end end
  H.assert_truthy(create ~= nil, "session.create was sent")
  H.assert_eq(create.params.projectRoot, vim.fn.getcwd(), "session.create carries cwd projectRoot (not headless)")

  -- An explicit root still wins over the cwd default.
  state.set_project_path("/tmp/explicit-root")
  H.assert_eq(state.get_project_path(), "/tmp/explicit-root", "explicit root wins over cwd")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
