-- -- nvim#65 phase 1: the bridge consumer's pure SSE frame parser. Feeds buffers
-- (incl. a frame split across chunks) and asserts decoded events + the retained
-- tail — the reassembly logic, testable without curl or a live bridge.
local NAME = "35_agui"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local agui = require("plurnk.agui")

  local prompt_input = agui.input({ threadId = "world", prompt = "hello" })
  H.assert_eq(type(prompt_input.runId), "string", "every request has a runId")
  H.assert_eq(type(prompt_input.messages[1].id), "string", "user messages have ids")
  H.assert_eq(prompt_input.forwardedProps.plurnk.workspace, "world", "workspace rides forwardedProps")

  local resume_input = agui.input({
    threadId = "world",
    resume = { { interruptId = "prop:9", status = "resolved", payload = { decision = "accept" } } },
  })
  H.assert_eq(resume_input.resume[1].interruptId, "prop:9", "standard resume carries the interrupt id")
  H.assert_eq(resume_input.messages, nil, "resume is not approximated by a tool message")
  H.assert_eq(agui.has_interrupt({ type = "interrupt", interrupts = { { id = "prop:9" } } }, "prop:9"), true, "declared interrupt matches its proposal")
  H.assert_eq(agui.has_interrupt({ type = "interrupt", interrupts = { { id = "prop:10" } } }, "prop:9"), false, "a foreign interrupt cannot authorize the proposal")
  H.assert_eq(agui.has_interrupt(nil, "prop:9"), false, "a tool call without an interrupt outcome is not a pause")

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

  -- Full SSE line semantics: comments and foreign fields are ignored; CRLF and
  -- lone CR delimit events; consecutive data fields join with a newline.
  local events3 = agui.parse_sse(
    ": keepalive\r\n"
    .. "event: message\r\n"
    .. "data:{\"type\":\"RUN_STARTED\",\r\n"
    .. "data: \"threadId\":\"world\",\"runId\":\"run\"}\r\n\r\n"
    .. "id: ignored\r"
    .. "data: {\"ok\":true}\r\r",
    true
  )
  H.assert_eq(#events3, 2, "comments, fields, CRLF, CR, and multiline data conform")
  H.assert_eq(events3[1].threadId, "world", "multiline data joined")
  H.assert_eq(events3[2].ok, true, "lone-CR frame decoded")

  local bom_events = agui.parse_sse("\239\187\191data: {\"ok\":\"bom\"}\n\n")
  H.assert_eq(bom_events[1].ok, "bom", "one leading event-stream BOM is ignored")

  -- A CRLF split between chunks is retained and reassembled rather than
  -- misread as two line endings.
  local split_events, split_rest = agui.parse_sse('data: {"ok":"split"}\r')
  H.assert_eq(#split_events, 0, "trailing CR waits for a possible LF")
  local split_done, split_tail = agui.parse_sse(split_rest .. "\n\r\n")
  H.assert_eq(split_done[1].ok, "split", "split CRLF frame decoded")
  H.assert_eq(split_tail, "", "split CRLF buffer drained")

  -- EOF dispatches a complete final event even without a blank line.
  local eof_events, eof_rest = agui.parse_sse('data: {"ok":"eof"}', true)
  H.assert_eq(eof_events[1].ok, "eof", "complete event dispatched at EOF")
  H.assert_eq(eof_rest, "", "EOF buffer drained")

  -- Malformed daemon data is a transport failure, never silently discarded.
  local malformed_ok, malformed_err = pcall(agui.parse_sse, "data: not json\n\n")
  H.assert_eq(malformed_ok, false, "malformed JSON fails hard")
  H.assert_match(tostring(malformed_err), "invalid AG%-UI SSE data JSON", "failure names the transport contract")

  -- The streaming adapter stops and carries that parse failure through its
  -- completion boundary rather than converting it to an ordinary curl exit.
  local real_system = vim.system
  local stdout, complete
  local fake_handle = { killed = false }
  function fake_handle:kill() self.killed = true end
  vim.system = function(_, opts, cb)
    stdout, complete = opts.stdout, cb
    return fake_handle
  end
  local done_error
  agui.run({ url = "http://example.test" }, { threadId = "world", messages = {} }, function() end, function(_, transport_error)
    done_error = transport_error
  end)
  stdout(nil, "data: not json\n\n")
  H.wait_for(function() return fake_handle.killed end, 1000, "malformed SSE stops curl")
  complete({ code = 0 })
  H.wait_for(function() return done_error ~= nil end, 1000, "parse error crosses completion")
  vim.system = real_system
  H.assert_match(done_error, "invalid AG%-UI SSE data JSON", "completion preserves parse error")

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
  H.assert_eq(agui.unproject({ type = "CUSTOM", name = "plurnk.notice", value = { source = "engine:turn", kind = "turn_generated", level = "info" } }, tool).params.notice.source, "engine:turn", "Notice wrapped as {notice}")
  H.assert_eq(agui.unproject({ type = "CUSTOM", name = "plurnk.stream", value = { closeStatus = 200 } }, tool).method, "stream/concluded", "closeStatus → concluded")
  H.assert_eq(agui.unproject({ type = "CUSTOM", name = "plurnk.stream", value = { state = "active" } }, tool).method, "stream/event", "state → event")

  -- JSON null → Lua nil (luanil), NOT vim.NIL — else render.lua concatenates a
  -- userdata (the live-smoke fragment bug). parse_sse must normalize.
  local nulls = agui.parse_sse('data: {"scheme":"known","fragment":null,"hostname":null}\n\n')
  H.assert_eq(nulls[1].fragment, nil, "JSON null decodes to Lua nil, not vim.NIL")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
