-- [§nvim-cockpit-gauge]
-- Phase 3 cockpit: the winbar gauge (LAST-loop snapshot, never a client
-- tally), the lean statusline glance, and the HUD headless fallback.
local NAME = "21_cockpit"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local state = require("plurnk.state")
  local dispatch = require("plurnk.dispatch")
  state.set_session_id("gauge", 3)
  state.set_active_session_name("gauge")
  vim.b.plurnk_session = "gauge"

  -- Real usage (loop/terminated, svc#197) — the LAST loop's usage, a SNAPSHOT,
  -- NOT a session tally. The lifetime total is the daemon's (svc#254); a client
  -- can't sum it (forks + multiple clients), and faking it lies about money.
  dispatch.handle_loop_terminated({ loopId = 1, finalStatus = 200, hitMaxTurns = false,
    usage = { promptTokens = 2000, completionTokens = 500, costPico = 7e9 } }, "gauge")
  dispatch.handle_loop_terminated({ loopId = 2, finalStatus = 200, hitMaxTurns = false,
    usage = { promptTokens = 1000, completionTokens = 250, costPico = 3e9 } }, "gauge")
  -- The rich gauge lives in the winbar now; the statusline is a lean glance.
  local wb = require("plurnk.run_tab").winbar_text("gauge", nil)
  H.assert_match(wb, "🐹 gauge", "winbar names the session")
  H.assert_match(wb, "↑1%.0k ↓250", "shows the LAST loop's usage (snapshot), not the sum of both")
  H.assert_eq(state.get_cost_pico("gauge"), 3e9, "cost is the last loop's, NOT accumulated (no client session total)")
  local sl = require("plurnk.statusline").text()
  H.assert_match(sl, "🐹", "statusline shows the brand")
  H.assert_truthy(not sl:match("↑"), "statusline does NOT squat tokens (winbar's job)")

  -- A session with no loop yet shows NO gauge (no fake zeros).
  vim.cmd("enew")
  vim.b.plurnk_session = "empty"
  state.set_session_id("empty", 4)
  H.assert_truthy(not require("plurnk.run_tab").winbar_text("empty", nil):match("↑"),
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
