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
  H.assert_eq(#resume_input.messages, 0, "resume carries the required empty message array")
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
  local events2, rest2 = agui.parse_sse(rest .. ',"name":"plurnk.terminated","value":{"result":{"status":200}}}\n\n')
  H.assert_eq(#events2, 1, "the reassembled frame decodes")
  H.assert_eq(events2[1].value.result.status, 200, "terminated payload")
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
  H.assert_eq(done_error.status, 502, "parse failure is an exact transport Problem")
  H.assert_match(done_error.type, "/invalid%-event%-stream$", "parse failure has a stable Problem type")
  H.assert_eq(done_error.retryable, false, "a malformed response is not safe to replay")
  local http_problem
  agui.run({ url = "http://example.test" }, { threadId = "world", messages = {} }, function() end, function(_, transport_error)
    http_problem = transport_error
  end)
  stdout(nil, vim.json.encode({
    type = "https://problems.plurnk.dev/agui/http/bearer-token-required",
    title = "Bearer token required",
    status = 401,
    detail = "A bearer token is required.",
    retryable = false,
  }))
  complete({ code = 0 })
  H.wait_for(function() return type(http_problem) == "table" end, 1000, "HTTP Problem crosses completion")
  H.assert_eq(http_problem.status, 401, "HTTP Problem status is preserved")
  H.assert_eq(http_problem.retryable, false, "HTTP Problem extensions are preserved")

  local unavailable_problem
  agui.run({ url = "http://example.test" }, { threadId = "world", messages = {} }, function() end, function(_, transport_error)
    unavailable_problem = transport_error
  end)
  complete({ code = 7 })
  H.wait_for(function() return type(unavailable_problem) == "table" end, 1000, "connection failure crosses completion")
  H.assert_eq(unavailable_problem.status, 503, "connection failure is an exact transport Problem")
  H.assert_match(unavailable_problem.type, "/connection/refused$", "connection failure has the shared client Problem type")
  H.assert_eq(unavailable_problem.retryable, true, "a request that never reached the daemon is safe to retry")

  -- An action proposal ends only the current AG-UI segment. It is not a
  -- missing action result; the result arrives on the resume segment.
  local interrupted_segment
  agui.rpc({ url = "http://example.test" }, "world", "op.exec", {}, function(segment)
    interrupted_segment = segment
  end, function() end)
  stdout(nil, table.concat({
    "data: " .. vim.json.encode({ type = "RUN_STARTED", threadId = "world", runId = "action-1" }),
    "",
    "data: " .. vim.json.encode({
      type = "RUN_FINISHED",
      threadId = "world",
      runId = "action-1",
      outcome = { type = "interrupt", interrupts = { { id = "prop:9" } } },
    }),
    "",
    "",
  }, "\n"))
  complete({ code = 0 })
  H.wait_for(function() return interrupted_segment ~= nil end, 1000, "interrupted action segment settles")
  H.assert_eq(interrupted_segment.state, "interrupted", "confirmed interrupt is not misreported as a missing daemon")

  local resumed_segment
  agui.resume_action({ url = "http://example.test" }, {
    threadId = "world",
    logEntryId = 9,
    decision = "accept",
  }, function(segment)
    resumed_segment = segment
  end, function() end)
  stdout(nil, table.concat({
    "data: " .. vim.json.encode({
      type = "CUSTOM",
      name = "plurnk.action.result",
      value = { kind = "op.exec", ok = true, result = { accepted = true } },
    }),
    "",
    "data: " .. vim.json.encode({
      type = "RUN_FINISHED",
      threadId = "world",
      runId = "action-2",
      outcome = { type = "success" },
    }),
    "",
    "",
  }, "\n"))
  complete({ code = 0 })
  H.wait_for(function() return resumed_segment ~= nil end, 1000, "resumed action segment settles")
  H.assert_eq(resumed_segment.state, "complete", "resume carries the action to completion")
  H.assert_eq(resumed_segment.result.accepted, true, "resume preserves the action result")

  local missing_segment
  agui.rpc({ url = "http://example.test" }, "world", "ping", {}, function(segment)
    missing_segment = segment
  end, function() end)
  stdout(nil, table.concat({
    "data: " .. vim.json.encode({
      type = "RUN_FINISHED",
      threadId = "world",
      runId = "action-3",
      outcome = { type = "success" },
    }),
    "",
    "",
  }, "\n"))
  complete({ code = 0 })
  H.wait_for(function() return missing_segment ~= nil end, 1000, "result-less action segment settles")
  H.assert_eq(missing_segment.state, "failed", "success terminal cannot fabricate a missing action result")
  H.assert_eq(missing_segment.problem.status, 502, "missing action result is an exact transport failure")
  H.assert_match(missing_segment.problem.type, "/action/result%-missing$", "missing action result has the shared client Problem type")

  vim.system = real_system

  -- unproject(e, tool): CUSTOM plurnk.* → daemon notification shapes; core events
  -- dropped; a stopped-world arrives as the request_approval TOOL_CALL triple and
  -- assembles into ONE loop/proposal (AG-UI+ terminate-resume).
  local tool = {}
  H.assert_eq(agui.unproject({ type = "TEXT_MESSAGE_CONTENT", delta = "x" }, tool), nil, "core AG-UI event dropped")
  local row = agui.unproject({ type = "CUSTOM", name = "plurnk.row", value = { id = 7, op = "SEND" } }, tool)
  H.assert_eq(row.method, "log/entry", "plurnk.row → log/entry")
  H.assert_eq(row.params.entry.id, 7, "row value wrapped as {entry}")
  H.assert_eq(agui.unproject({ type = "CUSTOM", name = "plurnk.terminated", value = { result = { status = 200 } } }, tool).method, "loop/terminated", "terminated")
  local problem = { type = "https://problems.plurnk.dev/test", title = "Test", status = 409, detail = "Conflict.", recovery = "Change the input." }
  local problem_event = agui.unproject({ type = "CUSTOM", name = "plurnk.problem", value = problem }, tool)
  H.assert_eq(problem_event.method, "problem/event", "Problem custom is preserved")
  H.assert_eq(problem_event.params.problem, problem, "Problem table is not flattened")
  for _, specimen in ipairs({
    { label = "success status", value = { status = 200 } },
    { label = "fractional status", value = { status = 499.5 } },
    { label = "relative type", value = { type = "relative" } },
    { label = "empty title", value = { title = "" } },
    { label = "empty detail", value = { detail = "" } },
    { label = "relative instance", value = { instance = "relative" } },
    { label = "empty stage", value = { stage = "" } },
    { label = "empty recovery", value = { recovery = "" } },
    { label = "non-boolean retryable", value = { retryable = "yes" } },
  }) do
    local candidate = vim.tbl_extend("force", problem, specimen.value)
    H.assert_eq(agui.is_problem(candidate), false, specimen.label .. " is not valid Problem Details")
  end
  local invalid_problem_event = agui.unproject({
    type = "CUSTOM",
    name = "plurnk.problem",
    value = { status = 500 },
  }, tool)
  H.assert_match(invalid_problem_event.params.problem.type, "/problem%-invalid$", "invalid Problem maps at the client boundary")

  local missing_status, missing_problem = agui.operation_result({ status = 500 })
  H.assert_eq(missing_status, 502, "a failed result without a Problem is a client contract failure")
  H.assert_match(missing_problem.type, "/problem%-missing$", "missing failure truth has a stable Problem type")
  local invalid_status, invalid_result = agui.operation_result({ status = 200, problem = problem })
  H.assert_eq(invalid_status, 502, "a success carrying a Problem is invalid")
  H.assert_match(invalid_result.type, "/result%-invalid$", "invalid result has a stable Problem type")

  local malformed_tool = {}
  agui.unproject({ type = "TOOL_CALL_START", toolCallId = "prop:12" }, malformed_tool)
  agui.unproject({ type = "TOOL_CALL_ARGS", toolCallId = "prop:12", delta = "{" }, malformed_tool)
  local malformed_proposal = agui.unproject({ type = "TOOL_CALL_END", toolCallId = "prop:12" }, malformed_tool)
  H.assert_eq(malformed_proposal.method, "problem/event", "malformed proposal is not fabricated into an empty proposal")
  H.assert_match(malformed_proposal.params.problem.type, "/proposal%-invalid$", "malformed proposal has an exact Problem")
  H.assert_eq(malformed_proposal.params.problem.logEntryId, 12, "proposal identity is retained")

  -- The daemon's terminal truth is result.status. No finalStatus sibling exists
  -- on the real wire; a non-500 failure must survive the bridge unchanged.
  local original_run = agui.run
  local dispatch = require("plurnk.dispatch")
  local original_handle_notification = dispatch.handle_notification
  local problem_events = 0
  dispatch.handle_notification = function(notification)
    if notification.method == "problem/event" then problem_events = problem_events + 1 end
  end
  agui.run = function(_, _, on_event, on_done)
    local terminal_problem = {
      type = "https://problems.plurnk.dev/lifecycle/cancel/loop-cancelled",
      title = "Loop cancelled",
      status = 499,
      detail = "The loop was cancelled.",
    }
    on_event({
      type = "CUSTOM",
      name = "plurnk.problem",
      value = terminal_problem,
    })
    on_event({
      type = "CUSTOM",
      name = "plurnk.terminated",
      value = {
        result = {
          status = 499,
          problem = terminal_problem,
        },
        hitMaxTurns = false,
      },
    })
    on_event({ type = "RUN_ERROR", code = "ignored", message = "The loop was cancelled." })
    on_done(0, nil)
    return {}
  end
  local bridge_status
  require("plurnk.bridge").run("world", "stop", {}, function(status) bridge_status = status end)
  H.assert_eq(bridge_status, 499, "bridge termination uses the exact result status")
  H.assert_eq(problem_events, 1, "one failure occurrence is dispatched exactly once")

  agui.run = function(_, _, on_event, on_done)
    on_event({ type = "RUN_ERROR", code = "429", message = "lossy" })
    on_done(0, nil)
    return {}
  end
  local missing_problem_status
  require("plurnk.bridge").run("world", "fail", {}, function(status) missing_problem_status = status end)
  H.assert_eq(missing_problem_status, 502, "bare RUN_ERROR cannot manufacture terminal failure truth")
  H.assert_eq(problem_events, 2, "a missing Problem creates one transport failure occurrence")
  agui.run = original_run
  dispatch.handle_notification = original_handle_notification

  -- A proposal-gated action owns the management lane across its interrupt and
  -- resume. Its continuation does not queue behind itself, while the next action
  -- cannot steal the lane before the original result arrives.
  local bridge = require("plurnk.bridge")
  local original_handle = dispatch.handle_notification
  local original_rpc = agui.rpc
  local original_resume_action = agui.resume_action
  local rpc_calls, second_started = 0, false
  local first_result, second_result, resolve_code, resolve_problem
  dispatch.handle_notification = function() end
  agui.rpc = function(_, _, _, _, cb, on_event)
    rpc_calls = rpc_calls + 1
    if rpc_calls == 1 then
      on_event({ type = "TOOL_CALL_START", toolCallId = "prop:9", toolCallName = "request_approval" })
      on_event({ type = "TOOL_CALL_ARGS", toolCallId = "prop:9", delta = '{"op":"EXEC"}' })
      on_event({ type = "TOOL_CALL_END", toolCallId = "prop:9" })
      cb({
        state = "interrupted",
        outcome = { type = "interrupt", interrupts = { { id = "prop:9" } } },
        code = 0,
      })
    else
      second_started = true
      cb({ state = "complete", result = { second = true }, code = 0 })
    end
  end
  agui.resume_action = function(_, _, cb)
    cb({ state = "complete", result = { first = true }, code = 0 })
  end
  bridge.rpc("world", "op.exec", {}, function(result) first_result = result end)
  bridge.rpc("world", "ping", {}, function(result) second_result = result end)
  H.assert_eq(first_result, nil, "interrupted action does not complete early")
  H.assert_eq(second_started, false, "queued action cannot steal the interrupted action's lane")
  bridge.resolve("world", { logEntryId = 9, decision = "accept" }, function(code, problem)
    resolve_code, resolve_problem = code, problem
  end)
  H.wait_for(function() return second_result ~= nil end, 1000, "lane advances after resumed action completes")
  H.assert_eq(first_result.first, true, "resumed result completes the original action")
  H.assert_eq(resolve_code, 0, "resolution acknowledges its completed resume segment")
  H.assert_eq(resolve_problem, nil, "successful resolution has no fabricated Problem")
  H.assert_eq(second_result.second, true, "queued action begins after the lane owner completes")
  dispatch.handle_notification = original_handle
  agui.rpc = original_rpc
  agui.resume_action = original_resume_action

  -- A failed action may carry the same Problem in the lossless custom event and
  -- its action result. The client dispatches that occurrence once instead of
  -- also raising a second notification from the management callback.
  local original_notify = vim.notify
  local action_problem_events, action_notifies = 0, 0
  local failed_action_done = false
  dispatch.handle_notification = function(notification)
    if notification.method == "problem/event" then
      action_problem_events = action_problem_events + 1
    end
  end
  vim.notify = function() action_notifies = action_notifies + 1 end
  agui.rpc = function(_, _, _, _, cb, on_event)
    local failure = {
      type = "https://problems.plurnk.dev/daemon/action/refused",
      title = "Action refused",
      status = 409,
      detail = "The action was refused.",
    }
    on_event({ type = "CUSTOM", name = "plurnk.problem", value = failure })
    cb({ state = "failed", problem = failure, code = 0 })
  end
  bridge.rpc("world", "op.exec", {}, function(result)
    H.assert_eq(result, nil, "failed action has no fabricated result")
    failed_action_done = true
  end)
  H.wait_for(function() return failed_action_done end, 1000, "failed action settles")
  H.assert_eq(action_problem_events, 1, "failed action dispatches one Problem occurrence")
  H.assert_eq(action_notifies, 0, "lossless Problem dispatch suppresses a duplicate action notification")
  dispatch.handle_notification = original_handle
  agui.rpc = original_rpc
  vim.notify = original_notify

  H.assert_eq(agui.unproject({ type = "TOOL_CALL_START", toolCallId = "prop:9", toolCallName = "request_approval" }, tool), nil, "triple start assembles silently")
  H.assert_eq(agui.unproject({ type = "TOOL_CALL_ARGS", toolCallId = "prop:9", delta = '{"op":"EDIT","body":"diff"}' }, tool), nil, "args accumulate")
  local prop = agui.unproject({ type = "TOOL_CALL_END", toolCallId = "prop:9" }, tool)
  H.assert_eq(prop.method, "loop/proposal", "the triple folds into loop/proposal")
  H.assert_eq(prop.params.logEntryId, 9, "logEntryId decoded from the toolCallId")
  H.assert_eq(prop.params.op, "EDIT", "args carried")
  H.assert_eq(agui.unproject({ type = "CUSTOM", name = "plurnk.notice", value = { source = "engine:turn", kind = "turn_generated", level = "info" } }, tool).params.notice.source, "engine:turn", "Notice wrapped as {notice}")
  H.assert_eq(agui.unproject({ type = "CUSTOM", name = "plurnk.branch_batch", value = { batchId = 7, state = "queued" } }, tool).method, "workspace/branch-batch", "branch batch custom preserved")
  H.assert_eq(agui.unproject({ type = "CUSTOM", name = "plurnk.stream", value = { result = { status = 200 } } }, tool).method, "stream/concluded", "result → concluded")
  H.assert_eq(agui.unproject({ type = "CUSTOM", name = "plurnk.stream", value = { state = "active" } }, tool).method, "stream/event", "state → event")

  -- JSON null → Lua nil (luanil), NOT vim.NIL — else render.lua concatenates a
  -- userdata (the live-smoke fragment bug). parse_sse must normalize.
  local nulls = agui.parse_sse('data: {"scheme":"known","fragment":null,"hostname":null}\n\n')
  H.assert_eq(nulls[1].fragment, nil, "JSON null decodes to Lua nil, not vim.NIL")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
