-- -- Phase 3 cockpit: the winbar gauge (LAST-loop snapshot, never a client
-- tally), the lean statusline glance, and the HUD headless fallback.
local NAME = "21_cockpit"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local state = require("plurnk.state")
  local dispatch = require("plurnk.dispatch")
  local function loop_usage(input_tokens, output_tokens, cost_usd)
    local aggregate = {
      inputTokens = input_tokens,
      outputTokens = output_tokens,
      totalTokens = input_tokens + output_tokens,
    }
    return {
      accounting = {
        requests = { {
          provider = "provider:test",
          model = "test",
          outcome = "response",
          usage = aggregate,
          cost = {
            kind = "estimated",
            amount = { amount = cost_usd, currency = "USD" },
            source = "fixture",
          },
        } },
        usage = aggregate,
        costUsd = cost_usd,
      },
      contextTokens = input_tokens,
      promptBudget = nil,
      meta = {},
    }
  end
  state.set_workspace_id("gauge", 3)
  state.set_active_workspace_name("gauge")
  vim.b.plurnk_workspace = "gauge"

  -- The terminal accounting envelope is a LAST-loop snapshot, never a client tally.
  dispatch.handle_loop_terminated({ loopId = 1, result = { status = 200 }, hitMaxTurns = false,
    usage = loop_usage(2000, 500, "0.007") }, "gauge")
  dispatch.handle_loop_terminated({ loopId = 2, result = { status = 200 }, hitMaxTurns = false,
    usage = loop_usage(1000, 250, "0.003") }, "gauge")
  -- The rich gauge lives in the winbar now; the statusline is a lean glance.
  local wb = require("plurnk.worker_tab").winbar_text("gauge", nil)
  H.assert_match(wb, "🐹 gauge", "winbar names the workspace")
  H.assert_match(wb, "↑1%.0k ↓250", "shows the LAST loop's usage (snapshot), not the sum of both")
  H.assert_eq(state.get_usage("gauge").accounting.costUsd, "0.003", "the exact last-loop decimal is not accumulated or converted")
  H.assert_eq(#state.get_usage("gauge").accounting.requests, 1, "physical request evidence remains cardinal")
  local sl = require("plurnk.statusline").text()
  H.assert_match(sl, "🐹", "statusline shows the brand")
  H.assert_truthy(not sl:match("↑"), "statusline does NOT squat tokens (winbar's job)")

  -- A workspace with no loop yet shows NO gauge (no fake zeros).
  vim.cmd("enew")
  vim.b.plurnk_workspace = "empty"
  state.set_workspace_id("empty", 4)
  H.assert_truthy(not require("plurnk.worker_tab").winbar_text("empty", nil):match("↑"),
    "no token segment before any loop runs")

  -- HUD: headless (no UI) falls back to vim.notify — message still lands.
  local notes = {}
  local orig = vim.notify
  vim.notify = function(msg) table.insert(notes, msg) end
  require("plurnk.hud").show("✓ sh:///demo → 200")
  vim.notify = orig
  H.assert_eq(notes[1], "✓ sh:///demo → 200", "headless HUD falls back to notify")
  H.assert_truthy(not require("plurnk.hud").is_open(), "no float without a UI")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
