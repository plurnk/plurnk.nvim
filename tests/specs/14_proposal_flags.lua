-- [§nvim-server-resolved]
-- Server-resolved proposal suppression: loop/proposal carrying flags.yolo
-- (server-side YOLO auto-accept) or flags.noProposals (server-side
-- auto-reject) settles in-process on the daemon — dispatch must drop it
-- before review. Pure unit test (stubbed resolve.process); no daemon
-- round-trip.
local NAME = "14_proposal_flags"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local reviewed = {}
  require("plurnk.resolve").process = function(_, proposal)
    table.insert(reviewed, proposal.logEntryId)
  end
  local dispatch = require("plurnk.dispatch")
  local base = { op = "EDIT", target = { scheme = nil, pathname = "/tmp/x" }, body = "", attrs = {} }

  local proposal = function(id, flags)
    return vim.tbl_extend("force", base, { logEntryId = id, flags = flags })
  end

  dispatch.handle_loop_proposal(proposal(1, { yolo = true }), "smoke")
  dispatch.handle_loop_proposal(proposal(2, { noProposals = true }), "smoke")
  dispatch.handle_loop_proposal(proposal(3, { yolo = false, noProposals = false }), "smoke")
  dispatch.handle_loop_proposal(proposal(4, {}), "smoke")

  H.wait_for(function() return #reviewed == 2 end, 2000, "client-reviewed proposals reach resolve")
  H.assert_eq(reviewed[1], 3, "yolo=false reviewed")
  H.assert_eq(reviewed[2], 4, "empty flags reviewed")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
