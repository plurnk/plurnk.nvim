-- The nvim bridge transport (nvim#65 phase 2/3) — mirrors the client's
-- BridgeTransport. When PLURNK_AGUI_URL is set, runs ride agui.run (curl -N SSE)
-- with each event un-projected into the SAME dispatch.handle_notification the WS
-- path feeds, so the run-tab renders unchanged; verbs + resolve ride the
-- management + resolve endpoints. The threadId is the session name (the bridge
-- lazy-creates agui-<threadId>); session options ride the first run's forwardedProps.
local M = {}
local agui = require("plurnk.agui")

-- The bridge target from the env, or nil when unset (WS path stays authoritative).
function M.target()
  local url = vim.env.PLURNK_AGUI_URL
  if url == nil or url == "" then return nil end
  return { url = url, token = vim.env.PLURNK_AGUI_TOKEN }
end

function M.enabled() return M.target() ~= nil end

-- Run a prompt through the bridge. Events un-project into the dispatcher (the
-- run-tab renders identically to WS); on_done(finalStatus). Returns the vim.system
-- handle (handle:kill() = /stop, the bridge cancels on hangup).
function M.run(thread_id, prompt, opts, on_done)
  local t = M.target()
  if t == nil then return nil end
  local dispatch = require("plurnk.dispatch")
  local final = 200
  return agui.run(t, { threadId = thread_id, prompt = prompt, forwardedProps = opts and opts.forwardedProps or nil },
    function(e)
      if type(e) == "table" and e.type == "RUN_ERROR" then final = tonumber(e.code) or 500; return end
      local n = agui.unproject(e)
      if n == nil then return end
      if n.method == "loop/terminated" then final = (type(n.params) == "table" and n.params.finalStatus) or final end
      pcall(dispatch.handle_notification, n)
    end,
    function(_code) if on_done then on_done(final) end end)
end

-- The management escape hatch (session.*, providers, op.*, run.fork, …).
function M.rpc(thread_id, method, params, cb)
  local t = M.target()
  if t ~= nil then agui.rpc(t, thread_id, method, params, cb) end
end

-- Answer a stopped-world proposal.
function M.resolve(thread_id, r, cb)
  local t = M.target()
  if t ~= nil then agui.resolve(t, vim.tbl_extend("force", { threadId = thread_id }, r), cb) end
end

return M
