-- :checkhealth plurnk
local M = {}
local health = vim.health or require("health")
local start = health.start or health.report_start
local ok = health.ok or health.report_ok
local warn = health.warn or health.report_warn
local error = health.error or health.report_error

M.check = function()
  start("plurnk.nvim")
  if vim.fn.has("nvim-0.10") == 1 then ok("Neovim >= 0.10") else error("Need Neovim >= 0.10") end
  local has_plenary = pcall(require, "plenary")
  if has_plenary then ok("plenary.nvim present") else error("plenary.nvim missing — required dependency") end
  local cfg = require("plurnk.config")
  ok(string.format("Configured: %s:%d", cfg.get("host"), cfg.get("port")))
  local transport = require("plurnk.transport")
  transport.send("ping", {}, false, function(_)
    ok("Daemon responded to ping")
  end)
  warn("Ping is async — re-run :checkhealth if you don't see 'Daemon responded' below within ~1s")
end

return M
