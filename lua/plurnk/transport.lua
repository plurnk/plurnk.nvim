-- JSON-RPC transport over headless nvim background process.

local M = {}
local Job = require("plenary.job")
local cfg = require("plurnk.config")
local state = require("plurnk.state")

local background_job = nil
local is_initialized = false
local init_pending = false
local pending_queue = {}
local last_requests = {}

-- Normalize server data at the JSON boundary.
-- vim.NIL → nil, \r stripped from strings.
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

M.log = function(msg)
  local f = io.open(cfg.get("log_path"), "a")
  if f then
    f:write(os.date("%Y-%m-%d %H:%M:%S ") .. msg .. "\n")
    f:flush()
    f:close()
  end
end

M.normalize = normalize

local function start_background_job()
  if background_job then return end
  local dispatch = require("plurnk.dispatch")
  local script_path = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h") .. "/background_client.lua"
  background_job = Job:new({
    command = vim.v.progpath,
    args = { "--headless", "-u", "NONE", "--noplugin", "-c", "luafile " .. script_path },
    env = vim.tbl_extend("force", vim.fn.environ(), {
      LUA_PATH = package.path,
      LUA_CPATH = package.cpath,
      PLURNK_HOST = cfg.get("host"),
      PLURNK_PORT = tostring(cfg.get("port")),
      PLURNK_LOG_PATH = cfg.get("background_log_path"),
    }),
    on_stdout = function(_, line)
      if not line or line == "" then return end
      M.log("RECV: " .. line)
      local decode_ok, payload = pcall(vim.json.decode, line)
      if not decode_ok or not payload or payload.jsonrpc ~= "2.0" then return end

      payload = normalize(payload)

      if payload.id then
        local req_meta = last_requests[payload.id]
        local result = payload.result
        if req_meta and result then
          M.log("DISPATCH response: method=" .. tostring(req_meta.method):upper() .. " id=" .. tostring(payload.id))
          is_initialized = true
          init_pending = false
          vim.schedule(function() M.flush_queue() end)

          local ok, err = pcall(dispatch.handle_response, req_meta, result)
          if not ok then M.log("HANDLER ERROR (response): " .. tostring(err)) end

          if req_meta.callback then
            vim.schedule(function()
              local cb_ok, cb_err = pcall(req_meta.callback, result)
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
    end,
    on_stderr = function(_, line)
      if not line or line == "" or line:match("^E%d+:") or line:match("deadly signal") or line:match("Nvim: Finished") or line:match("^From Nvim:") or line:match("^Valid frame received") then return end
      vim.schedule(function() vim.notify("Plurnk Background Error: " .. line, vim.log.levels.ERROR) end)
    end,
    on_exit = function(_, code)
      background_job = nil
      is_initialized = false
      init_pending = false
      vim.schedule(function()
        if code and code ~= 0 and code ~= 143 and code ~= 129 then
          M.log("Background process exited with code " .. tostring(code) .. " — will reconnect on next command")
          state.set_run_status("disconnected")
          state.set_run_status_text("Server disconnected")
          vim.notify("Rummy: disconnected — will reconnect on next command", vim.log.levels.WARN)
        else
          state.set_run_status(nil)
          state.set_run_status_text(nil)
        end
        vim.cmd("redrawstatus! | redrawtabline")
      end)
    end,
  })
  background_job:start()
end

M.send = function(method, params, is_notification, callback)
  state.mark_interacted()
  start_background_job()
  local request = { jsonrpc = "2.0", method = method, params = params or {} }
  if not is_notification then
    local id = method .. "-" .. vim.fn.strftime("%Y%m%d%H%M%S") .. tostring(math.random(1000, 9999))
    request.id = id
    last_requests[id] = { method = method:upper(), prompt = params.prompt, callback = callback }
  end
  local json = vim.json.encode(request)
  M.log("SEND: " .. json)
  if not is_initialized and method ~= "rummy/hello" then
    table.insert(pending_queue, json)
    require("plurnk.client").init_project()
    return
  end
  if background_job then background_job:send(json .. "\n") end
end

M.send_async = function(method, params, is_notification)
  vim.schedule(function() M.send(method, params, is_notification) end)
end

M.flush_queue = function()
  if not background_job then return end
  while #pending_queue > 0 do
    background_job:send(table.remove(pending_queue, 1) .. "\n")
  end
end

M.stop = function()
  if background_job then
    background_job:shutdown()
    background_job = nil
    is_initialized = false
    init_pending = false
    pending_queue = {}
  end
end

M.reset_connection = function()
  init_pending = false
  is_initialized = false
  pending_queue = {}
end

M.init_project = function()
  if init_pending or is_initialized then return end
  init_pending = true
  local project_path = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  state.set_project_path(project_path)
  M.send("rummy/hello", {
    name = vim.fn.fnamemodify(project_path, ":p:h:t"),
    projectRoot = project_path,
    clientVersion = "2.0.0",
  })
end

return M
