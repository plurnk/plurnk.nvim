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
  require("plurnk.functionality").invalidate_aliases("mcp")
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

local function usage(subcommand)
  local exact = require("plurnk.command_registry").usage("mcp", subcommand)
  require("plurnk.client").notify(
    "usage: :AI" .. exact,
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
        require("plurnk.functionality").remember_aliases("mcp", result.definitions)
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
      usage("discover")
      return
    end
    return with_workspace(function()
      client.send("worker.mcp.discover", { source = alias }, false, notify_candidates)
    end)
  end

  if command == "add" then
    if #argv < 3 or #argv > 4 or alias == "" or argv[3] == "" then
      usage("add")
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

  if command == "enable" then
    if #argv < 2 or #argv > 3 or alias == "" then
      usage("enable")
      return
    end
    if argv[3] ~= nil then
      local options = read_options(argv[3])
      if options == nil then return end
      return with_workspace(function()
        client.send("worker.mcp.list", {}, false, function(result)
          local definitions = type(result) == "table" and result.definitions or nil
          if type(definitions) ~= "table" then return end
          require("plurnk.functionality").remember_aliases("mcp", definitions)
          local current = nil
          for _, entry in ipairs(definitions) do
            if entry.alias == alias and type(entry.definition) == "table" then current = entry.definition; break end
          end
          if current == nil then
            client.notify("MCP server '" .. alias .. "' is not available to this Worker", vim.log.levels.WARN)
            return
          end
          local definition = {}
          for key, value in pairs(current) do definition[key] = value end
          for key, value in pairs(options) do definition[key] = value end
          client.send("worker.mcp.add", { alias = alias, definition = definition }, false, function(mutation)
            notify_mutation(mutation, "added", alias)
          end)
        end)
      end)
    end
    return with_workspace(function()
      client.send("worker.mcp.enable", { alias = alias }, false, function(result)
        notify_mutation(result, "enabled", alias)
      end)
    end)
  end

  if command == "disable" then
    if #argv ~= 2 or alias == "" then usage("disable"); return end
    return with_workspace(function()
      client.send("worker.mcp.disable", { alias = alias }, false, function(result)
        notify_mutation(result, "disabled", alias)
      end)
    end)
  end

  if command == "remove" then
    if #argv ~= 2 or alias == "" then
      usage("remove")
      return
    end
    return with_workspace(function()
      client.send("worker.mcp.remove", { alias = alias }, false, function(result)
        if type(result) == "table" then
          require("plurnk.functionality").invalidate_aliases("mcp")
          client.notify("removed: " .. alias, vim.log.levels.INFO)
        end
      end)
    end)
  end

  if command == "oauth" then
    if #argv ~= 3 or alias == "" or argv[3] == "" then
      usage("oauth")
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

return M
