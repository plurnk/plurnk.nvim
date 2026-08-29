local M = {}

local log_dir = vim.fn.stdpath("log")
vim.fn.mkdir(log_dir, "p")

local defaults = {
  host = "127.0.0.1",
  port = 1066,
  log_path = log_dir .. "/plurnk_client.log",
  background_log_path = log_dir .. "/plurnk_background.log",
  loop_policy = { capabilities = {}, proposals = "review" },
  workspace_capabilities = nil,
}

local config = vim.deepcopy(defaults)

M.setup = function(opts)
  config = vim.tbl_extend("force", vim.deepcopy(defaults), opts or {})
end

M.get = function(key)
  return config[key]
end

return M
