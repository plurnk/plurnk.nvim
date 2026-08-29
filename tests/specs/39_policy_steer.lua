-- A per-loop policy profile must conclude through the general capability and
-- recovery machinery. The original specimen deterministically cycled after a
-- denied EXEC; it now owns only the absence of that state-machine regression,
-- not a particular stochastic answer.
local NAME = "39_policy_steer"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()
require("plurnk").apply_default_keymaps()

local ok, err = pcall(function()
  local dispatch = require("plurnk.dispatch")
  local terminated = nil
  local orig = dispatch.handle_loop_terminated
  dispatch.handle_loop_terminated = function(p, sn) terminated = p; orig(p, sn) end

  vim.cmd("AI ? Hello, world.")
  H.wait_for(function() return terminated ~= nil end, 540000, "loop/terminated")
  H.assert_truthy(terminated.result.status ~= 508,
    "a denied capability does not create a cycle-strike spiral: status "
      .. tostring(terminated.result.status) .. " ~= 508")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
