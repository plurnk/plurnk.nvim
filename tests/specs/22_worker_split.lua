-- [§nvim-model-worker-waterfall]
-- Worker-split routing (#214): only the model worker (the conversation) is shown
-- in the waterfall. The conversation worker is adopted from events arriving
-- while a loop is in flight (those are the model worker); client-worker
-- housekeeping (op.exec, arriving when no loop is in flight) is never
-- adopted and never rendered. Pure module path; no daemon.
local NAME = "22_worker_split"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local function entry(worker_id, path)
  return { entry = {
    id = math.random(1, 1e6), worker_id = worker_id, loop_id = 1, turn_id = 1,
    loop_seq = 1, turn_seq = 1, sequence = 1,
    op = "READ", origin = "model", status_rx = 200, scheme = "known",
    pathname = path or "/x", tx = {}, rx = {},
  }, workspaceId = 3 }
end

local function waterfall_text(workspace)
  local rec = require("plurnk.worker_tab").get_record(workspace)
  if not rec or not rec.waterfall_buf then return "" end
  return table.concat(vim.api.nvim_buf_get_lines(rec.waterfall_buf, 0, -1, false), "\n")
end

local ok, err = pcall(function()
  local state = require("plurnk.state")
  local dispatch = require("plurnk.dispatch")
  state.set_workspace_id("conv", 3)
  state.set_active_workspace_name("conv")
  vim.b.plurnk_workspace = "conv"
  require("plurnk.worker_tab").open("conv")  -- pending tab, no run yet

  -- A client-worker op.exec entry arriving while NO loop is in flight must be
  -- ignored (housekeeping) — it must not become the conversation worker.
  state.set_loop_inflight("conv", false)
  dispatch.handle_log_entry(entry(99, "/client-exec"), "conv")
  vim.wait(50, function() return false end, 10)
  H.assert_eq(state.get_worker_id("conv"), nil, "client-worker housekeeping is not adopted")
  H.assert_truthy(not waterfall_text("conv"):match("client%-exec"), "housekeeping not rendered")

  -- Now we drive a loop: events that arrive are the model worker. The first
  -- adopts the conversation worker authoritatively (its worker_id).
  state.set_loop_inflight("conv", true)
  dispatch.handle_log_entry(entry(42, "/model-says-hi"), "conv")
  vim.wait(500, function() return waterfall_text("conv"):match("model%-says%-hi") ~= nil end, 10)
  H.assert_eq(state.get_worker_id("conv"), 42, "first in-flight event adopts the model worker")
  H.assert_match(waterfall_text("conv"), "model%-says%-hi", "conversation rendered")

  -- A later wake-loop event (same model worker, even if not in flight) routes.
  state.set_loop_inflight("conv", false)
  dispatch.handle_log_entry(entry(42, "/wake-reaction"), "conv")
  vim.wait(500, function() return waterfall_text("conv"):match("wake%-reaction") ~= nil end, 10)
  H.assert_match(waterfall_text("conv"), "wake%-reaction", "model-worker wake event still routes")

  -- A stray client-worker entry (run 99) never enters the conversation.
  dispatch.handle_log_entry(entry(99, "/more-housekeeping"), "conv")
  vim.wait(50, function() return false end, 10)
  H.assert_truthy(not waterfall_text("conv"):match("more%-housekeeping"),
    "client worker stays out of the conversation once the model worker is known")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
