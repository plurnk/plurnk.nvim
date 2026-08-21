-- The Lua consumer of the plurnk-agui bridge. No fetch in
-- Lua, so the SSE run rides `curl -N` under vim.system with a streaming stdout
-- callback; the management plane + resolve are one-shot curl POSTs.
--
-- Mirrors the client's agui.ts: run() streams AG-UI events, resolve() answers a
-- stopped-world proposal, and rpc() carries management actions. Plurnk fidelity
-- rides the CUSTOM plurnk.* events (esp. plurnk.row — the full wire row), which a
-- is un-projected to the daemon shapes dispatch.lua already renders.
local M = {}
local id_sequence = 0

local function new_id(prefix)
  id_sequence = id_sequence + 1
  return string.format("%s-%x-%x", prefix, vim.uv.hrtime(), id_sequence)
end

local function empty_array()
  return vim.json.decode("[]")
end

function M.is_problem(value)
  if type(value) ~= "table" then return false end
  local function nonempty(field)
    return type(field) == "string" and #field > 0
  end
  local function absolute_uri(field)
    return type(field) == "string" and field:match("^[A-Za-z][A-Za-z0-9+.-]*:") ~= nil
  end
  return absolute_uri(value.type)
      and nonempty(value.title)
      and type(value.status) == "number"
      and value.status == math.floor(value.status)
      and value.status >= 400
      and value.status <= 599
      and nonempty(value.detail)
      and (value.instance == nil or absolute_uri(value.instance))
      and (value.stage == nil or nonempty(value.stage))
      and (value.recovery == nil or nonempty(value.recovery))
      and (value.retryable == nil or type(value.retryable) == "boolean")
end

-- Pure, dependency-free SSE extraction for Neovim's Lua runtime. It implements
-- the event-stream line rules rather than assuming one LF-delimited data line:
-- CRLF/LF/CR, comments, ignored fields, multiline data, and split chunks.
local function next_line(buffer, start)
  local pos = buffer:find("[\r\n]", start)
  if pos == nil then return nil end
  local ending = buffer:sub(pos, pos)
  -- A trailing CR may be the first half of a CRLF split across chunks.
  if ending == "\r" and pos == #buffer then return nil end
  local next_pos = pos + 1
  if ending == "\r" and buffer:sub(next_pos, next_pos) == "\n" then next_pos = next_pos + 1 end
  return buffer:sub(start, pos - 1), next_pos
end

