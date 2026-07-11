-- [§nvim-sse-parser]
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

  -- unproject(e, tool): CUSTOM plurnk.* → daemon notification shapes; core events
  -- dropped; a stopped-world arrives as the request_approval TOOL_CALL triple and
  -- assembles into ONE loop/proposal (AG-UI+ terminate-resume).
  local tool = {}
  H.assert_eq(agui.unproject({ type = "TEXT_MESSAGE_CONTENT", delta = "x" }, tool), nil, "core AG-UI event dropped")
  local row = agui.unproject({ type = "CUSTOM", name = "plurnk.row", value = { id = 7, op = "SEND" } }, tool)
  H.assert_eq(row.method, "log/entry", "plurnk.row → log/entry")
  H.assert_eq(row.params.entry.id, 7, "row value wrapped as {entry}")
  H.assert_eq(agui.unproject({ type = "CUSTOM", name = "plurnk.terminated", value = { finalStatus = 200 } }, tool).method, "loop/terminated", "terminated")
  H.assert_eq(agui.unproject({ type = "TOOL_CALL_START", toolCallId = "prop:9", toolCallName = "request_approval" }, tool), nil, "triple start assembles silently")
  H.assert_eq(agui.unproject({ type = "TOOL_CALL_ARGS", toolCallId = "prop:9", delta = '{"op":"EDIT","body":"diff"}' }, tool), nil, "args accumulate")
  local prop = agui.unproject({ type = "TOOL_CALL_END", toolCallId = "prop:9" }, tool)
  H.assert_eq(prop.method, "loop/proposal", "the triple folds into loop/proposal")
  H.assert_eq(prop.params.logEntryId, 9, "logEntryId decoded from the toolCallId")
  H.assert_eq(prop.params.op, "EDIT", "args carried")
  H.assert_eq(agui.unproject({ type = "CUSTOM", name = "plurnk.telemetry", value = { source = "engine:rail" } }, tool).params.event.source, "engine:rail", "telemetry wrapped as {event}")
  H.assert_eq(agui.unproject({ type = "CUSTOM", name = "plurnk.stream", value = { closeStatus = 200 } }, tool).method, "stream/concluded", "closeStatus → concluded")
  H.assert_eq(agui.unproject({ type = "CUSTOM", name = "plurnk.stream", value = { state = "active" } }, tool).method, "stream/event", "state → event")

  -- JSON null → Lua nil (luanil), NOT vim.NIL — else render.lua concatenates a
  -- userdata (the live-smoke fragment bug). parse_sse must normalize.
  local nulls = agui.parse_sse('data: {"scheme":"known","fragment":null,"hostname":null}\n\n')
  H.assert_eq(nulls[1].fragment, nil, "JSON null decodes to Lua nil, not vim.NIL")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
