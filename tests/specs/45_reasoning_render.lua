-- {§nvim-readable-reasoning}: the standard reasoning notification reaches the
-- active worker buffer without masquerading as a log entry or PLAN.
local NAME = "45_reasoning_render"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local seen = {}
  local worker_tab = require("plurnk.worker_tab")
  worker_tab.begin_reasoning = function(workspace, worker_id, message_id)
    seen[#seen + 1] = { phase = "start", workspace = workspace, workerId = worker_id, messageId = message_id }
  end
  worker_tab.append_reasoning_delta = function(workspace, worker_id, message_id, delta)
    seen[#seen + 1] = { phase = "content", workspace = workspace, workerId = worker_id, messageId = message_id, delta = delta }
  end
  worker_tab.end_reasoning = function(workspace, worker_id, message_id)
    seen[#seen + 1] = { phase = "end", workspace = workspace, workerId = worker_id, messageId = message_id }
  end
  require("plurnk.state").set_active_workspace_name("reasoning")
  require("plurnk.dispatch").handle_notification({
    method = "reasoning/event",
    params = { phase = "start", workerId = 17, messageId = "1/1/2/SEND/reasoning" },
  })
  require("plurnk.dispatch").handle_notification({
    method = "reasoning/event",
    params = { phase = "content", workerId = 17, messageId = "1/1/2/SEND/reasoning", delta = "inspect the evidence" },
  })
  require("plurnk.dispatch").handle_notification({
    method = "reasoning/event",
    params = { phase = "end", workerId = 17, messageId = "1/1/2/SEND/reasoning" },
  })
  H.wait_for(function() return #seen == 3 end, 1000, "reasoning dispatch")
  H.assert_eq(seen[1].workspace, "reasoning", "reasoning routes to the active conversation")
  H.assert_eq(seen[1].workerId, 17, "reasoning retains the worker selected for its run")
  H.assert_eq(seen[1].messageId, "1/1/2/SEND/reasoning", "reasoning identity survives dispatch")
  H.assert_eq(seen[2].delta, "inspect the evidence", "reasoning delta survives dispatch before completion")
  H.assert_eq(seen[3].phase, "end", "reasoning completion survives dispatch")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