function M.parse_sse(buffer, eof)
  local source = eof and (buffer .. "\n\n") or buffer
  if source:sub(1, 3) == "\239\187\191" then source = source:sub(4) end
  local events, data_lines = {}, {}
  local frame_start, pos = 1, 1
  while true do
    local line, next_pos = next_line(source, pos)
    if line == nil then return events, eof and "" or source:sub(frame_start) end
    if line == "" then
      if #data_lines > 0 then
        local data = table.concat(data_lines, "\n")
        local okp, decoded = pcall(vim.json.decode, data, { luanil = { object = true, array = true } })
        if not okp then error("invalid AG-UI SSE data JSON: " .. tostring(decoded), 0) end
        events[#events + 1] = decoded
      end
      data_lines = {}
      frame_start = next_pos
    elseif line:sub(1, 1) ~= ":" then
      local colon = line:find(":", 1, true)
      local field = colon == nil and line or line:sub(1, colon - 1)
      local value = colon == nil and "" or line:sub(colon + 1)
      if value:sub(1, 1) == " " then value = value:sub(2) end
      if field == "data" then data_lines[#data_lines + 1] = value end
    end
    pos = next_pos
  end
end

-- Project standard readable reasoning or un-project a family AG-UI event into
-- the notification shape dispatch.lua routes ({ method, params }), or nil to
-- await more deltas/drop it. AG-UI+ dialect: a stopped-world
-- proposal arrives as a request_approval/request_user_input TOOL_CALL triple (the
-- run then FINISHES; the loop stays paused in-engine — the resume is a tool-result
-- run). The assembler below folds the triple into ONE loop/proposal notification.
function M.unproject(e, tool)
  if type(e) ~= "table" then return nil end
  if e.type == "REASONING_START" or e.type == "REASONING_END" then return nil end
  if e.type == "REASONING_MESSAGE_START" and type(e.messageId) == "string" then
    tool.reasoning = tool.reasoning or {}
    if tool.reasoning[e.messageId] ~= nil then
      error("reasoning message started twice: " .. e.messageId, 0)
    end
    tool.reasoning[e.messageId] = ""
    return nil
  end
  if e.type == "REASONING_MESSAGE_CONTENT" and type(e.messageId) == "string" then
    tool.reasoning = tool.reasoning or {}
    local prior = tool.reasoning[e.messageId]
    if prior == nil then error("reasoning content arrived before its start: " .. e.messageId, 0) end
    tool.reasoning[e.messageId] = prior .. tostring(e.delta or "")
    return nil
  end
  if e.type == "REASONING_MESSAGE_END" and type(e.messageId) == "string" then
    tool.reasoning = tool.reasoning or {}
    local content = tool.reasoning[e.messageId]
    if content == nil then error("reasoning message ended before its start: " .. e.messageId, 0) end
    tool.reasoning[e.messageId] = nil
    if content == "" then return nil end
    return { method = "reasoning/message", params = { messageId = e.messageId, content = content } }
  end
  if e.type == "TOOL_CALL_START" and type(e.toolCallId) == "string" and e.toolCallId:find("^prop:") then
    tool.id = e.toolCallId; tool.args = ""
    return nil
  end
  if e.type == "TOOL_CALL_ARGS" and tool.id ~= nil and e.toolCallId == tool.id then
    tool.args = tool.args .. (e.delta or ""); return nil
  end
  if e.type == "TOOL_CALL_END" and tool.id ~= nil and e.toolCallId == tool.id then
    local log_entry_id = tonumber(tool.id:sub(6))
    local okp, a = pcall(vim.json.decode, tool.args ~= "" and tool.args or "{}", { luanil = { object = true, array = true } })
    tool.id = nil
    if not okp then
      return {
        method = "problem/event",
        params = {
          problem = M.transport_problem(
            "proposal-invalid",
            "Proposal invalid",
            502,
            "The proposal contained invalid JSON arguments.",
            false,
            "proposal-resolution",
            { logEntryId = log_entry_id, reason = tostring(a) }
          ),
        },
      }
    end
    a.logEntryId = log_entry_id
    return { method = "loop/proposal", params = a }
  end
  if e.type ~= "CUSTOM" then return nil end
  local name, v = e.name, e.value
  if name == "plurnk.row" then return { method = "log/entry", params = { entry = v } } end
  if name == "plurnk.terminated" then return { method = "loop/terminated", params = v } end
  if name == "plurnk.problem" then
    local problem = M.is_problem(v) and v or M.transport_problem(
      "problem-invalid",
      "Problem invalid",
      502,
      "The AG-UI stream contained invalid Problem Details.",
      false
    )
    return { method = "problem/event", params = { problem = problem } }
  end
  if name == "plurnk.notice" then return { method = "notice/event", params = { notice = v } } end
  if name == "plurnk.branch_batch" then return { method = "workspace/branch-batch", params = v } end
  if name == "plurnk.stream" then
    local concluded = type(v) == "table" and type(v.result) == "table" and type(v.result.status) == "number"
    return { method = concluded and "stream/concluded" or "stream/event", params = v }
  end
  return nil
end

function M.has_interrupt(outcome, interrupt_id)
  if type(outcome) ~= "table" or outcome.type ~= "interrupt" or type(outcome.interrupts) ~= "table" then return false end
  for _, interrupt in ipairs(outcome.interrupts) do
    if type(interrupt) == "table" and interrupt.id == interrupt_id then return true end
  end
  return false
end

local function auth_headers(target)
  local h = { "-H", "content-type: application/json" }
  if type(target.token) == "string" and #target.token > 0 then
    vim.list_extend(h, { "-H", "authorization: Bearer " .. target.token })
  end
  return h
end

function M.client_problem(owner, kind, title, status, detail, stage, retryable, extensions)
  return vim.tbl_extend("force", {
    type = "https://problems.plurnk.dev/client/" .. owner .. "/" .. kind,
    title = title,
    status = status,
    detail = detail,
    source = "client:" .. owner,
    kind = kind,
    stage = stage,
    retryable = retryable,
  }, extensions or {})
end

function M.transport_problem(kind, title, status, detail, retryable, stage, extensions)
  return M.client_problem("transport", kind, title, status, detail, stage or "transport", retryable, extensions)
end

function M.operation_result(value)
  if type(value) ~= "table" or type(value.status) ~= "number"
      or value.status < 100 or value.status > 599 then
    local problem = M.transport_problem(
      "result-invalid",
      "Result invalid",
      502,
      "The AG-UI stream contained an invalid operation result.",
      false
    )
    return problem.status, problem
  end
  if value.status >= 400 then
    if M.is_problem(value.problem) and value.problem.status == value.status then
      return value.status, value.problem
    end
    local problem = M.transport_problem(
      "problem-missing",
      "Problem missing",
      502,
      "The AG-UI stream reported a failed run without its required Problem Details.",
      false
    )
    return problem.status, problem
  end
  if value.problem ~= nil then
    local problem = M.transport_problem(
      "result-invalid",
      "Result invalid",
      502,
      "The AG-UI stream contained an invalid operation result.",
      false
    )
    return problem.status, problem
  end
  return value.status, nil
end

local unreachable_exit = { [5] = true, [6] = true, [7] = true, [28] = true }

-- Run one turn through the bridge. `on_event(e)` fires per AG-UI event (on the
-- main loop, via vim.schedule); `on_done(code)` when the stream ends. Returns the
-- vim.system handle — handle:kill() aborts (the bridge cancels the loop on hangup).
function M.input(run)
  local messages = run.messages
  if messages == nil and run.prompt ~= nil then
    messages = { { id = new_id("message"), role = "user", content = run.prompt } }
  end
  if messages == nil then messages = empty_array() end
  return {
    threadId = run.threadId,
    runId = run.runId or new_id("run"),
    state = vim.empty_dict(),
    tools = empty_array(),
    context = empty_array(),
    messages = messages,
    resume = run.resume,
    -- The workspace (world) is REQUIRED — a run has no existence without one. The client
    -- resolves ONE workspace name and IS its threadId (one conversation per world until
    -- #366 splits them); send it verbatim, never letting the module forge one.
    forwardedProps = { plurnk = vim.tbl_extend("force", { workspace = run.threadId }, run.forwardedProps or {}) },
  }
end

function M.run(target, run, on_event, on_done)
  local body = vim.json.encode(M.input(run))
  local args = { "curl", "-sN", "-X", "POST", target.url .. "/" }
  vim.list_extend(args, auth_headers(target))
  vim.list_extend(args, { "-d", body })
  local buffer, transport_failure, handle = "", nil, nil
  local saw_bytes, saw_event = false, false
  local function decode_http_problem()
    if not buffer:match("^%s*{") then return false end
    local okp, value = pcall(vim.json.decode, buffer, { luanil = { object = true, array = true } })
    if not okp or not M.is_problem(value) then
      return false
    end
    transport_failure = value
    buffer = ""
    return true
  end
  local function consume(eof)
    local okp, events, rest = pcall(M.parse_sse, buffer, eof)
    if not okp then
      transport_failure = M.transport_problem(
        "invalid-event-stream",
        "Invalid event stream",
        502,
        "The daemon returned an AG-UI event stream that could not be decoded.",
        false
      )
      buffer = ""
      return false
    end
    buffer = rest
    for _, e in ipairs(events) do
      saw_event = true
      vim.schedule(function() on_event(e) end)
    end
    return true
  end
  handle = vim.system(args, {
    stdout = function(err, data)
      if transport_failure ~= nil or data == nil then return end
      if err ~= nil then
        transport_failure = M.transport_problem(
          "stream-read-failed",
          "Event stream read failed",
          502,
          "The AG-UI event stream could not be read.",
          false
        )
        vim.schedule(function() if handle ~= nil then handle:kill() end end)
        return
      end
      saw_bytes = saw_bytes or #data > 0
      buffer = buffer .. data
      if not consume(false) then vim.schedule(function() if handle ~= nil then handle:kill() end end) end
    end,
  }, function(res)
    if transport_failure == nil and not decode_http_problem() then consume(true) end
    if transport_failure == nil and not saw_event then
      if not saw_bytes and unreachable_exit[res.code] == true then
        transport_failure = M.client_problem(
          "connection",
          "refused",
          "Refused",
          503,
          "No Plurnk daemon is listening at " .. tostring(target.url) .. ".",
          "transport",
          true
        )
      else
        transport_failure = M.transport_problem(
          "event-stream-empty",
          "Event stream empty",
          502,
          "The AG-UI endpoint returned no events.",
          false
        )
      end
    end
    vim.schedule(function() on_done(res.code, transport_failure) end)
  end)
  return handle
end

-- Answer a stopped-world client interaction: the standard AG-UI resume on a NEW
-- run, addressed by the opaque `int:<interactionId>` tool-call id. The payload is
-- the standard answer ({ action = "accept", content = ... }); "cancel" sends the
-- standard cancellation.
function M.resolve_interaction(target, thread_id, interaction_id, payload, on_event, on_done)
  local interrupt_id = "int:" .. tostring(interaction_id)
  local resume
  if payload == "cancel" then
    resume = { { interruptId = interrupt_id, status = "cancelled" } }
  else
    resume = { { interruptId = interrupt_id, status = "resolved", payload = payload } }
  end
  return M.run(target, { threadId = thread_id, resume = resume }, on_event, on_done)
end

-- Answer a stopped-world proposal: the standard AG-UI resume on a NEW run. The
-- continued loop streams there — feed its
-- events through the same on_event/on_done as the original run.
function M.resolve(target, r, on_event, on_done)
  local interrupt_id = "prop:" .. tostring(r.logEntryId)
  local resume
  if r.decision == "cancel" then
    resume = { { interruptId = interrupt_id, status = "cancelled" } }
  else
    local payload = { decision = r.decision }
    if r.body ~= nil then payload.body = r.body end
    resume = { { interruptId = interrupt_id, status = "resolved", payload = payload } }
  end
  return M.run(target, {
    threadId = r.threadId,
    resume = resume,
  }, on_event, on_done)
end

-- Consume one action segment. A proposal-confirmed interrupt is a successful
-- segment boundary, not a completed action; the caller owns the logical
-- action across the later resume segment.
function M.action_segment(target, run, cb, on_event)
  local result, failure, terminal = nil, nil, nil
  local has_result, saw_run_error = false, false
  return M.run(target, run, function(e)
    if type(e) == "table" and e.type == "CUSTOM" and e.name == "plurnk.action.result" then
      local v = e.value
      if type(v) == "table" and type(v.kind) == "string" and v.kind ~= "" and v.ok == true then
        has_result = true
        result = v.result
      elseif type(v) == "table" and type(v.kind) == "string" and v.kind ~= ""
          and v.ok == false and M.is_problem(v.problem) then
        failure = v.problem
      else
        failure = M.client_problem(
          "action",
          "result-invalid",
          "Result invalid",
          502,
          "The AG-UI action result did not satisfy the Plurnk action-result contract.",
          "action-result",
          false
        )
      end
      return
    end
    if type(e) == "table" and e.type == "CUSTOM" and e.name == "plurnk.problem"
        and type(e.value) == "table" then
      failure = e.value
    elseif type(e) == "table" and e.type == "RUN_FINISHED" then
      terminal = e.outcome
    elseif type(e) == "table" and e.type == "RUN_ERROR" then
      saw_run_error = true
    end
    if on_event then on_event(e) end
  end, function(code, transport_error)
    if transport_error ~= nil then
      failure = transport_error
    elseif saw_run_error and failure == nil then
      failure = M.transport_problem(
        "problem-missing",
        "Problem missing",
        502,
        "The AG-UI stream reported a failed run without its required Problem Details.",
        false
      )
    elseif not has_result and failure == nil
        and not (type(terminal) == "table" and terminal.type == "interrupt") then
      local kind = type(run.forwardedProps) == "table"
          and type(run.forwardedProps.action) == "table"
          and tostring(run.forwardedProps.action.kind)
          or "unknown"
      failure = M.client_problem(
        "action",
        "result-missing",
        "Result missing",
        502,
        "Action '" .. kind .. "' ended without a plurnk.action.result event.",
        "action-result",
        false
      )
    end
    if failure ~= nil then
      cb({ state = "failed", problem = failure, code = code })
    elseif type(terminal) == "table" and terminal.type == "interrupt" then
      cb({ state = "interrupted", outcome = terminal, code = code })
    else
      cb({ state = "complete", result = result, code = code })
    end
  end)
end

-- A verb begins as an action run. Its callback receives this segment's state;
-- bridge.lua keeps interrupted actions alive until their resume completes.
function M.rpc(target, thread_id, method, params, cb, on_event)
  return M.action_segment(target, {
    threadId = thread_id,
    messages = {},
    forwardedProps = { action = vim.tbl_extend("force", { kind = method }, params or {}) },
  }, cb, on_event)
end

function M.resume_action(target, r, cb, on_event)
  local interrupt_id = "prop:" .. tostring(r.logEntryId)
  local resume
  if r.decision == "cancel" then
    resume = { { interruptId = interrupt_id, status = "cancelled" } }
  else
    local payload = { decision = r.decision }
    if r.body ~= nil then payload.body = r.body end
    resume = { { interruptId = interrupt_id, status = "resolved", payload = payload } }
  end
  return M.action_segment(target, {
    threadId = r.threadId,
    resume = resume,
  }, cb, on_event)
end

return M
