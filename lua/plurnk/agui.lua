-- The Lua consumer of the plurnk-agui bridge (nvim#65 phase 1) — the transport
-- substrate for migrating nvim off raw WS onto the exclusive portal. No fetch in
-- Lua, so the SSE run rides `curl -N` under vim.system with a streaming stdout
-- callback; the management plane + resolve are one-shot curl POSTs.
--
-- Mirrors the client's agui.ts: run() streams AG-UI events, resolve() answers a
-- stopped-world proposal, rpc() is the /plurnk/rpc escape hatch. plurnk fidelity
-- rides the CUSTOM plurnk.* events (esp. plurnk.row — the full wire row), which a
-- later phase un-projects to the daemon shapes dispatch.lua already renders.
local M = {}
local id_sequence = 0

local function new_id(prefix)
  id_sequence = id_sequence + 1
  return string.format("%s-%x-%x", prefix, vim.uv.hrtime(), id_sequence)
end

local function empty_array()
  return vim.json.decode("[]")
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

-- Un-project one AG-UI event → the daemon notification shape dispatch.lua already
-- routes ({ method, params }), or nil to drop it. AG-UI+ dialect: a stopped-world
-- proposal arrives as a request_approval/request_user_input TOOL_CALL triple (the
-- run then FINISHES; the loop stays paused in-engine — the resume is a tool-result
-- run). The assembler below folds the triple into ONE loop/proposal notification.
function M.unproject(e, tool)
  if type(e) ~= "table" then return nil end
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
    if not okp then a = {} end
    a.logEntryId = log_entry_id
    return { method = "loop/proposal", params = a }
  end
  if e.type ~= "CUSTOM" then return nil end
  local name, v = e.name, e.value
  if name == "plurnk.row" then return { method = "log/entry", params = { entry = v } } end
  if name == "plurnk.terminated" then return { method = "loop/terminated", params = v } end
  if name == "plurnk.telemetry" then return { method = "telemetry/event", params = { event = v } } end
  if name == "plurnk.stream" then
    local concluded = type(v) == "table" and v.closeStatus ~= nil
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

-- Run one turn through the bridge. `on_event(e)` fires per AG-UI event (on the
-- main loop, via vim.schedule); `on_done(code)` when the stream ends. Returns the
-- vim.system handle — handle:kill() aborts (the bridge cancels the loop on hangup).
function M.input(run)
  local messages = run.messages
  if messages == nil and run.prompt ~= nil then
    messages = { { id = new_id("message"), role = "user", content = run.prompt } }
  end
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
  local buffer, parse_error, handle = "", nil, nil
  local function consume(eof)
    local okp, events, rest = pcall(M.parse_sse, buffer, eof)
    if not okp then
      parse_error = tostring(events)
      buffer = ""
      return false
    end
    buffer = rest
    for _, e in ipairs(events) do
      vim.schedule(function() on_event(e) end)
    end
    return true
  end
  handle = vim.system(args, {
    stdout = function(err, data)
      if parse_error ~= nil or data == nil then return end
      if err ~= nil then
        parse_error = "AG-UI SSE stdout failed: " .. tostring(err)
        vim.schedule(function() if handle ~= nil then handle:kill() end end)
        return
      end
      buffer = buffer .. data
      if not consume(false) then vim.schedule(function() if handle ~= nil then handle:kill() end end) end
    end,
  }, function(res)
    if parse_error == nil then consume(true) end
    vim.schedule(function() on_done(res.code, parse_error) end)
  end)
  return handle
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

-- A verb is a §3 action run: forwardedProps.plurnk.action in, plurnk.action.result
-- out. cb(result, err) — an ok:false projects err, never a silent nil.
function M.rpc(target, thread_id, method, params, cb, on_event)
  local result, errmsg = nil, nil
  M.run(target, {
    threadId = thread_id,
    messages = {},
    forwardedProps = { action = vim.tbl_extend("force", { kind = method }, params or {}) },
  }, function(e)
    if type(e) == "table" and e.type == "CUSTOM" and e.name == "plurnk.action.result" then
      local v = e.value
      if type(v) == "table" and v.ok == true then result = v.result else errmsg = (type(v) == "table" and v.error) or "action failed" end
      return
    end
    if on_event then on_event(e) end   -- everything else the dispatch emitted rides here
  end, function(code, transport_error)
    -- A stream that ended with NEITHER a result NOR an action error never reached
    -- a daemon (curl 7 refused / 6 unresolvable / 28 timeout) — name it; a silent
    -- nil here was the old behavior and it hid the first-run moment entirely.
    if transport_error ~= nil then
      errmsg = transport_error
    elseif result == nil and errmsg == nil then
      errmsg = "no daemon listening (curl exit " .. tostring(code) .. ")"
    end
    if cb then cb(result, errmsg) end
  end)
end

return M
