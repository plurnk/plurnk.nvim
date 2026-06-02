-- :2,3 AI: explain — single-prefix range form wraps the visual selection
-- into the loop.run prompt, against the live daemon.
local NAME = "11_visual_selection"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()
require("plurnk").apply_default_keymaps()

local ok, err = pcall(function()
  local proj = vim.fn.tempname() .. "_proj"
  vim.fn.mkdir(proj, "p")
  require("plurnk.state").set_project_path(proj)
  local file = proj .. "/sample.txt"
  vim.fn.writefile({ "first", "second", "third" }, file)
  vim.cmd("edit " .. file)

  local captured
  local original = require("plurnk.client").send
  require("plurnk.client").send = function(method, params, n, cb)
    if method == "loop.run" then captured = params.prompt end
    return original(method, params, n, cb)
  end

  vim.cmd("2,3 AI: explain")
  vim.wait(15000, function() return captured ~= nil end, 50)

  H.assert_truthy(captured, "loop.run dispatched")
  H.assert_match(captured, "<selection", "selection wrapper present")
  H.assert_match(captured, 'file="sample.txt"', "file attribute set")
  H.assert_match(captured, "second", "line 2 in selection")
  H.assert_match(captured, "third", "line 3 in selection")
  H.assert_match(captured, "explain", "user prompt appended")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
