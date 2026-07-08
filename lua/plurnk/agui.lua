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
      local okp, decoded = pcall(vim.json.decode, data)
      if okp then events[#events + 1] = decoded end
    end
  end
  return events, rest
end

-- Un-project one AG-UI event → the daemon notification shape dispatch.lua already
-- routes ({ method, params }), or nil to drop it. The family client renders from
-- the CUSTOM plurnk.* events; core AG-UI events (TEXT_MESSAGE/THINKING/TOOL_CALL/
-- STEP/STATE_DELTA/RUN_*) are for generic frontends and are dropped. plurnk.row IS
-- the wire entry, plurnk.terminated the loop/terminated payload, etc.
function M.unproject(e)
  if type(e) ~= "table" or e.type ~= "CUSTOM" then return nil end
  local name, v = e.name, e.value
  if name == "plurnk.row" then return { method = "log/entry", params = { entry = v } } end
  if name == "plurnk.terminated" then return { method = "loop/terminated", params = v } end
  if name == "plurnk.proposal" then return { method = "loop/proposal", params = v } end
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
    messages = { { role = "user", content = run.prompt } },
    forwardedProps = run.forwardedProps ~= nil and { plurnk = run.forwardedProps } or nil,
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

-- One-shot POST returning the parsed JSON body (or nil). cb runs on the main loop.
local function post_json(target, path, body, cb)
  local args = { "curl", "-s", "-X", "POST", target.url .. path }
  vim.list_extend(args, auth_headers(target))
  vim.list_extend(args, { "-d", body })
  vim.system(args, { text = true }, function(res)
    local parsed = nil
    if res.code == 0 and type(res.stdout) == "string" and #res.stdout > 0 then
      local okp, decoded = pcall(vim.json.decode, res.stdout)
      if okp then parsed = decoded end
    end
    vim.schedule(function() cb(parsed, res.code) end)
  end)
end

-- Answer a stopped-world proposal (POST /resolve → loop.resolve).
function M.resolve(target, r, cb)
  local body = vim.json.encode({ threadId = r.threadId, logEntryId = r.logEntryId, decision = r.decision, body = r.body })
  post_json(target, "/resolve", body, function(_, code) if cb then cb(code) end end)
end

-- The management escape hatch: a daemon JSON-RPC method scoped to the thread's
-- session (POST /plurnk/rpc). cb(result) with the daemon's result verbatim.
function M.rpc(target, thread_id, method, params, cb)
  local body = vim.json.encode({ threadId = thread_id, method = method, params = params or vim.empty_dict() })
  post_json(target, "/plurnk/rpc", body, function(parsed) if cb then cb(parsed ~= nil and parsed.result or nil) end end)
end

return M
