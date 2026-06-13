-- Phase 3 cockpit: statusline token accumulation (session-total, from
-- log/entry rows) and the HUD headless fallback. Pure module path.
local NAME = "21_cockpit"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local state = require("plurnk.state")
  local dispatch = require("plurnk.dispatch")
  state.set_session_id("gauge", 3)
  state.set_active_session_name("gauge")
  vim.b.plurnk_session = "gauge"

  -- Real usage (loop/terminated, svc#197) — the ONLY token source;
  -- accumulates ↑/↓ and cost per session. No content-token fallback.
  dispatch.handle_loop_terminated({ loopId = 1, finalStatus = 200, hitMaxTurns = false,
    usage = { promptTokens = 2000, completionTokens = 500, costPico = 7e9 } }, "gauge")
  dispatch.handle_loop_terminated({ loopId = 2, finalStatus = 200, hitMaxTurns = false,
    usage = { promptTokens = 1000, completionTokens = 250, costPico = 3e9 } }, "gauge")
  local line = require("plurnk.statusline").text()
  H.assert_match(line, "plurnk%[gauge", "statusline names the session")
  H.assert_match(line, "↑3%.0k ↓750", "statusline shows accumulated real usage")
  H.assert_eq(state.get_cost_pico("gauge"), 1e10, "cost accumulates from usage")

  -- A session with no loop yet shows NO gauge (no fake zeros).
  vim.cmd("enew")
  vim.b.plurnk_session = "empty"
  state.set_session_id("empty", 4)
  H.assert_truthy(not require("plurnk.statusline").text():match("↑"),
    "no token segment before any loop runs")

  -- HUD: headless (no UI) falls back to vim.notify — message still lands.
  local notes = {}
  local orig = vim.notify
  vim.notify = function(msg) table.insert(notes, msg) end
  require("plurnk.hud").show("✓ exec://demo → 200")
  vim.notify = orig
  H.assert_eq(notes[1], "✓ exec://demo → 200", "headless HUD falls back to notify")
  H.assert_truthy(not require("plurnk.hud").is_open(), "no float without a UI")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
