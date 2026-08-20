-- Thin client projection of daemon-owned workspace MCP management.

local M = {}
local arguments_of = require("plurnk.arguments").parse

local function read_options(path)
  local client = require("plurnk.client")
  local abs = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  if vim.fn.filereadable(abs) == 0 then
    client.notify(":AI/mcp — options not readable: " .. abs, vim.log.levels.WARN)
    return nil
  end
  local read_ok, lines = pcall(vim.fn.readfile, abs)
  if not read_ok then
    client.notify(":AI/mcp — options not readable: " .. abs, vim.log.levels.WARN)
    return nil
  end
  local decode_ok, options = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decode_ok then
    client.notify(":AI/mcp — options are not valid JSON: " .. abs, vim.log.levels.WARN)
    return nil
  end
  return options
end

local function server_line(server)
  local alias = type(server) == "table" and type(server.alias) == "string" and server.alias or "(unnamed)"
  local state = type(server) == "table" and type(server.state) == "string" and server.state or "unknown"
  local transport = type(server) == "table" and type(server.transport) == "string" and server.transport or "unknown"
  local target = type(server) == "table" and type(server.target) == "string" and ("  " .. server.target) or ""
  local available = type(server) == "table" and type(server.tools) == "table" and #server.tools or nil
  local enabled = type(server) == "table" and type(server.enabledTools) == "table" and #server.enabledTools or nil
  local count = nil
  if enabled ~= nil then
    count = available == nil and tostring(enabled) or string.format("%d/%d", enabled, available)
  elseif available ~= nil then
    count = tostring(available)
  end
  local tools = count ~= nil and ("  " .. count .. " tools") or ""
  return string.format("%s  %s  %s%s%s", alias, state, transport, target, tools)
end

local function notify_mutation(result, verb, alias_hint)
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
      "complete: :AI/mcp oauth " .. alias_hint .. " <callback-url>",
    }, "\n"), vim.log.levels.INFO)
    return
  end
  local server = type(result.server) == "table" and result.server or nil
  local alias = server and type(server.alias) == "string" and server.alias or alias_hint
  local state = server and type(server.state) == "string" and (" (" .. server.state .. ")") or ""
  client.notify(verb .. ": " .. alias .. state, vim.log.levels.INFO)
end

local function usage()
  require("plurnk.client").notify(
    "usage: :AI/mcp [add <alias> <target> [options.json] | enable|disable|remove <alias> | oauth <alias> <callback-url>]",
    vim.log.levels.WARN
  )
end

-- JSON decoding is local; normalization, MCP behavior, persistence, and
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

  local argv = arguments_of(raw)
  if argv == nil or #argv == 0 then usage(); return end
  local command, alias = argv[1], argv[2]

  if command == "add" then
    if #argv < 3 or #argv > 4 or alias == "" or argv[3] == "" then
      client.notify("usage: :AI/mcp add <alias> <target> [options.json]", vim.log.levels.WARN)
      return
    end
    local options = argv[4] ~= nil and read_options(argv[4]) or nil
    if argv[4] ~= nil and options == nil then return end
    local params = { alias = alias, target = argv[3] }
    if options ~= nil then params.options = options end
    return with_workspace(function()
      client.send("workspace.mcp.add", params, false, function(result)
        notify_mutation(result, "added", alias)
      end)
    end)
  end

  if command == "enable" or command == "disable" then
    if #argv ~= 2 or alias == "" then
      client.notify("usage: :AI/mcp " .. command .. " <alias>", vim.log.levels.WARN)
      return
    end
    return with_workspace(function()
      client.send("workspace.mcp." .. command, { alias = alias }, false, function(result)
        notify_mutation(result, command == "enable" and "enabled" or "disabled", alias)
      end)
    end)
  end

  if command == "remove" then
    if #argv ~= 2 or alias == "" then
      client.notify("usage: :AI/mcp remove <alias>", vim.log.levels.WARN)
      return
    end
    return with_workspace(function()
      client.send("workspace.mcp.remove", { alias = alias }, false, function(result)
        if type(result) == "table" then client.notify("removed: " .. alias, vim.log.levels.INFO) end
      end)
    end)
  end

  if command == "oauth" then
    if #argv ~= 3 or alias == "" or argv[3] == "" then
      client.notify("usage: :AI/mcp oauth <alias> <callback-url>", vim.log.levels.WARN)
      return
    end
    return with_workspace(function()
      client.send("workspace.mcp.oauth.complete", { alias = alias, callbackUrl = argv[3] }, false, function(result)
        notify_mutation(result, "authorized", alias)
      end)
    end)
  end

  usage()
end

M.complete = function(cmdline)
  local options_partial = cmdline:match("/mcp%s+add%s+%S+%s+%S+%s+(%S*)$")
  if options_partial then return vim.fn.getcompletion(options_partial, "file") end

  local partial = cmdline:match("/mcp%s+(%S*)$")
  if not partial then return nil end
  local out = {}
  for _, subcommand in ipairs({ "add", "enable", "disable", "remove", "oauth" }) do
    if vim.startswith(subcommand, partial) then out[#out + 1] = subcommand end
  end
  table.sort(out)
  return out
end

return M
