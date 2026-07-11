-- [§nvim-push-pipeline]
-- op.parse against a hand-rolled DSL packet produces a log/entry
-- notification. Verifies the push pipeline: dispatch → state.set_last_seen_log_id.
local NAME = "05_op_parse_logentry"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()
local ok, err = pcall(function()
  -- Need a session for the log/entry to belong to.
  local fresh = string.format("plurnk-nvim-test-%d-%d", vim.loop.hrtime(), math.random(1, 1e6))
  local sess = H.call("session.create", { name = fresh })
  H.assert_type(sess.id, "number", "session id")

  -- Tap log/entry notifications. The dispatch already routes them through
  -- state; we additionally observe them by patching the handler.
  local dispatch = require("plurnk.dispatch")
  local seen = {}
  local original = dispatch.handle_log_entry
  dispatch.handle_log_entry = function(params, sn)
    if params and params.entry then table.insert(seen, params.entry) end
    return original(params, sn)
  end

  -- EDIT a known scheme key — simplest op that always succeeds and emits
  -- a log/entry. The known scheme is an in-memory KV; EDIT writes a value.
  local key = "/plurnk-nvim-test-" .. tostring(vim.loop.hrtime())
  local dsl = "<<EDIT(known://" .. key .. "):hello:EDIT"
  local parsed = H.call("op.parse", { text = dsl })
  H.assert_type(parsed, "table", "op.parse result")
  H.assert_type(parsed.results, "table", "op.parse.results")
  H.assert_truthy(#parsed.results >= 1, "op.parse non-empty results")

  H.wait_for(function() return #seen > 0 end, 5000, "log/entry notification")
  local entry = seen[1]
  H.assert_type(entry.id, "number", "entry.id")
  H.assert_eq(entry.op, "EDIT", "entry.op")
end)
if ok then H.finish(NAME) else H.fail(NAME, err) end
