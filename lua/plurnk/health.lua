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
  -- plenary was dropped in v0.1.2 (vim.system is built-in ≥ 0.10) — no dependency.
  -- AG-UI+ is the sole transport. Neovim streams its HTTP/SSE response through curl.
  if vim.fn.executable("curl") == 1 then ok("curl present (AG-UI+ transport)") else error("curl is required for the AG-UI+ transport") end
  local cfg = require("plurnk.config")
  ok(string.format("Configured: %s:%d", cfg.get("host"), cfg.get("port")))
  require("plurnk.client").send("ping", {}, false, function(_)
    ok("Daemon responded to ping")
  end)
  warn("Ping is async — re-run :checkhealth if you don't see 'Daemon responded' below within ~1s")
end

return M
