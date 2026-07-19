-- [§nvim-proposal-review]
-- resolve.lua diffsplit + accept-with-edits regenerates a valid udiff.
-- Pure unit test (stubbed client.send); no daemon round-trip.
local NAME = "07_resolve"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local tmp = vim.fn.tempname()
  vim.fn.writefile({ "hello", "world" }, tmp)
  local original_udiff = "--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n hello\n-world\n+universe\n"

  local captured = {}
  require("plurnk.client").send = function(method, params)
    table.insert(captured, { method = method, params = params })
  end

  -- accept-as-proposed
  require("plurnk.resolve").process("smoke", {
    logEntryId = 1, op = "EDIT",
    target = { scheme = nil, pathname = tmp },
    body = original_udiff,
  })
  local right
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match("^plurnk%-nvim://proposed/") then right = b end
  end
  H.assert_truthy(right, "proposed buffer")
  -- Hit \a
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(right, "n")) do
    if m.lhs == "\\a" and m.callback then m.callback() end
  end
  H.assert_eq(#captured, 1, "1 resolve sent")
  H.assert_eq(captured[1].params.decision, "accept", "accept decision")
  H.assert_eq(captured[1].params.body, nil, "no body on accept-as-proposed")

  -- accept-with-edits regenerates udiff
  captured = {}
  require("plurnk.resolve").process("smoke", {
    logEntryId = 2, op = "EDIT",
    target = { scheme = nil, pathname = tmp },
    body = original_udiff,
  })
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match("^plurnk%-nvim://proposed/") then right = b end
  end
  vim.api.nvim_buf_set_lines(right, 0, -1, false, { "hello", "PLANET" })
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(right, "n")) do
    if m.lhs == "\\e" and m.callback then m.callback() end
  end
  H.assert_eq(captured[1].params.decision, "accept", "edits decision")
  H.assert_match(captured[1].params.body, "%-world", "regen udiff has -world")
  H.assert_match(captured[1].params.body, "%+PLANET", "regen udiff has +PLANET")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
