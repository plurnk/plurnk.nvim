-- nvim#65 phase 1: the bridge consumer's pure SSE frame parser. Feeds buffers
-- (incl. a frame split across chunks) and asserts decoded events + the retained
-- tail — the reassembly logic, testable without curl or a live bridge.
local NAME = "35_agui"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local agui = require("plurnk.agui")

  -- Two complete frames + a trailing partial (chunk boundary mid-frame).
  local buf = 'data: {"type":"RUN_STARTED"}\n\n'
    .. 'data: {"type":"CUSTOM","name":"plurnk.row","value":{"id":5}}\n\n'
    .. 'data: {"type":"CUSTOM"'
  local events, rest = agui.parse_sse(buf)
  H.assert_eq(#events, 2, "two complete frames decoded")
  H.assert_eq(events[1].type, "RUN_STARTED", "first event type")
  H.assert_eq(events[2].name, "plurnk.row", "second event is the row custom")
  H.assert_eq(events[2].value.id, 5, "row value decoded")
  H.assert_eq(rest, 'data: {"type":"CUSTOM"', "incomplete tail retained for the next chunk")

  -- Feeding the retained tail + its completion reassembles the third frame.
  local events2, rest2 = agui.parse_sse(rest .. ',"name":"plurnk.terminated","value":{"finalStatus":200}}\n\n')
  H.assert_eq(#events2, 1, "the reassembled frame decodes")
  H.assert_eq(events2[1].value.finalStatus, 200, "terminated payload")
  H.assert_eq(rest2, "", "buffer fully drained")

  -- A non-data line (comment/keepalive) is ignored; malformed JSON is skipped.
  local events3 = agui.parse_sse(": keepalive\n\ndata: not json\n\ndata: {\"ok\":true}\n\n")
  H.assert_eq(#events3, 1, "only the valid data frame decodes")
  H.assert_eq(events3[1].ok, true, "valid frame")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
