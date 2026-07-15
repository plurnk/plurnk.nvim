-- [§nvim-prompt-prefixes]
-- ASK-MODE SPIRAL, DEAD (svc#367/#386): an ask-mode prompt the model reads as "do
-- something" used to provoke EXEC → 403 → identical retry → StrikeRail 508 on EVERY
-- run. The fixed stack (mode-filtered capability sheet + 'EXEC operations disabled'
-- packet line + don't-retry steer) kills the CYCLE: this drives the ORIGINAL specimen
-- prompt live and pins that the loop always CONCLUDES and never cycle-strikes (508).
--
-- Deliberately NOT gated on finalStatus==200: measured 2/3 → 200, 1/3 → 500 across
-- client-side runs (vs the service's 5/5 — model-dependent variance). The residual
-- 500 is the model still occasionally failing this awkward prompt — model-quality
-- nondeterminism, not a client contract. Gating a hard 200 would flake CI; the
-- regression this spec owns is the 508 cycle + the indefinite hang, and BOTH are gone.
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
  -- The loop always CONCLUDES (the indefinite-hang failure mode is gone) — a timeout
  -- here is itself a regression, caught by wait_for.
  H.wait_for(function() return terminated ~= nil end, 540000, "loop/terminated")

  -- The regression this spec owns: never the StrikeRail CYCLE (508), which was 100%
  -- pre-fix and is 0 across every post-fix run.
  H.assert_truthy(terminated.finalStatus ~= 508, "no cycle-strike spiral: finalStatus " .. tostring(terminated.finalStatus) .. " ~= 508")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
