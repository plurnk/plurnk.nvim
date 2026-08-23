-- Thin client projection of the daemon-owned MCP Functionality family: one
-- common lifecycle (list | discover | add | enable | disable | remove) plus the
-- MCP OAuth continuation. The client composes exact definitions and renders
-- the daemon's states; it owns no lifecycle policy.

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
  if not decode_ok or type(options) ~= "table" then
    client.notify(":AI/mcp — options are not a valid JSON object: " .. abs, vim.log.levels.WARN)
    return nil
  end
  return options
end

-- An absolute HTTP(S) target selects Streamable HTTP; anything else is one
-- exact stdio executable. Options are the closed McpServerOptions supplement.
M.compose_definition = function(alias, target, options)
  local definition = { name = alias }
  for key, value in pairs(options or {}) do definition[key] = value end
  if target:match("^https?://") then
    definition.transport = "http"
    definition.url = target
    return definition
  end
  definition.transport = "stdio"
  definition.command = target
  if type(definition.args) ~= "table" then definition.args = {} end
  return definition
end

local function target_of(definition)
  if type(definition) ~= "table" then return nil end
  if definition.transport == "http" and type(definition.url) == "string" then return definition.url end
  if definition.transport == "stdio" and type(definition.command) == "string" then return definition.command end
  return nil
end

local function definition_line(entry)
  entry = type(entry) == "table" and entry or {}
  local alias = type(entry.alias) == "string" and entry.alias or "(unnamed)"
  local state = type(entry.state) == "string" and entry.state or "unknown"
  local definition = type(entry.definition) == "table" and entry.definition or {}
  local transport = type(definition.transport) == "string" and definition.transport or "unknown"
  local target = target_of(definition)
  local enabled = type(definition.tools) == "table" and #definition.tools or nil
  local detail = type(entry.detail) == "table" and entry.detail or {}
  local available = type(detail.tools) == "table" and #detail.tools or nil
  local count = nil
  if enabled ~= nil then
    count = available == nil and tostring(enabled) or string.format("%d/%d", enabled, available)
  elseif available ~= nil then
    count = tostring(available)
  end
  local problem = type(entry.problem) == "table" and type(entry.problem.detail) == "string" and ("  — " .. entry.problem.detail) or ""
  return string.format(
    "%s  %s  %s%s%s%s%s",
    alias,
    state,
    transport,
    target ~= nil and ("  " .. target) or "",
    count ~= nil and ("  " .. count .. " tools") or "",
    entry.origin == "service" and "  (service)" or "",
    problem
  )
end

local function candidate_line(candidate)
  candidate = type(candidate) == "table" and candidate or {}
  local alias = type(candidate.alias) == "string" and candidate.alias or "(unnamed)"
  local definition = type(candidate.definition) == "table" and candidate.definition or {}
  local transport = type(definition.transport) == "string" and definition.transport or "unknown"
  local target = target_of(definition)
  return string.format("%s  candidate  %s%s", alias, transport, target ~= nil and ("  " .. target) or "")
end

local function notify_mutation(result, verb, alias_hint)
  if type(result) ~= "table" then return end
  local client = require("plurnk.client")
  local alias = type(result.alias) == "string" and result.alias or alias_hint
  local definition = type(result.definition) == "table" and result.definition or {}
  if result.status == 202 then
    local url = type(definition.authorization) == "table" and definition.authorization.url or nil
    if type(url) ~= "string" then
      client.notify("MCP authorization response omitted its URL", vim.log.levels.WARN)
      return
    end
    client.notify(table.concat({
      "authorization required: " .. url,
      "complete: :AI/mcp oauth " .. alias .. " <callback-url>",
    }, "\n"), vim.log.levels.INFO)
    return
  end
  local state = type(definition.state) == "string" and (" (" .. definition.state .. ")") or ""
  client.notify(verb .. ": " .. alias .. state, vim.log.levels.INFO)
end

local function usage()
  require("plurnk.client").notify(
    "usage: :AI/mcp [discover <url|command> | add <alias> <target> [options.json] | enable|disable|remove <alias> | oauth <alias> <callback-url>]",
    vim.log.levels.WARN
  )
end

local function notify_candidates(result)
  local client = require("plurnk.client")
  if type(result) ~= "table" or type(result.candidates) ~= "table" then return end
  if #result.candidates == 0 then
    client.notify("MCP candidates: none", vim.log.levels.INFO)
    return
  end
  local lines = {}
  for _, candidate in ipairs(result.candidates) do lines[#lines + 1] = candidate_line(candidate) end
  client.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

-- JSON decoding is local; definition semantics, MCP behavior, persistence, and
-- protocol compatibility stay at the daemon boundary.
M.run = function(args, with_workspace)
  local raw = vim.fn.trim(args or "")
  local client = require("plurnk.client")

  if raw == "" then
    return with_workspace(function()
      client.send("worker.mcp.list", {}, false, function(result)
        if type(result) ~= "table" or type(result.definitions) ~= "table" then return end
        if #result.definitions == 0 then
          client.notify("MCP servers: none", vim.log.levels.INFO)
          return
        end
        local lines = {}
        for _, entry in ipairs(result.definitions) do lines[#lines + 1] = definition_line(entry) end
        client.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
      end)
    end)
  end

  local argv = arguments_of(raw)
  if argv == nil or #argv == 0 then usage(); return end
  local command, alias = argv[1], argv[2]

  if command == "discover" then
    if #argv ~= 2 or alias == "" then
      client.notify("usage: :AI/mcp discover <url|command>", vim.log.levels.WARN)
      return
    end
    return with_workspace(function()
      client.send("worker.mcp.discover", { source = alias }, false, notify_candidates)
    end)
  end

  if command == "add" then
    if #argv < 3 or #argv > 4 or alias == "" or argv[3] == "" then
      client.notify("usage: :AI/mcp add <alias> <target> [options.json]", vim.log.levels.WARN)
      return
    end
    local options = argv[4] ~= nil and read_options(argv[4]) or nil
    if argv[4] ~= nil and options == nil then return end
    local params = { alias = alias, definition = M.compose_definition(alias, argv[3], options) }
    return with_workspace(function()
      client.send("worker.mcp.add", params, false, function(result)
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
      client.send("worker.mcp." .. command, { alias = alias }, false, function(result)
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
      client.send("worker.mcp.remove", { alias = alias }, false, function(result)
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
      client.send("worker.mcp.oauth.complete", { alias = alias, callbackUrl = argv[3] }, false, function(result)
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
  for _, subcommand in ipairs({ "add", "discover", "enable", "disable", "remove", "oauth" }) do
    if vim.startswith(subcommand, partial) then out[#out + 1] = subcommand end
  end
  table.sort(out)
  return out
end

return M
