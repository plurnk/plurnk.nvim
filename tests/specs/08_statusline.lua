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
  state.set_cost_pico("s1", 70000000000) -- $0.07 — the LAST loop's cost, not a total
  local text = require("plurnk.statusline").text()
  H.assert_match(text, "s1", "session")
  H.assert_match(text, "claude", "model")
  H.assert_match(text, "L7", "loop")
  H.assert_match(text, "T2", "turn")
  H.assert_match(text, "loop: %$0%.07", "per-loop cost, labelled 'loop:'")
  H.assert_match(text, "⏳", "in-flight glyph")
  state.set_final_status("s1", 200)
  H.assert_match(require("plurnk.statusline").text(), "✅", "done glyph")
  state.set_final_status("s1", 504)
  H.assert_match(require("plurnk.statusline").text(), "❌", "error glyph")

  -- session total + remaining (account balance) — each shown ONLY when the
  -- daemon pushes it (svc#254 / svc#252); the client renders, never aggregates.
  H.assert_truthy(not require("plurnk.statusline").text():match("session:"), "no session total until the wire carries it")
  H.assert_truthy(not require("plurnk.statusline").text():match("remaining:"), "no remaining until the wire carries it")
  state.record_loop_usage("s1", { sessionCostPico = 12560000000000, balancePico = 198530000000000 })
  local m = require("plurnk.statusline").text()
  H.assert_match(m, "session: %$12%.56", "session total = daemon's authoritative cumulative cost")
  H.assert_match(m, "remaining: %$198%.53", "remaining = account balance")

  -- record_loop_usage is a SNAPSHOT, not a tally: a second loop's cost REPLACES.
  state.record_loop_usage("s1", { costPico = 50000000000 }) -- $0.05
  H.assert_match(require("plurnk.statusline").text(), "loop: %$0%.05", "last loop's cost replaces, not accumulates")

  -- Active-model resolution (converged with the TUI header): with no loop yet
  -- (no model_alias), the statusline/winbar still name the daemon's active
  -- default from the warmed providers.list cache.
  local buf2 = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf2)
  vim.b[buf2].plurnk_session = "s2"
  state.set_available_aliases({ { alias = "haiku", active = false }, { alias = "opus", active = true } })
  H.assert_eq(state.get_active_model("s2"), "opus", "active default resolved when no loop has set a model")
  H.assert_match(require("plurnk.statusline").text(), "🤖 opus", "statusline names the active default from cold")
  -- An explicit per-session model still wins over the daemon default.
  state.set_model_alias("s2", "sonnet")
  H.assert_eq(state.get_active_model("s2"), "sonnet", "session's last-used model wins over the active default")
end)
if ok then H.finish(NAME) else H.fail(NAME, err) end
