-- End-to-end :AI flow against the live daemon. This is the spec that
-- would have caught the missing session-routing in v0.3.0: drives the
-- exact command the user types, waits for loop/terminated, then asserts
-- the run_tab buffer contains the model's broadcast response.
local NAME = "10_ai_end_to_end"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()
require("plurnk").apply_default_keymaps()

local ok, err = pcall(function()
  local dispatch = require("plurnk.dispatch")
  local terminated = nil
  local orig = dispatch.handle_loop_terminated
  dispatch.handle_loop_terminated = function(p, sn) terminated = p; orig(p, sn) end

  -- Ask mode: grammar-constrained sampling (svc#189) makes bare prompts
  -- provoke EXEC attempts → proposal pauses this spec never resolves.
  -- Ask 403s exec at dispatch — deterministic AND dogfoods the habit.
  vim.cmd("AI ? Hello, world.")
  -- 9 minutes: dramatically generous so a failure is unambiguously a real hang,
  -- never "the model was slow" (under the runner's 600s SIGKILL).
  H.wait_for(function() return terminated ~= nil end, 540000, "loop/terminated")
  vim.wait(300, function() return false end, 50) -- flush appended-history schedules

  H.assert_eq(terminated.finalStatus, 200, "loop terminated 200")

  local session_buf
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match("^plurnk://session%-") then session_buf = b end
  end
  H.assert_truthy(session_buf, "run_tab session buffer exists")
  local content = table.concat(vim.api.nvim_buf_get_lines(session_buf, 0, -1, false), "\n")
  H.assert_match(content, "💡", "waterfall has the answer glyph")
  H.assert_match(content, "💡    200", "waterfall has terminal SEND status")
  -- The leading line is the SEND[200] header itself, not a blank.
  H.assert_truthy(content:sub(1, 1) ~= "\n", "no leading blank line")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
