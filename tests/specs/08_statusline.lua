-- The statusline is LEAN (🐹 + status emoji + ⚡yolo); the rich detail
-- (session/model/L·T/tokens/money trio) lives in the winbar — run_tab.winbar_text.
local NAME = "08_statusline"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()
local ok, err = pcall(function()
  local state = require("plurnk.state")
  local run_tab = require("plurnk.run_tab")
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].plurnk_session = "s1"
  state.set_model_alias("s1", "claude")
  state.set_current_loop_id("s1", 7)
  state.set_current_turn("s1", 2)
  state.set_cost_pico("s1", 70000000000) -- $0.07 — the LAST loop's cost, not a total
  state.set_loop_inflight("s1", true)

  -- ── lean statusline: a glance, not a squat on shared real estate ──
  local sl = require("plurnk.statusline").text()
  H.assert_match(sl, "🐹", "hamster brand")
  H.assert_match(sl, "⏳", "in-flight glyph")
  H.assert_truthy(not sl:match("s1"), "statusline does NOT show the session name (winbar's job)")
  H.assert_truthy(not sl:match("claude"), "statusline does NOT show the model (winbar's job)")
  H.assert_truthy(not sl:match("loop:"), "statusline does NOT show money (winbar's job)")

  -- ── rich winbar: identity + model + L·T + status + money ──
  local wb = run_tab.winbar_text("s1", 7)
  H.assert_match(wb, "🐹", "winbar brand")
  H.assert_match(wb, "s1", "session")
  H.assert_match(wb, "claude", "model")
  H.assert_match(wb, "L7", "loop")
  H.assert_match(wb, "T2", "turn")
  H.assert_match(wb, "⏳", "in-flight glyph in winbar")
  H.assert_match(wb, "loop: %$0%.07", "per-loop cost, labelled 'loop:'")

  state.set_loop_inflight("s1", false)
  state.set_final_status("s1", 200)
  H.assert_match(run_tab.winbar_text("s1", 7), "✅", "done glyph")
  state.set_final_status("s1", 504)
  H.assert_match(run_tab.winbar_text("s1", 7), "❌", "error glyph")

  -- session total + remaining (account balance) — each shown ONLY when the
  -- daemon pushes it (svc#254 / svc#252); the client renders, never aggregates.
  H.assert_truthy(not run_tab.winbar_text("s1", 7):match("session:"), "no session total until the wire carries it")
  H.assert_truthy(not run_tab.winbar_text("s1", 7):match("remaining:"), "no remaining until the wire carries it")
  state.record_loop_usage("s1", { sessionCostPico = 12560000000000, balancePico = 198530000000000 })
  local m = run_tab.winbar_text("s1", 7)
  H.assert_match(m, "session: %$12%.56", "session total = daemon's authoritative cumulative cost")
  H.assert_match(m, "remaining: %$198%.53", "remaining = account balance")

  -- record_loop_usage is a SNAPSHOT, not a tally: a second loop's cost REPLACES.
  state.record_loop_usage("s1", { costPico = 50000000000 }) -- $0.05
  H.assert_match(run_tab.winbar_text("s1", 7), "loop: %$0%.05", "last loop's cost replaces, not accumulates")

  -- Active-model resolution (converged with the TUI header): with no loop yet
  -- (no model_alias), the winbar still names the daemon's active default from
  -- the warmed providers.list cache.
  state.set_available_aliases({ { alias = "haiku", active = false }, { alias = "opus", active = true } })
  H.assert_eq(state.get_active_model("s2"), "opus", "active default resolved when no loop has set a model")
  H.assert_match(run_tab.winbar_text("s2", nil), "🤖 opus", "winbar names the active default from cold")
  -- An explicit per-session model still wins over the daemon default.
  state.set_model_alias("s2", "sonnet")
  H.assert_eq(state.get_active_model("s2"), "sonnet", "session's last-used model wins over the active default")
end)
if ok then H.finish(NAME) else H.fail(NAME, err) end
