-- [§nvim-visual-selection][§nvim-scope-repetition]
-- :1,2 AI?? recap — double-prefix form (rummy ?? = new session) wraps the
-- visual selection into the loop.run prompt. Regression coverage for the
-- :AI?? path that bypassed wrap_with_selection in v0.3.0.
local NAME = "12_visual_selection_new_session"
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
  require("plurnk.bridge").run = function(_t, prompt, _o, on_done)
    captured = prompt
    if on_done then on_done(200) end
    return nil
  end
  local original = require("plurnk.client").send
  require("plurnk.client").send = function(method, params, n, cb)
    if method == "loop.run" then captured = params.prompt end
    return original(method, params, n, cb)
  end

  vim.cmd("1,2 AI?? recap")
  vim.wait(15000, function() return captured ~= nil end, 50)

  H.assert_truthy(captured, "loop.run dispatched")
  H.assert_match(captured, "<selection", "selection wrapper present")
  H.assert_match(captured, 'file="sample.txt"', "file attribute set")
  H.assert_match(captured, "first", "line 1 in selection")
  H.assert_match(captured, "second", "line 2 in selection")
  H.assert_match(captured, "recap", "user prompt appended")

  -- This spec only needed the wire capture — cancel the loop so its
  -- drain doesn't hold the shared model server hostage while later
  -- specs (13's live loop) wait on it.
  local cancelled
  original("loop.cancel", { reason = "spec_done" }, false, function() cancelled = true end)
  vim.wait(5000, function() return cancelled end, 50)
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
