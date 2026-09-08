-- -- The statusline mirrors the TUI's one activity slot; rich identity and
-- accounting live in the winbar — worker_tab.winbar_text.
local NAME = "08_statusline"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()
local ok, err = pcall(function()
  local state = require("plurnk.state")
  local worker_tab = require("plurnk.worker_tab")
  local function loop_usage(input_tokens, output_tokens, cost_usd, curation_weight, curation_budget, context_tokens, context_capacity)
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
      curationWeight = curation_weight,
      curationBudget = curation_budget,
      contextTokens = context_tokens,
      contextCapacity = context_capacity,
      meta = {},
    }
  end
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].plurnk_workspace = "s1"
  local runtime_status = require("plurnk.runtime_status")
  local handled, gauge = runtime_status.reduce(nil, {
    type = "STATE_SNAPSHOT",
    snapshot = {
      plurnk = { status = {
        lifecycle = "running",
        model = { alias = "claude", provider = "anthropic", model = "sonnet" },
        loopId = 7,
        packetCount = 2,
        activity = vim.NIL,
        children = 2,
      } },
      budget = {},
    },
  })
  H.assert_eq(handled, true, "runtime snapshot is handled")
  state.set_runtime_gauge("s1", gauge)
  state.record_loop_usage("s1", loop_usage(0, 0, "0.0700"))

  -- ── lean statusline: a glance, not a squat on shared real estate ──
  local sl = require("plurnk.statusline").text()
  H.assert_eq(sl, "⌛︎", "active loop uses the exact shared hourglass")
  H.assert_truthy(not sl:match("🐹"), "the activity slot carries no redundant brand")
  H.assert_truthy(not sl:match("🔥"), "active lifecycle supersedes idle YOLO state")
  H.assert_truthy(not sl:match("s1"), "statusline does NOT show the workspace name (winbar's job)")
  H.assert_truthy(not sl:match("claude"), "statusline does NOT show the model (winbar's job)")
  H.assert_truthy(not sl:match("loop:"), "statusline does NOT show money (winbar's job)")

  -- ── rich winbar: identity + authoritative lifecycle/model/packets + money ──
  local wb = worker_tab.winbar_text("s1", 7)
  H.assert_match(wb, "plurnk", "winbar names the client without a mascot")
  H.assert_truthy(not wb:match("🐹"), "the retired mascot is absent from the winbar")
  H.assert_match(wb, "s1", "workspace")
  H.assert_match(wb, "claude", "model")
  H.assert_match(wb, "P2", "authoritative packet count")
  H.assert_truthy(not wb:match("L7") and not wb:match("T2"), "row coordinates do not masquerade as packet status")
  H.assert_match(wb, "⌛︎", "in-flight glyph in winbar")
  H.assert_match(wb, "loop: %$0%.0700", "per-loop cost, labelled 'loop:'")
  local lifecycle_at, model_at, packet_at = wb:find("⌛︎"), wb:find("🤖 claude"), wb:find("P2")
  H.assert_truthy(lifecycle_at < model_at and model_at < packet_at, "winbar status order is lifecycle → model → packet count")
  -- {§nvim-status-children}: the ant is the daemon's alive-children count, after the packet count
  H.assert_match(wb, "P2 · 🐜2", "the daemon's alive-children count rides the winbar as the ant")
  local _, older = runtime_status.reduce(nil, { type = "STATE_SNAPSHOT", snapshot = { plurnk = { status = {
    lifecycle = "idle", model = vim.NIL, loopId = vim.NIL, packetCount = 0, activity = vim.NIL } }, budget = {} } })
  H.assert_truthy(runtime_status.project(older).children == nil, "an older daemon states no count")
  state.set_runtime_gauge("s1", older)
  H.assert_truthy(not worker_tab.winbar_text("s1", 7):match("🐜"), "no count, no ant")
  state.set_runtime_gauge("s1", gauge)

  handled, gauge = runtime_status.reduce(gauge, {
    type = "STATE_DELTA",
    delta = { { op = "replace", path = "/plurnk/status/lifecycle", value = "completed" } },
  })
  state.set_runtime_gauge("s1", gauge)
  H.assert_match(worker_tab.winbar_text("s1", 7), "⏹️", "completion lifecycle glyph")
  H.assert_truthy(not worker_tab.winbar_text("s1", 7):match("200"), "routine final code is not repeated")
  handled, gauge = runtime_status.reduce(gauge, {
    type = "STATE_DELTA",
    delta = { { op = "replace", path = "/plurnk/status/lifecycle", value = "queued" } },
  })
  state.set_runtime_gauge("s1", gauge)
  H.assert_eq(state.get_runtime_status("s1").lifecycle, "queued", "a future task is neither running nor WAITing")
  H.assert_match(worker_tab.winbar_text("s1", 7), "⏳", "queued work uses the shared queued glyph")
  H.assert_eq(require("plurnk.statusline").text(), "⏳", "queued work is not presented as active inference")
  handled, gauge = runtime_status.reduce(gauge, {
    type = "STATE_DELTA",
    delta = { { op = "replace", path = "/plurnk/status/lifecycle", value = "failed" } },
  })
  state.set_runtime_gauge("s1", gauge)
  H.assert_match(worker_tab.winbar_text("s1", 7), "❌", "failed lifecycle comes from AG-UI state")

  require("plurnk.diff").set_yolo(true)
  H.assert_eq(require("plurnk.statusline").text(), "🔥", "idle YOLO uses the same fire as the TUI")
  require("plurnk.diff").set_yolo(false)

  -- record_loop_usage is a SNAPSHOT, not a tally: a second loop's cost REPLACES.
  state.record_loop_usage("s1", loop_usage(0, 0, "0.05"))
  H.assert_match(worker_tab.winbar_text("s1", 7), "loop: %$0%.05", "the next exact loop envelope replaces the prior one")

  -- Unknown monetary evidence stays unknown and cannot inherit a prior loop's cost.
  state.record_loop_usage("s1", loop_usage(0, 0, nil))
  local unknown = worker_tab.winbar_text("s1", 7)
  H.assert_match(unknown, "loop: %$unknown", "unknown money remains unknown")
  H.assert_truthy(not unknown:match("%$0%.05"), "an unknown loop never inherits prior evidence")

  -- Curation pressure and context occupancy are independent gauges from the
  -- same terminal envelope; model-independent weight is never compared to tokens.
  state.set_available_aliases({ { alias = "opus", active = true, contextSize = 128000 } })
  state.record_loop_usage("s1", loop_usage(0, 0, "0", 12000, 48000, 7360, 49152))
  local gauges = worker_tab.winbar_text("s1", 7)
  H.assert_match(gauges, "cur 25%%/48k", "curation pressure uses only weight and its budget")
  H.assert_match(gauges, "ctx 15%%/49k", "context occupancy uses only provider tokens and capacity")
  state.record_loop_usage("s1", loop_usage(0, 0, "0", 12000, 48000, 7360, nil))
  local partial = worker_tab.winbar_text("s1", 7)
  H.assert_match(partial, "cur 25%%/48k", "a known curation gauge survives unknown context capacity")
  H.assert_truthy(not partial:match("ctx "), "no context gauge when terminal capacity is unknown")

  -- Active-model resolution (converged with the TUI header): with no loop yet
  -- (no durable model selector), the winbar still names the daemon's active default from
  -- the warmed providers.list cache.
  state.set_available_aliases({ { alias = "haiku", active = false }, { alias = "opus", active = true } })
  H.assert_eq(state.get_active_model("s2"), "opus", "active default resolved when no loop has set a model")
  H.assert_match(worker_tab.winbar_text("s2", nil), "🤖 opus", "winbar names the active default from cold")
  -- An explicit per-workspace model still wins over the daemon default.
  state.set_model_selector("s2", "anthropic/claude-sonnet-4")
  H.assert_eq(state.get_active_model("s2"), "anthropic/claude-sonnet-4", "workspace's exact route wins over the active default")
end)
if ok then H.finish(NAME) else H.fail(NAME, err) end
