-- [§nvim-connection-onboarding]
-- Cold no-daemon: a verb against a dead port surfaces the onboarding notify
-- (quick-start + install lines) — never a silent nil. Deterministic: no
-- daemon is booted; the port is dead by construction.
local NAME = "40_no_daemon"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
vim.opt.rtp:append(os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim")
require("plurnk").setup({ host = "127.0.0.1", port = 1 })  -- nothing listens on 1
vim.env.PLURNK_PORT = "1"
vim.env.PLURNK_AGUI_URL = nil

local ok, err = pcall(function()
  local notified = nil
  local orig = vim.notify
  vim.notify = function(msg, ...) notified = msg; return orig(msg, ...) end
  local got = "pending"
  require("plurnk.client").send("ping", {}, false, function(r) got = r end)
  H.wait_for(function() return notified ~= nil end, 10000, "onboarding notify")
  vim.notify = orig
  H.assert_match(notified, "no daemon is running", "names the condition")
  H.assert_match(notified, "npx @plurnk/plurnk%-service start", "quick-start line")
  H.assert_truthy(got == nil or got == "pending", "no fabricated result")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
