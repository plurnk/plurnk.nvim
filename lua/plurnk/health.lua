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
  -- curl is only needed for the plurnk-agui bridge (PLURNK_AGUI_URL); the WS path
  -- uses vim.system + libuv directly, so a missing curl is a warning, not an error.
  if vim.fn.executable("curl") == 1 then ok("curl present (for PLURNK_AGUI_URL bridge mode)") else warn("curl not found — needed only for PLURNK_AGUI_URL bridge mode") end
  local cfg = require("plurnk.config")
  ok(string.format("Configured: %s:%d", cfg.get("host"), cfg.get("port")))
  local transport = require("plurnk.transport")
  transport.send("ping", {}, false, function(_)
    ok("Daemon responded to ping")
  end)
  warn("Ping is async — re-run :checkhealth if you don't see 'Daemon responded' below within ~1s")
end

return M
