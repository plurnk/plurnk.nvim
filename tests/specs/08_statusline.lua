-- -- The statusline is LEAN (🐹 + status emoji + 🔥yolo); the rich detail
-- (workspace/model/L·T/tokens/loop cost) lives in the winbar — worker_tab.winbar_text.
local NAME = "08_statusline"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()
local ok, err = pcall(function()
  local state = require("plurnk.state")
  local worker_tab = require("plurnk.worker_tab")
  local function loop_usage(input_tokens, output_tokens, cost_usd, context_tokens, prompt_budget)
    local aggregate = {
      inputTokens = input_tokens,
      outputTokens = output_tokens,
      totalTokens = input_tokens + output_tokens,
    }
    local cost = cost_usd and {
      kind = "estimated",
      amount = { amount = cost_usd, currency = "USD" },
      source = "fixture",
    } or { kind = "unknown", reason = "provider supplied no monetary evidence" }
    return {
      accounting = {
        requests = { {
          provider = "provider:test",
          model = "test",
          outcome = "response",
          usage = aggregate,
          cost = cost,
        } },
        usage = aggregate,
        costUsd = cost_usd,
      },
      contextTokens = context_tokens,
      promptBudget = prompt_budget,
      meta = {},
    }
  end
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].plurnk_workspace = "s1"
  state.set_model_alias("s1", "claude")
  state.set_current_loop_id("s1", 7)
  state.set_current_turn("s1", 2)
  state.record_loop_usage("s1", loop_usage(0, 0, "0.0700"))
  state.set_loop_inflight("s1", true)

  -- ── lean statusline: a glance, not a squat on shared real estate ──
  local sl = require("plurnk.statusline").text()
  H.assert_match(sl, "🐹", "hamster brand")
  H.assert_match(sl, "⏳", "in-flight glyph")
  H.assert_truthy(not sl:match("s1"), "statusline does NOT show the workspace name (winbar's job)")
  H.assert_truthy(not sl:match("claude"), "statusline does NOT show the model (winbar's job)")
  H.assert_truthy(not sl:match("loop:"), "statusline does NOT show money (winbar's job)")

  -- ── rich winbar: identity + model + L·T + status + money ──
  local wb = worker_tab.winbar_text("s1", 7)
  H.assert_match(wb, "🐹", "winbar brand")
  H.assert_match(wb, "s1", "workspace")
  H.assert_match(wb, "claude", "model")
  H.assert_match(wb, "L7", "loop")
  H.assert_match(wb, "T2", "turn")
  H.assert_match(wb, "⏳", "in-flight glyph in winbar")
  H.assert_match(wb, "loop: %$0%.0700", "per-loop cost, labelled 'loop:'")

  state.set_loop_inflight("s1", false)
  state.set_final_status("s1", 200)
  H.assert_match(worker_tab.winbar_text("s1", 7), "✅", "done glyph")
  state.set_final_status("s1", 504)
  H.assert_match(worker_tab.winbar_text("s1", 7), "❌", "error glyph")

  -- record_loop_usage is a SNAPSHOT, not a tally: a second loop's cost REPLACES.
  state.record_loop_usage("s1", loop_usage(0, 0, "0.05"))
  H.assert_match(worker_tab.winbar_text("s1", 7), "loop: %$0%.05", "the next exact loop envelope replaces the prior one")

  -- Unknown monetary evidence stays unknown and cannot inherit a prior loop's cost.
  state.record_loop_usage("s1", loop_usage(0, 0, nil))
  local unknown = worker_tab.winbar_text("s1", 7)
  H.assert_match(unknown, "loop: %$unknown", "unknown money remains unknown")
  H.assert_truthy(not unknown:match("%$0%.05"), "an unknown loop never inherits prior evidence")

  -- Context occupancy and budget both come from the same terminal envelope.
  state.set_available_aliases({ { alias = "opus", active = true, contextSize = 128000 } })
  state.record_loop_usage("s1", loop_usage(0, 0, "0", 7360, 49152))
  H.assert_match(worker_tab.winbar_text("s1", 7), "ctx 15%%/49k", "the loop's budget wins over ambient alias metadata")
  state.record_loop_usage("s1", loop_usage(0, 0, "0", 7360, nil))
  H.assert_truthy(not worker_tab.winbar_text("s1", 7):match("ctx "), "no gauge when the terminal budget is unknown")

  -- Active-model resolution (converged with the TUI header): with no loop yet
  -- (no model_alias), the winbar still names the daemon's active default from
  -- the warmed providers.list cache.
  state.set_available_aliases({ { alias = "haiku", active = false }, { alias = "opus", active = true } })
  H.assert_eq(state.get_active_model("s2"), "opus", "active default resolved when no loop has set a model")
  H.assert_match(worker_tab.winbar_text("s2", nil), "🤖 opus", "winbar names the active default from cold")
  -- An explicit per-workspace model still wins over the daemon default.
  state.set_model_alias("s2", "sonnet")
  H.assert_eq(state.get_active_model("s2"), "sonnet", "workspace's last-used model wins over the active default")
end)
if ok then H.finish(NAME) else H.fail(NAME, err) end
