-- Background script run via nvim --headless
-- Uses Neovim's native vim.loop (libuv) for robust TCP/WebSocket
-- Communicates via JSON-RPC 2.0

local PLURNK_HOST = os.getenv("PLURNK_HOST") or "127.0.0.1"
local PLURNK_PORT = tonumber(os.getenv("PLURNK_PORT")) or 3044
local PLURNK_LOG_PATH = os.getenv("PLURNK_LOG_PATH") or "/tmp/plurnk_background.log"

local log_file = io.open(PLURNK_LOG_PATH, "a")
local function log(msg)
  if log_file then
    log_file:write(os.date("%Y-%m-%d %H:%M:%S ") .. msg .. "\n")
    log_file:flush()
  end
end

local function emit_error(msg)
  local ok, err = pcall(function()
    local safe_msg = msg:gsub('"', '\\"')
    io.stdout:write('{"jsonrpc":"2.0","error":{"code":-32000,"message":"' .. safe_msg .. '"}}\n')
    io.stdout:flush()
  end)
  if not ok then log("Failed to emit error to nvim: " .. tostring(err)) end
end

log("Background client starting (libuv improved mode)...")

local uv = vim.loop
local bit = require("bit")
local tcp = nil
local is_connected = false
local handshake_done = false
local out_queue = {}
local rx_buf = ""

local function send_frame(data)
  if not tcp or not is_connected then return end
  local len = #data
  local head = string.char(0x81)
  if len <= 125 then
    head = head .. string.char(len + 128)
  elseif len <= 65535 then
    head = head .. string.char(126 + 128, math.floor(len/256), len%256)
  else
    log("Error: Data too large for simple framer")
    return
  end

  local mask = { math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255) }
  head = head .. string.char(unpack(mask))

  local masked = {}
  for i = 1, #data do
    masked[i] = string.char(bit.bxor(data:byte(i), mask[(i-1) % 4 + 1]))
  end

  tcp:write(head .. table.concat(masked))
end

local function flush_queue()
  log("Flushing queue: " .. #out_queue .. " items")
  while #out_queue > 0 do
    local item = table.remove(out_queue, 1)
    send_frame(item)
  end
end

local function process_rx_buf()
  if not handshake_done then
    local start_idx, end_idx = rx_buf:find("\r\n\r\n")
    if start_idx then
      local resp = rx_buf:sub(1, end_idx)
      rx_buf = rx_buf:sub(end_idx + 1)
      log("Received handshake response")
      if resp:match("101 Switching Protocols") then
        log("Handshake accepted")
        handshake_done = true
        flush_queue()
        -- Recursively process any data after the handshake
        process_rx_buf()
      else
        log("Handshake REJECTED:\n" .. resp)
      end
    end
    return
  end

  -- Process WebSocket frames
  while #rx_buf >= 2 do
    local b1 = rx_buf:byte(1)
    local b2 = rx_buf:byte(2)
    local opcode = bit.band(b1, 0x0F)
    local masked = bit.band(b2, 0x80) ~= 0
    local payload_len = bit.band(b2, 0x7F)
    local header_len = 2

    if payload_len == 126 then
      if #rx_buf < 4 then return end
      payload_len = bit.lshift(rx_buf:byte(3), 8) + rx_buf:byte(4)
      header_len = 4
    elseif payload_len == 127 then
      if #rx_buf < 10 then return end
      -- 64-bit len not fully implemented, assume it fits in 32-bit for now
      payload_len = bit.lshift(rx_buf:byte(7), 24) + bit.lshift(rx_buf:byte(8), 16) + bit.lshift(rx_buf:byte(9), 8) + rx_buf:byte(10)
      header_len = 10
    end

    if masked then header_len = header_len + 4 end

    if #rx_buf < header_len + payload_len then return end

    local payload = rx_buf:sub(header_len + 1, header_len + payload_len)
    rx_buf = rx_buf:sub(header_len + payload_len + 1)

    if masked then
      -- Servers shouldn't mask, but just in case
      local mask = { payload:byte(1,4) }
      local unmasked = {}
      for i=1, #payload-4 do
        unmasked[i] = string.char(bit.bxor(payload:byte(i+4), mask[(i-1)%4+1]))
      end
      payload = table.concat(unmasked)
    end

    if opcode == 0x1 or opcode == 0x2 then -- Text or Binary
      log("Valid frame received, len: " .. #payload .. " Payload: " .. payload)
      local ok, err = pcall(function()
        io.stdout:write(payload .. "\n")
        io.stdout:flush()
      end)
      if not ok then
        log("Error writing to stdout: " .. tostring(err))
      end
    elseif opcode == 0x8 then -- Close
      log("Connection closed by server opcode")
      is_connected = false
      handshake_done = false
      if tcp then
        tcp:close()
        tcp = nil
      end
      return
    end
  end
end

local function connect()
  if tcp then return end
  tcp = uv.new_tcp()
  log("Connecting to " .. PLURNK_HOST .. ":" .. PLURNK_PORT .. "...")

  tcp:connect(PLURNK_HOST, PLURNK_PORT, function(err)
    if err then
      log("Connect error: " .. err)
      emit_error("Connection failed: " .. err .. ". Is the RUMMY server running?")
      tcp:close()
      tcp = nil
      return
    end

    log("Connected. Sending handshake...")
    local key = "dGhlIHNhbXBsZSBub25jZQ=="
    local handshake = "GET / HTTP/1.1\r\n" ..
                      "Host: " .. PLURNK_HOST .. "\r\n" ..
                      "Upgrade: websocket\r\n" ..
                      "Connection: Upgrade\r\n" ..
                      "Sec-WebSocket-Key: " .. key .. "\r\n" ..
                      "Sec-WebSocket-Version: 13\r\n\r\n"

    tcp:write(handshake)
    is_connected = true

    tcp:read_start(function(read_err, data)
      if read_err or not data then
        log("Read error or closed: " .. (read_err or "EOF"))
        emit_error("Connection lost: " .. (read_err or "EOF"))
        is_connected = false
        handshake_done = false
        tcp:close()
        tcp = nil
        -- Exit so parent can detect disconnect and auto-reconnect
        os.exit(1)
        return
      end

      rx_buf = rx_buf .. data
      process_rx_buf()
    end)
  end)
end

local stdin = uv.new_pipe(false)
stdin:open(0)
stdin:read_start(function(err, data)
  if err or not data then os.exit(0) end
  for line in data:gmatch("[^\r\n]+") do
    log("From Nvim: " .. line)
    if not handshake_done then
      table.insert(out_queue, line)
      if not is_connected then
        connect()
      end
    else
      send_frame(line)
    end
  end
end)

uv.run()
