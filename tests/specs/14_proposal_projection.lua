-- AG-UI delivers only client-owned proposals to this handler. It de-duplicates
-- repeated delivery on the durable log id and never re-derives ownership from
-- loop policy.
local NAME = "14_proposal_projection"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local reviewed = {}
  require("plurnk.resolve").process = function(_, proposal)
    table.insert(reviewed, proposal.logEntryId)
  end
  local dispatch = require("plurnk.dispatch")
  local proposal = {
    logEntryId = 1,
    op = "EDIT",
    target = { scheme = nil, pathname = "/tmp/x" },
    body = "",
    attrs = {},
    policy = { capabilities = {}, proposals = "review" },
  }

  dispatch.handle_loop_proposal(proposal, "smoke")
  dispatch.handle_loop_proposal(proposal, "smoke")

  H.wait_for(function() return #reviewed == 1 end, 2000, "client proposal reaches review once")
  H.assert_eq(reviewed[1], 1, "review receives the projected proposal")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
