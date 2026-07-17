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

-- Pure SSE frame extraction: split an accumulated buffer into decoded `data:`
-- JSON values + the incomplete tail (a chunk can split a frame). Bridge frames
-- are `data: <json>\n\n`. Unit-testable without curl or a bridge.
function M.parse_sse(buffer)
  local events, rest = {}, buffer
  while true do
    local sep = rest:find("\n\n", 1, true)
    if not sep then break end
    local frame = rest:sub(1, sep - 1)
    rest = rest:sub(sep + 2)
    local data = frame:match("^data: (.*)")
    if data then
      local okp, decoded = pcall(vim.json.decode, data, { luanil = { object = true, array = true } })
      if okp then events[#events + 1] = decoded end
    end
  end
  return events, rest
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
function M.run(target, run, on_event, on_done)
  local body = vim.json.encode({
    threadId = run.threadId,
    runId = run.runId,
    -- omit when empty: vim.json.encode({}) emits an OBJECT, and RunAgentInput.messages
    -- must be an array or absent (the module tolerates absent).
    messages = run.messages or (run.prompt ~= nil and { { role = "user", content = run.prompt } } or nil),
    -- The workspace (world) is REQUIRED — a run has no existence without one. The client
    -- resolves ONE workspace name and IS its threadId (one conversation per world until
    -- #366 splits them); send it verbatim, never letting the module forge one.
    forwardedProps = { plurnk = vim.tbl_extend("force", { workspace = run.threadId }, run.forwardedProps or {}) },
  })
  local args = { "curl", "-sN", "-X", "POST", target.url .. "/" }
  vim.list_extend(args, auth_headers(target))
  vim.list_extend(args, { "-d", body })
  local buffer = ""
  return vim.system(args, {
    stdout = function(err, data)
      if err ~= nil or data == nil then return end
      buffer = buffer .. data
      local events, rest = M.parse_sse(buffer)
      buffer = rest
      for _, e in ipairs(events) do
        vim.schedule(function() on_event(e) end)
      end
    end,
  }, function(res)
    vim.schedule(function() on_done(res.code) end)
  end)
end

-- Answer a stopped-world proposal: the AG-UI+ resume run. The decision rides a
-- tool-result message on a NEW run; the continued loop streams there — feed its
-- events through the same on_event/on_done as the original run.
function M.resolve(target, r, on_event, on_done)
  local content = vim.json.encode({ decision = r.decision, body = r.body })
  return M.run(target, {
    threadId = r.threadId,
    messages = { { role = "tool", toolCallId = "prop:" .. tostring(r.logEntryId), content = content } },
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
  end, function(_)
    if cb then cb(result, errmsg) end
  end)
end

return M
