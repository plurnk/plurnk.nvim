local M = {}

local log_dir = vim.fn.stdpath("log")
vim.fn.mkdir(log_dir, "p")

local defaults = {
  host = "127.0.0.1",
  port = 3044,
  log_path = log_dir .. "/plurnk_client.log",
  background_log_path = log_dir .. "/plurnk_background.log",
  -- #268 — per-session override of the SERVICE's AGENTS auto-load (the daemon
  -- picks + reads; this only forces it on/off). nil = use the daemon's env
  -- default (PLURNK_AGENTS_AUTO); true/false overrides for this client's sessions.
  auto_read_agents = nil,
}

local config = vim.deepcopy(defaults)

M.setup = function(opts)
  config = vim.tbl_extend("force", vim.deepcopy(defaults), opts or {})
end

M.get = function(key)
  return config[key]
end

return M
