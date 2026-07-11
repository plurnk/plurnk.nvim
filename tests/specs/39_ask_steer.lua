-- [§nvim-prompt-prefixes]
-- THE SPIRAL REGRESSION (svc#367): an ask-mode prompt the model reads as "do
-- something" used to provoke EXEC → 403 → identical retry → StrikeRail 508,
-- EVERY run. Core's fix (svc be8a77c): the 403 steer NAMES the restriction and
-- says don't retry. This drives the ORIGINAL failing prompt live and pins
-- exactly that regression: the loop must never CYCLE-strike (508). Verified
-- distribution post-fix (2026-07-11, 5 runs): 508×0, 500×3, 200×1, timeout×1 —
-- the cycle is dead; the residual 500s (model still taught/permitted EXEC it
-- can't use — plurnk-grammar#64) are svc#367's open half, tracked there, and
-- deliberately NOT gated here: this suite pins the client-visible regression,
-- not the service's open model-quality work.
local NAME = "39_ask_steer"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()
require("plurnk").apply_default_keymaps()

local ok, err = pcall(function()
  local dispatch = require("plurnk.dispatch")
  local terminated = nil
  local orig = dispatch.handle_loop_terminated
  dispatch.handle_loop_terminated = function(p, sn) terminated = p; orig(p, sn) end

  -- The original spiral prompt, verbatim (pre-fix: 508 every run).
  vim.cmd("AI ? Hello, world.")
  H.wait_for(function() return terminated ~= nil end, 540000, "loop/terminated")

  H.assert_truthy(terminated.finalStatus ~= 508, "no cycle-strike spiral: finalStatus " .. tostring(terminated.finalStatus) .. " ~= 508")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
