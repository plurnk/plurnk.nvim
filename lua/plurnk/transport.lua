-- JSON-RPC 2.0 transport over a headless background nvim subprocess.
-- Architecture (same as rummy.nvim):
--   main nvim  <-stdio JSON-RPC->  background headless nvim  <-WebSocket->  daemon
-- The background nvim holds the WebSocket via vim.loop/libuv; main nvim
-- never touches the socket.
--
-- v0.1.2: dropped plenary.nvim. Modern nvim (>= 0.10) has vim.system as
-- a built-in; one less dependency for users, smoke-test trivial.
--
-- v0.1.2: dropped the rummy/hello handshake. Plurnk has no such
-- handshake — sends are issued immediately on connection-ready; no
-- init-pending gate.

local M = {}
local cfg = require("plurnk.config")

local background_proc = nil  -- the vim.system handle
local pending_queue = {}     -- requests queued before subprocess is up
local last_requests = {}     -- id -> { method, callback } for response routing
local stdout_buf = ""        -- partial line carry-over for stdout

-- Normalize server data at the JSON boundary.
-- vim.NIL -> nil, \r stripped from strings.
local function normalize(val)
  if val == vim.NIL then return nil end
  if type(val) == "string" then return val:gsub("\r", "") end
  if type(val) == "table" then
    local out = {}
    for k, v in pairs(val) do out[k] = normalize(v) end
    return out
  end
  return val
end

M.normalize = normalize

M.log = function(msg)
  local f = io.open(cfg.get("log_path"), "a")
  if f then
    f:write(os.date("%Y-%m-%d %H:%M:%S ") .. msg .. "\n")
    f:flush()
    f:close()
  end
end

local function process_line(line)
  if not line or line == "" then return end
  M.log("RECV: " .. line)
  local decode_ok, payload = pcall(vim.json.decode, line)
  if not decode_ok or not payload or payload.jsonrpc ~= "2.0" then return end
  payload = normalize(payload)

  local dispatch = require("plurnk.dispatch")

  if payload.id ~= nil then
    local req_meta = last_requests[payload.id]
    last_requests[payload.id] = nil
    if req_meta and payload.result then
      M.log("DISPATCH response: method=" .. tostring(req_meta.method) .. " id=" .. tostring(payload.id))
      local ok, err = pcall(dispatch.handle_response, req_meta, payload.result)
      if not ok then M.log("HANDLER ERROR (response): " .. tostring(err)) end
      if req_meta.callback then
        vim.schedule(function()
          local cb_ok, cb_err = pcall(req_meta.callback, payload.result)
          if not cb_ok then M.log("CALLBACK ERROR: " .. tostring(cb_err)) end
        end)
      end
    end
  end

  if payload.method then
    vim.schedule(function()
      local ok, err = pcall(dispatch.handle_notification, payload)
      if not ok then M.log("HANDLER ERROR (notification): " .. tostring(err)) end
    end)
  end

  if payload.error then
    pcall(dispatch.handle_error, payload)
  end
end

-- Stdout from the subprocess arrives in arbitrary chunks. Split on \n,
-- carrying over any partial trailing line until the next chunk.
local function feed_stdout(data)
  if not data or data == "" then return end
  stdout_buf = stdout_buf .. data
  while true do
    local nl = stdout_buf:find("\n", 1, true)
    if not nl then break end
    local line = stdout_buf:sub(1, nl - 1)
    stdout_buf = stdout_buf:sub(nl + 1)
    pcall(process_line, line)
  end
end

local function start_background_proc()
  if background_proc then return end
  local script_path = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h") .. "/background_client.lua"
  local env = vim.tbl_extend("force", vim.fn.environ(), {
    LUA_PATH = package.path,
    LUA_CPATH = package.cpath,
    PLURNK_HOST = cfg.get("host"),
    PLURNK_PORT = tostring(cfg.get("port")),
    PLURNK_LOG_PATH = cfg.get("background_log_path"),
  })
  -- Translate env from { K=V table } to { "K=V", ... } list — vim.system
  -- accepts both but the list form is what its docs guarantee.
  local env_list = {}
  for k, v in pairs(env) do env_list[#env_list+1] = k .. "=" .. tostring(v) end

  background_proc = vim.system(
    { vim.v.progpath, "--headless", "-u", "NONE", "--noplugin", "-c", "luafile " .. script_path },
    {
      stdin = true,
      env = env_list,
      stdout = vim.schedule_wrap(function(_, data)
        if data then feed_stdout(data) end
      end),
      stderr = vim.schedule_wrap(function(_, data)
        if not data or data == "" then return end
        for line in (data .. "\n"):gmatch("([^\n]*)\n") do
          if line ~= "" and not line:match("^E%d+:") and not line:match("deadly signal")
             and not line:match("^From Nvim:") and not line:match("^Valid frame received") then
            vim.notify("Plurnk Background: " .. line, vim.log.levels.WARN)
          end
        end
      end),
    },
    vim.schedule_wrap(function(obj)
      background_proc = nil
      stdout_buf = ""
      last_requests = {}
      if obj.code ~= 0 and obj.code ~= 143 and obj.code ~= 129 then
        M.log("Background subprocess exited code=" .. tostring(obj.code) .. " — will reconnect on next send")
      end
    end)
  )

  -- Flush anything queued during boot.
  vim.defer_fn(function() M.flush_queue() end, 50)
end

local function next_id()
  return string.format("%d-%d", vim.loop.hrtime(), math.random(1000, 9999))
end

M.send = function(method, params, is_notification, callback)
  start_background_proc()
  local request = { jsonrpc = "2.0", method = method, params = params or {} }
  if not is_notification then
    local id = next_id()
    request.id = id
    last_requests[id] = { method = method, callback = callback }
  end
  local json = vim.json.encode(request)
  M.log("SEND: " .. json)
  if not background_proc then
    table.insert(pending_queue, json)
    return
  end
  -- vim.system's write may not be available immediately after spawn —
  -- queue and flush on first stdout (or defer_fn above).
  local ok = pcall(function() background_proc:write(json .. "\n") end)
  if not ok then table.insert(pending_queue, json) end
end

M.send_async = function(method, params, is_notification)
  vim.schedule(function() M.send(method, params, is_notification) end)
end

M.flush_queue = function()
  if not background_proc then return end
  while #pending_queue > 0 do
    local item = table.remove(pending_queue, 1)
    local ok = pcall(function() background_proc:write(item .. "\n") end)
    if not ok then table.insert(pending_queue, 1, item); break end
  end
end

M.stop = function()
  if background_proc then
    pcall(function() background_proc:kill(15) end)
    background_proc = nil
    pending_queue = {}
    last_requests = {}
    stdout_buf = ""
  end
end

M.reset_connection = function()
  pending_queue = {}
  last_requests = {}
end

return M
