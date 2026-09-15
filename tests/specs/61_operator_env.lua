-- {§nvim-transport-target}: the bridge finds the daemon the way the terminal client does —
-- the editor's environment, then ./.env, then the operator's XDG file, then setup() — so a
-- bearer configured for the daemon reaches Neovim without a shell export. Pure; no daemon.
local NAME = "61_operator_env"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local NAMES = { "PLURNK_AGUI_URL", "PLURNK_HOST", "PLURNK_PORT", "PLURNK_AGUI_TOKEN", "XDG_CONFIG_HOME" }
local saved = {}
for _, name in ipairs(NAMES) do saved[name] = vim.env[name]; vim.env[name] = nil end
local cwd = vim.fn.getcwd()
local root = vim.fn.tempname()

local ok, err = pcall(function()
  local bridge = require("plurnk.bridge")
  local config = require("plurnk.config")
  vim.fn.mkdir(root .. "/config/plurnk", "p")
  vim.fn.mkdir(root .. "/project", "p")
  vim.env.XDG_CONFIG_HOME = root .. "/config"
  vim.cmd("cd " .. vim.fn.fnameescape(root .. "/project"))
  config.setup({})

  local target = bridge.target()
  H.assert_eq(target.url, "http://127.0.0.1:1066", "the daemon's default address")
  H.assert_eq(target.token, nil, "no bearer anywhere is no bearer")

  vim.fn.writefile({
    "# the operator's daemon configuration",
    "export PLURNK_AGUI_TOKEN=\"from-the-user-file\"",
    "PLURNK_PORT=4242   # where the daemon listens",
  }, root .. "/config/plurnk/.env")
  target = bridge.target()
  H.assert_eq(target.url, "http://127.0.0.1:4242", "the operator's file names the daemon's port")
  H.assert_eq(target.token, "from-the-user-file", "the bearer configured for the daemon reaches the editor")

  vim.fn.writefile({ "PLURNK_PORT='5151'" }, root .. "/project/.env")
  target = bridge.target()
  H.assert_eq(target.url, "http://127.0.0.1:5151", "the working directory's .env outranks the user file")
  H.assert_eq(target.token, "from-the-user-file", "each variable resolves on its own")

  config.setup({ port = 7171 })
  H.assert_eq(bridge.target().url, "http://127.0.0.1:5151", "an env file outranks setup()")
  vim.fn.delete(root .. "/project/.env")
  vim.fn.writefile({ "PLURNK_AGUI_TOKEN=only-a-token" }, root .. "/config/plurnk/.env")
  H.assert_eq(bridge.target().url, "http://127.0.0.1:7171", "setup() outranks the built-in default")

  vim.env.PLURNK_PORT = "6161"
  vim.env.PLURNK_AGUI_TOKEN = "from-the-shell"
  target = bridge.target()
  H.assert_eq(target.url, "http://127.0.0.1:6161", "the editor's own environment outranks every file")
  H.assert_eq(target.token, "from-the-shell", "the editor's own bearer outranks the file")

  vim.env.PLURNK_AGUI_URL = "http://plurnk.example:9/"
  H.assert_eq(bridge.target().url, "http://plurnk.example:9/", "an explicit AG-UI URL is the whole address")
end)

vim.cmd("cd " .. vim.fn.fnameescape(cwd))
for _, name in ipairs(NAMES) do vim.env[name] = saved[name] end
require("plurnk.config").setup({})
vim.fn.delete(root, "rf")
if ok then H.finish(NAME) else H.fail(NAME, err) end
