-- Proposal review (loop/proposal → loop.resolve).
-- v0.1 stub: render the diff body in a scratch buffer, three keys to
-- accept/reject/cancel. Rich :diffsplit integration is next-pass.

local M = {}
local client = require("plurnk.client")
local diff = require("plurnk.diff")

M.process = function(session_name, proposal)
  if not proposal or not proposal.logEntryId then return end
  if diff.is_yolo() then
    client.send("loop.resolve", {
      logEntryId = proposal.logEntryId,
      decision = "accept",
      outcome = "client_yolo",
    })
    return
  end

  -- Show a scratch buffer with the udiff body; prompt for keypress.
  local buf = vim.api.nvim_create_buf(false, true)
  local body_lines = {}
  if type(proposal.body) == "string" then
    for line in (proposal.body .. "\n"):gmatch("([^\n]*)\n") do body_lines[#body_lines+1] = line end
  end
  table.insert(body_lines, 1, string.format("── proposal %s %s://%s ──",
    tostring(proposal.op or "?"),
    tostring(proposal.target and proposal.target.scheme or ""),
    tostring(proposal.target and proposal.target.pathname or "")))
  table.insert(body_lines, "")
  table.insert(body_lines, "[a]ccept · [r]eject · [c]ancel")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, body_lines)
  vim.bo[buf].filetype = "diff"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)

  local function resolve(decision, outcome)
    client.send("loop.resolve", {
      logEntryId = proposal.logEntryId,
      decision = decision,
      outcome = outcome,
    })
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    if session_name then require("plurnk.state").remove_proposal(session_name, proposal.logEntryId) end
  end

  vim.keymap.set("n", "a", function() resolve("accept") end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "r", function() resolve("reject") end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "c", function() resolve("cancel") end, { buffer = buf, nowait = true })
end

return M
