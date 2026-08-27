-- {§nvim-readable-reasoning}: a completed standard reasoning lifecycle is
-- idempotent when an AG-UI segment is replayed after interrupt or reconnect.
local NAME = "56_reasoning_replay"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local state = require("plurnk.state")
  local worker_tab = require("plurnk.worker_tab")
  state.set_workspace_id("reasoning-replay", 1)
  state.set_worker_id("reasoning-replay", 7)
  worker_tab.open("reasoning-replay")

  local function deliver()
    worker_tab.begin_reasoning("reasoning-replay", 7, "model-call-41/reasoning")
    worker_tab.append_reasoning_delta("reasoning-replay", 7, "model-call-41/reasoning", "inspect the evidence")
    worker_tab.end_reasoning("reasoning-replay", 7, "model-call-41/reasoning")
  end

  deliver()
  deliver()

  local rec = worker_tab.get_record("reasoning-replay", 7)
  local content = table.concat(vim.api.nvim_buf_get_lines(rec.waterfall_buf, 0, -1, false), "\n")
  local _, count = content:gsub("inspect the evidence", "")
  H.assert_eq(count, 1, "a replayed completed lifecycle renders exactly once")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
