-- statusline composes session/model/loop/turn/status/cost/yolo from state.
local NAME = "08_statusline"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()
local ok, err = pcall(function()
  local state = require("plurnk.state")
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].plurnk_session = "s1"
  state.set_model_alias("s1", "claude")
  state.set_current_loop_id("s1", 7)
  state.set_current_turn("s1", 2)
  state.set_cost_pico("s1", 12000000000) -- $0.012
  local text = require("plurnk.statusline").text()
  H.assert_match(text, "s1", "session")
  H.assert_match(text, "claude", "model")
  H.assert_match(text, "L7", "loop")
  H.assert_match(text, "T2", "turn")
  H.assert_match(text, "%$0%.0120", "cost")
  H.assert_match(text, "⏳", "in-flight glyph")
  state.set_final_status("s1", 200)
  H.assert_match(require("plurnk.statusline").text(), "✅", "done glyph")
  state.set_final_status("s1", 504)
  H.assert_match(require("plurnk.statusline").text(), "🔥", "error glyph")
end)
if ok then H.finish(NAME) else H.fail(NAME, err) end
