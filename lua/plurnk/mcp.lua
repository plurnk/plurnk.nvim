-- Thin client projection of daemon-owned workspace MCP management.

local M = {}

local function read_definition(path)
  local client = require("plurnk.client")
  local abs = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  if vim.fn.filereadable(abs) == 0 then
    client.notify(":AI/mcp — definition not readable: " .. abs, vim.log.levels.WARN)
    return nil
  end
  local read_ok, lines = pcall(vim.fn.readfile, abs)
  if not read_ok then
    client.notify(":AI/mcp — definition not readable: " .. abs, vim.log.levels.WARN)
    return nil
  end
  local decode_ok, definition = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decode_ok then
    client.notify(":AI/mcp — definition is not valid JSON: " .. abs, vim.log.levels.WARN)
    return nil
  end
  return definition
end

local function definition_name(definition)
  return type(definition) == "table" and type(definition.name) == "string"
      and definition.name or "<name>"
end

local function server_line(server)
  local name = type(server) == "table" and type(server.name) == "string" and server.name or "(unnamed)"
  local state = type(server) == "table" and type(server.state) == "string" and server.state or "unknown"
  local transport = type(server) == "table" and type(server.transport) == "string" and server.transport or "unknown"
  local tools = type(server) == "table" and type(server.tools) == "table"
      and string.format("  %d tool%s", #server.tools, #server.tools == 1 and "" or "s") or ""
  return string.format("%s  %s  %s%s", name, state, transport, tools)
end

local function notify_mutation(result, verb, name_hint)
  if type(result) ~= "table" then return end
  local client = require("plurnk.client")
  if result.status == 202 then
    local url = type(result.authorization) == "table" and result.authorization.url or nil
    if type(url) ~= "string" then
      client.notify("MCP authorization response omitted its URL", vim.log.levels.WARN)
      return
    end
    client.notify(table.concat({
      "authorization required: " .. url,
      "complete: :AI/mcp oauth " .. name_hint .. " <callback-url>",
    }, "\n"), vim.log.levels.INFO)
    return
  end
  local server = type(result.server) == "table" and result.server or nil
  local name = server and type(server.name) == "string" and server.name or name_hint
  local state = server and type(server.state) == "string" and (" (" .. server.state .. ")") or ""
  client.notify(verb .. ": " .. name .. state, vim.log.levels.INFO)
end

-- JSON decoding is local; definition semantics, MCP behavior, persistence, and
-- protocol compatibility stay at the daemon boundary.
M.run = function(args, with_workspace)
  local raw = vim.fn.trim(args or "")
  local client = require("plurnk.client")

  if raw == "" then
    return with_workspace(function()
      client.send("workspace.mcp.list", {}, false, function(result)
        if type(result) ~= "table" or type(result.servers) ~= "table" then return end
        if #result.servers == 0 then
          client.notify("MCP servers: none", vim.log.levels.INFO)
          return
        end
        local lines = {}
        for _, server in ipairs(result.servers) do lines[#lines + 1] = server_line(server) end
        client.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
      end)
    end)
  end

  if raw == "replace" or vim.startswith(raw, "replace ") then
    local path = vim.fn.trim(raw:sub(#"replace" + 1))
    if path == "" then
      client.notify("usage: :AI/mcp replace <definition.json>", vim.log.levels.WARN)
      return
    end
    local server = read_definition(path)
    if server == nil then return end
    return with_workspace(function()
      client.send("workspace.mcp.replace", { server = server }, false, function(result)
        notify_mutation(result, "replaced", definition_name(server))
      end)
    end)
  end

  for _, action in ipairs({ "detach", "reconnect" }) do
    local operation = action
    if raw == operation or vim.startswith(raw, operation .. " ") then
      local name = vim.fn.trim(raw:sub(#operation + 1))
      if name == "" or name:find("%s") then
        client.notify("usage: :AI/mcp " .. operation .. " <name>", vim.log.levels.WARN)
        return
      end
      return with_workspace(function()
        client.send("workspace.mcp." .. operation, { name = name }, false, function(result)
          if operation == "detach" then
            if type(result) == "table" then client.notify("detached: " .. name, vim.log.levels.INFO) end
          else
            notify_mutation(result, "reconnected", name)
          end
        end)
      end)
    end
  end

  if raw == "oauth" or vim.startswith(raw, "oauth ") then
    local name, callback_url = raw:match("^oauth%s+(%S+)%s+(%S+)$")
    if not name then
      client.notify("usage: :AI/mcp oauth <name> <callback-url>", vim.log.levels.WARN)
      return
    end
    return with_workspace(function()
      client.send("workspace.mcp.oauth.complete", { name = name, callbackUrl = callback_url }, false, function(result)
        notify_mutation(result, "authorized", name)
      end)
    end)
  end

  local server = read_definition(raw)
  if server == nil then return end
  return with_workspace(function()
    client.send("workspace.mcp.attach", { server = server }, false, function(result)
      notify_mutation(result, "attached", definition_name(server))
    end)
  end)
end

M.complete = function(cmdline)
  local replace_partial = cmdline:match("/mcp%s+replace%s+(%S*)$")
  if replace_partial then return vim.fn.getcompletion(replace_partial, "file") end

  local partial = cmdline:match("/mcp%s+(%S*)$")
  if not partial then return nil end
  local out = vim.fn.getcompletion(partial, "file")
  for _, subcommand in ipairs({ "replace", "detach", "reconnect", "oauth" }) do
    if vim.startswith(subcommand, partial) then out[#out + 1] = subcommand end
  end
  table.sort(out)
  return out
end

return M
