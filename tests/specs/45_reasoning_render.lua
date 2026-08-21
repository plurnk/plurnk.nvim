-- {§nvim-readable-reasoning}: the standard reasoning notification reaches the
-- active worker buffer without masquerading as a log entry or PLAN.
local NAME = "45_reasoning_render"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local seen = {}
  local worker_tab = require("plurnk.worker_tab")
  worker_tab.append_reasoning = function(workspace, worker_id, message_id, content)
    seen[#seen + 1] = { workspace = workspace, workerId = worker_id, messageId = message_id, content = content }
  end
  require("plurnk.state").set_active_workspace_name("reasoning")
  require("plurnk.dispatch").handle_notification({
    method = "reasoning/message",
    params = { workerId = 17, messageId = "1/1/2/SEND/reasoning", content = "inspect the evidence" },
  })
  H.wait_for(function() return #seen == 1 end, 1000, "reasoning dispatch")
  H.assert_eq(seen[1].workspace, "reasoning", "reasoning routes to the active conversation")
  H.assert_eq(seen[1].workerId, 17, "reasoning retains the worker selected for its run")
  H.assert_eq(seen[1].messageId, "1/1/2/SEND/reasoning", "reasoning identity survives dispatch")
  H.assert_eq(seen[1].content, "inspect the evidence", "reasoning content survives dispatch")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
