-- The nvim bridge transport (nvim#65 phase 2/3) — mirrors the client's
-- BridgeTransport. When PLURNK_AGUI_URL is set, runs ride agui.run (curl -N SSE)
-- with each event un-projected into the SAME dispatch.handle_notification the WS
-- path feeds, so the worker-tab renders unchanged; verbs + resolve ride the
-- management + resolve endpoints. The threadId IS the workspace (workspace) name,
-- verbatim — no prefix, no forging (module §agui-thread-is-run: the workspace is the
-- world, the thread binds its model worker); workspace options ride the first run's forwardedProps.
local M = {}
local agui = require("plurnk.agui")

-- AG-UI+ IS the client surface: default http://PLURNK_HOST:PLURNK_PORT (the
-- daemon's in-process module); PLURNK_AGUI_URL stays an explicit remote override.
function M.target()
  local url = vim.env.PLURNK_AGUI_URL
  if url == nil or url == "" then
    local host = (vim.env.PLURNK_HOST ~= nil and vim.env.PLURNK_HOST ~= "") and vim.env.PLURNK_HOST or "127.0.0.1"
    local port = (vim.env.PLURNK_PORT ~= nil and vim.env.PLURNK_PORT ~= "") and vim.env.PLURNK_PORT or "3044"
    url = "http://" .. host .. ":" .. port
  end
  return { url = url, token = vim.env.PLURNK_AGUI_TOKEN }
end

function M.enabled() return true end

-- Run a prompt through the bridge. Events un-project into the dispatcher (the
-- worker-tab renders identically to WS); on_done(finalStatus). Returns the vim.system
-- handle (handle:kill() = /stop, the bridge cancels on hangup).
function M.run(thread_id, prompt, opts, on_done)
  local t = M.target()
  if t == nil then return nil end
  local dispatch = require("plurnk.dispatch")
  local final = nil   -- NO fabricated success: only loop/terminated sets it (else 502)
  local tool = {}   -- the TOOL_CALL triple assembler (terminate-resume proposals)
  local paused = false
  local on_event
  on_event = function(e)
    if type(e) == "table" and e.type == "RUN_ERROR" then final = tonumber(e.code) or 500; return end
    local n = agui.unproject(e, tool)
    if n == nil then return end
    if n.method == "loop/proposal" then paused = true end
    if n.method == "loop/terminated" then
      paused = false
      final = (type(n.params) == "table" and n.params.finalStatus) or 502
    end
    pcall(dispatch.handle_notification, n)
  end
  -- resolve.lua answers via M.resolve below; the resume run's events feed the SAME
  -- on_event/on_done, so the worker-tab renders the continuation seamlessly.
  M._active = { thread_id = thread_id, on_event = on_event, on_done = function(_)
    -- A stream that died without terminal truth is a broken wire — 502, never 200.
    if not paused and on_done then on_done(final or 502) end
  end }
  return agui.run(t, { threadId = thread_id, prompt = prompt, forwardedProps = opts and opts.forwardedProps or nil },
    on_event, M._active.on_done)
end

-- A verb is a §3 action run. cb(result); an action error surfaces as a notify —
-- honest, never silent. The action stream ALSO carries any events the dispatch
-- emits (log/entry from a client op, a proposal from a gated EXEC, stream chunks)
-- — feed them through the same unproject→dispatch path as a run, or client ops
-- would render nothing and gated ops would hang unresolved.
function M.rpc(thread_id, method, params, cb)
  local t = M.target()
  local dispatch = require("plurnk.dispatch")
  local tool = {}
  agui.rpc(t, thread_id, method, params, function(result, err)
    if err ~= nil then vim.notify("plurnk: " .. method .. " — " .. err, vim.log.levels.WARN) end
    if cb then cb(result) end
  end, function(e)
    local n = agui.unproject(e, tool)
    if n ~= nil then pcall(dispatch.handle_notification, n) end
  end)
end

-- Answer a stopped-world proposal: the tool-result resume run. The continued
-- work's events (a loop's rows OR an action's exec streams + result) ride the
-- SAME unproject→dispatch path as every other stream — a loop run's registered
-- on_done still fires so its inflight state clears.
function M.resolve(thread_id, r, cb)
  local t = M.target()
  local a = M._active
  local dispatch = require("plurnk.dispatch")
  local tool = {}
  local on_event = (a ~= nil and a.thread_id == thread_id) and a.on_event or function(e)
    local n = agui.unproject(e, tool)
    if n ~= nil then pcall(dispatch.handle_notification, n) end
  end
  local on_done = (a ~= nil and a.thread_id == thread_id) and a.on_done or function(_) end
  agui.resolve(t, vim.tbl_extend("force", { threadId = thread_id }, r), on_event, function(code)
    on_done(code)
    if cb then cb(code) end
  end)
end

return M
