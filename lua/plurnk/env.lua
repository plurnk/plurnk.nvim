-- Thin client projection of the daemon-owned environment Functionality
-- family: the common lifecycle (list | discover | add | enable | disable |
-- remove) over the Worker's `env` actions. The family is worker-scoped — an
-- environment is how one Worker's commands run, not a workspace capability —
-- so its actions are `worker.env.*` and the bridge binds the active Worker.
-- `list` is what this Worker's commands receive: the ambient names the
-- operator's ceiling admits (service origin) and the Worker's own entries
-- (worker origin, inherited entries naming the Worker that set them). A
-- definition is one exact { value }, used verbatim; the client hands the rest
-- of the line over as typed, never tokenized. Admission, the ceiling, and the
-- composition at the spawn live in the service.

local M = {}
local arguments_of = require("plurnk.arguments").parse

local function definition_line(entry)
  entry = type(entry) == "table" and entry or {}
  local definition = type(entry.definition) == "table" and entry.definition or {}
  local problem = type(entry.problem) == "table" and type(entry.problem.detail) == "string" and ("  — " .. entry.problem.detail) or ""
  return string.format(
    "%s  %s%s%s%s%s",
    type(entry.alias) == "string" and entry.alias or "(unnamed)",
    type(entry.state) == "string" and entry.state or "unknown",
    type(definition.value) == "string" and ("  " .. definition.value) or "",
    type(entry.inherited) == "string" and ("  (from " .. entry.inherited .. ")") or "",
    entry.origin == "service" and "  (service)" or "",
    problem
  )
end

local function candidate_line(candidate)
  candidate = type(candidate) == "table" and candidate or {}
  local definition = type(candidate.definition) == "table" and candidate.definition or {}
  local provenance = type(candidate.provenance) == "table" and candidate.provenance or {}
  return string.format(
    "%s%s%s%s",
    type(candidate.alias) == "string" and candidate.alias or "(unnamed)",
    type(provenance.source) == "string" and ("  " .. provenance.source) or "",
    type(definition.value) == "string" and definition.value ~= "" and ("  =" .. definition.value) or "",
    type(candidate.summary) == "string" and ("  " .. candidate.summary) or ""
  )
end

local function notify_mutation(result, verb, alias_hint)
  if type(result) ~= "table" then return end
  require("plurnk.functionality").invalidate_aliases("env")
  local client = require("plurnk.client")
  local alias = type(result.alias) == "string" and result.alias or alias_hint
  local definition = type(result.definition) == "table" and result.definition or {}
  local state = type(definition.state) == "string" and (" (" .. definition.state .. ")") or ""
  local problem = type(definition.problem) == "table" and type(definition.problem.detail) == "string" and ("  — " .. definition.problem.detail) or ""
  client.notify(verb .. ": " .. alias .. state .. problem, vim.log.levels.INFO)
end

local function usage(subcommand)
  local exact = require("plurnk.command_registry").usage("env", subcommand)
  require("plurnk.client").notify("usage: :AI" .. exact, vim.log.levels.WARN)
end

M.run = function(args, with_workspace)
  local raw = vim.fn.trim(args or "")
  local client = require("plurnk.client")

  if raw == "" then
    return with_workspace(function()
      client.send("worker.env.list", {}, false, function(result)
        if type(result) ~= "table" or type(result.definitions) ~= "table" then return end
        require("plurnk.functionality").remember_aliases("env", result.definitions)
        if #result.definitions == 0 then
          client.notify("environment: none", vim.log.levels.INFO)
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
    local query = table.concat(argv, " ", 2)
    return with_workspace(function()
      client.send("worker.env.discover", query == "" and {} or { query = query }, false, function(result)
        if type(result) ~= "table" or type(result.candidates) ~= "table" then return end
        if #result.candidates == 0 then
          client.notify("environment candidates: none", vim.log.levels.INFO)
          return
        end
        local lines = {}
        for _, candidate in ipairs(result.candidates) do lines[#lines + 1] = candidate_line(candidate) end
        client.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
      end)
    end)
  end

  if command == "add" then
    -- The value is the rest of the line as typed: the daemon uses it verbatim, so the client
    -- never tokenizes it.
    local name, value = raw:match("^add%s+(%S+)%s+(.-)%s*$")
    if name == nil or value == nil or value == "" then
      usage("add")
      return
    end
    return with_workspace(function()
      client.send("worker.env.add", { alias = name, definition = { value = value } }, false, function(result)
        notify_mutation(result, "added", name)
      end)
    end)
  end

  if command == "enable" or command == "disable" then
    if #argv ~= 2 or alias == "" then
      usage(command)
      return
    end
    return with_workspace(function()
      client.send("worker.env." .. command, { alias = alias }, false, function(result)
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
      client.send("worker.env.remove", { alias = alias }, false, function(result)
        if type(result) == "table" then
          require("plurnk.functionality").invalidate_aliases("env")
          client.notify("removed: " .. alias, vim.log.levels.INFO)
        end
      end)
    end)
  end

  usage()
end

return M
