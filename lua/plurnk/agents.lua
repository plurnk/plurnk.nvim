-- Thin client projection of the daemon-owned outbound A2A agents Functionality
-- family: the common lifecycle (list | discover | add | enable | disable |
-- remove) over the Worker's `agents` actions. The client composes exact
-- A2aAgentDefinitions and renders the daemon's states; card discovery,
-- connection, and enablement policy live in the service.

local M = {}
local arguments_of = require("plurnk.arguments").parse

local function read_options(path)
  local client = require("plurnk.client")
  local abs = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  if vim.fn.filereadable(abs) == 0 then
    client.notify(":AI/agents — options not readable: " .. abs, vim.log.levels.WARN)
    return nil
  end
  local read_ok, lines = pcall(vim.fn.readfile, abs)
  if not read_ok then
    client.notify(":AI/agents — options not readable: " .. abs, vim.log.levels.WARN)
    return nil
  end
  local decode_ok, options = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decode_ok or type(options) ~= "table" then
    client.notify(":AI/agents — options are not a valid JSON object: " .. abs, vim.log.levels.WARN)
    return nil
  end
  return options
end

-- The alias is the definition's name and `a2a://` authority; options supply
-- the remaining A2aAgentDefinition members (cardPath, headers, authorization).
M.compose_definition = function(alias, url, options)
  local definition = { name = alias, url = url }
  for key, value in pairs(options or {}) do definition[key] = value end
  return definition
end

local function definition_line(entry)
  entry = type(entry) == "table" and entry or {}
  local definition = type(entry.definition) == "table" and entry.definition or {}
  local detail = type(entry.detail) == "table" and entry.detail or {}
  local version = type(detail.version) == "string" and detail.version ~= "" and (" v" .. detail.version) or ""
  local problem = type(entry.problem) == "table" and type(entry.problem.detail) == "string" and ("  — " .. entry.problem.detail) or ""
  return string.format(
    "%s  %s%s%s%s%s%s",
    type(entry.alias) == "string" and entry.alias or "(unnamed)",
    type(entry.state) == "string" and entry.state or "unknown",
    type(definition.url) == "string" and ("  " .. definition.url) or "",
    type(detail.name) == "string" and ("  " .. detail.name .. version) or "",
    type(detail.skills) == "table" and ("  " .. #detail.skills .. " skills") or "",
    entry.origin == "service" and "  (service)" or "",
    problem
  )
end

local function candidate_line(candidate)
  candidate = type(candidate) == "table" and candidate or {}
  local definition = type(candidate.definition) == "table" and candidate.definition or {}
  return string.format(
    "%s  candidate%s%s",
    type(candidate.alias) == "string" and candidate.alias or "(unnamed)",
    type(definition.url) == "string" and ("  " .. definition.url) or "",
    type(candidate.summary) == "string" and ("  " .. candidate.summary) or ""
  )
end

local function notify_mutation(result, verb, alias_hint)
  if type(result) ~= "table" then return end
  require("plurnk.functionality").invalidate_aliases("agents")
  local client = require("plurnk.client")
  local alias = type(result.alias) == "string" and result.alias or alias_hint
  local definition = type(result.definition) == "table" and result.definition or {}
  local state = type(definition.state) == "string" and (" (" .. definition.state .. ")") or ""
  local problem = type(definition.problem) == "table" and type(definition.problem.detail) == "string" and ("  — " .. definition.problem.detail) or ""
  client.notify(verb .. ": " .. alias .. state .. problem, vim.log.levels.INFO)
end

local function usage(subcommand)
  local exact = require("plurnk.command_registry").usage("agents", subcommand)
  require("plurnk.client").notify(
    "usage: :AI" .. exact,
    vim.log.levels.WARN
  )
end

M.run = function(args, with_workspace)
  local raw = vim.fn.trim(args or "")
  local client = require("plurnk.client")

  if raw == "" then
    return with_workspace(function()
      client.send("worker.agents.list", {}, false, function(result)
        if type(result) ~= "table" or type(result.definitions) ~= "table" then return end
        require("plurnk.functionality").remember_aliases("agents", result.definitions)
        if #result.definitions == 0 then
          client.notify("A2A agents: none", vim.log.levels.INFO)
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
      client.send("worker.agents.discover", { source = alias }, false, function(result)
        if type(result) ~= "table" or type(result.candidates) ~= "table" then return end
        if #result.candidates == 0 then
          client.notify("Agent candidates: none", vim.log.levels.INFO)
          return
        end
        local lines = {}
        for _, candidate in ipairs(result.candidates) do lines[#lines + 1] = candidate_line(candidate) end
        client.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
      end)
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
      client.send("worker.agents.add", params, false, function(result)
        notify_mutation(result, "added", alias)
      end)
    end)
  end

  if command == "enable" or command == "disable" then
    if #argv ~= 2 or alias == "" then
      usage(command)
      return
    end
    return with_workspace(function()
      client.send("worker.agents." .. command, { alias = alias }, false, function(result)
        notify_mutation(result, command == "enable" and "enabled" or "disabled", alias)
      end)
    end)
  end

  if command == "remove" then
    if #argv ~= 2 or alias == "" then
      usage("remove")
      return
    end
    return with_workspace(function()
      client.send("worker.agents.remove", { alias = alias }, false, function(result)
        if type(result) == "table" then
          require("plurnk.functionality").invalidate_aliases("agents")
          client.notify("removed: " .. alias, vim.log.levels.INFO)
        end
      end)
    end)
  end

  usage()
end

return M
