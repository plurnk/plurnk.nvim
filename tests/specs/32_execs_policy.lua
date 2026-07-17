-- [§nvim-execs-policy]
-- #132: per-workspace exec-policy — forward PLURNK_EXECS_* verbatim so the daemon
-- intersects it with its ceiling (subtractive). MCP SERVER configs
-- (PLURNK_EXECS_MCP_*: URLs, bearer tokens) must NEVER ride the wire; the bare
-- PLURNK_EXECS_MCP tag toggle stays.
local NAME = "32_execs_policy"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local commands = require("plurnk.commands")
  H.assert_eq(commands.collect_execs_policy(), nil, "nothing set → nil")

  vim.env.PLURNK_EXECS_ONLY = "python,node"
  vim.env.PLURNK_EXECS_SHELL = "0"
  vim.env.PLURNK_EXECS_MCP = "1"                       -- bare tag toggle → forwarded
  vim.env.PLURNK_EXECS_MCP_GITHUB_HEADERS = "Bearer s" -- server secret → NEVER forwarded
  vim.env.PLURNK_EXECS_MCP_GITHUB_URL = "https://x"    -- server config → NEVER forwarded

  local got = commands.collect_execs_policy()
  H.assert_eq(got.PLURNK_EXECS_ONLY, "python,node", "allowlist forwarded")
  H.assert_eq(got.PLURNK_EXECS_SHELL, "0", "tag kill forwarded")
  H.assert_eq(got.PLURNK_EXECS_MCP, "1", "bare MCP tag toggle forwarded")
  H.assert_eq(got.PLURNK_EXECS_MCP_GITHUB_HEADERS, nil, "MCP server secret NOT on the wire")
  H.assert_eq(got.PLURNK_EXECS_MCP_GITHUB_URL, nil, "MCP server URL NOT on the wire")

  vim.env.PLURNK_EXECS_ONLY = nil
  vim.env.PLURNK_EXECS_SHELL = nil
  vim.env.PLURNK_EXECS_MCP = nil
  vim.env.PLURNK_EXECS_MCP_GITHUB_HEADERS = nil
  vim.env.PLURNK_EXECS_MCP_GITHUB_URL = nil
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
