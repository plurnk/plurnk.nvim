-- Thin client projection of the daemon-owned Agent Skills Functionality
-- family: the common lifecycle (list | discover | add | enable | disable |
-- remove) over the Worker's `skills` actions. The client composes exact
-- definitions and renders the daemon's states; it runs no package manager,
-- reads no registry, and keeps no parallel package metadata.

local M = {}
local arguments_of = require("plurnk.arguments").parse

-- A package reference (owner/repo, URL, or path) is a source; anything else
-- is a registry query.
M.is_source = function(term)
  return term:find("[/\\:]") ~= nil or vim.startswith(term, ".") or vim.startswith(term, "~")
end

local function definition_line(entry)
  entry = type(entry) == "table" and entry or {}
  local definition = type(entry.definition) == "table" and entry.definition or {}
  local detail = type(entry.detail) == "table" and entry.detail or {}
  local alias = type(entry.alias) == "string" and entry.alias or "(unnamed)"
  local state = type(entry.state) == "string" and entry.state or "unknown"
  local scope = type(definition.scope) == "string" and definition.scope or "unknown"
  local problem = type(entry.problem) == "table" and type(entry.problem.detail) == "string" and ("  — " .. entry.problem.detail) or ""
  return string.format(
    "%s  %s  %s%s%s%s%s",
    alias,
    state,
    scope,
    type(definition.source) == "string" and ("  " .. definition.source) or "",
    type(detail.description) == "string" and ("  " .. detail.description) or "",
    entry.origin == "worker" and "  (worker)" or "",
    problem
  )
end

local function candidate_line(candidate)
  candidate = type(candidate) == "table" and candidate or {}
  local definition = type(candidate.definition) == "table" and candidate.definition or {}
  local provenance = type(candidate.provenance) == "table" and candidate.provenance or {}
  return string.format(
    "%s  candidate%s%s%s",
    type(candidate.alias) == "string" and candidate.alias or "(unnamed)",
    type(definition.source) == "string" and ("  " .. definition.source) or "",
    type(candidate.summary) == "string" and ("  " .. candidate.summary) or "",
    type(provenance.reference) == "string" and ("  " .. provenance.reference) or ""
  )
end

local function notify_mutation(result, verb, alias_hint)
  if type(result) ~= "table" then return end
  local client = require("plurnk.client")
  local alias = type(result.alias) == "string" and result.alias or alias_hint
  local definition = type(result.definition) == "table" and result.definition or {}
  local state = type(definition.state) == "string" and (" (" .. definition.state .. ")") or ""
  local problem = type(definition.problem) == "table" and type(definition.problem.detail) == "string" and ("  — " .. definition.problem.detail) or ""
  client.notify(verb .. ": " .. alias .. state .. problem, vim.log.levels.INFO)
end

local function usage()
  require("plurnk.client").notify(
    "usage: :AI/skills [discover <query|source> | add <name> <source> [--global] | enable|disable|remove <name>]",
    vim.log.levels.WARN
  )
end

M.run = function(args, with_workspace)
  local raw = vim.fn.trim(args or "")
  local client = require("plurnk.client")

  if raw == "" then
    return with_workspace(function()
      client.send("worker.skills.list", {}, false, function(result)
        if type(result) ~= "table" or type(result.definitions) ~= "table" then return end
        if #result.definitions == 0 then
          client.notify("Agent Skills: none", vim.log.levels.INFO)
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
  local command, name = argv[1], argv[2]

  if command == "discover" or command == "find" then
    local terms = {}
    for index = 2, #argv do terms[#terms + 1] = argv[index] end
    local term = vim.fn.trim(table.concat(terms, " "))
    if term == "" then
      client.notify("usage: :AI/skills discover <query|source>", vim.log.levels.WARN)
      return
    end
    local query = (#argv == 2 and M.is_source(term)) and { source = term } or { query = term }
    return with_workspace(function()
      client.send("worker.skills.discover", query, false, function(result)
        if type(result) ~= "table" or type(result.candidates) ~= "table" then return end
        if #result.candidates == 0 then
          client.notify("Skill candidates: none", vim.log.levels.INFO)
          return
        end
        local lines = {}
        for _, candidate in ipairs(result.candidates) do lines[#lines + 1] = candidate_line(candidate) end
        client.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
      end)
    end)
  end

  if command == "add" then
    local positional, global = {}, false
    for index = 2, #argv do
      if argv[index] == "--global" then global = true else positional[#positional + 1] = argv[index] end
    end
    if #positional ~= 2 or positional[1] == "" or positional[2] == "" then
      client.notify("usage: :AI/skills add <name> <source> [--global]", vim.log.levels.WARN)
      return
    end
    local alias, source = positional[1], positional[2]
    local params = { alias = alias, definition = { name = alias, scope = global and "global" or "project", source = source } }
    return with_workspace(function()
      client.send("worker.skills.add", params, false, function(result)
        notify_mutation(result, "added", alias)
      end)
    end)
  end

  if command == "enable" or command == "disable" then
    if #argv ~= 2 or name == "" then
      client.notify("usage: :AI/skills " .. command .. " <name>", vim.log.levels.WARN)
      return
    end
    return with_workspace(function()
      client.send("worker.skills." .. command, { alias = name }, false, function(result)
        notify_mutation(result, command == "enable" and "enabled" or "disabled", name)
      end)
    end)
  end

  if command == "remove" then
    if #argv ~= 2 or name == "" then
      client.notify("usage: :AI/skills remove <name>", vim.log.levels.WARN)
      return
    end
    return with_workspace(function()
      client.send("worker.skills.remove", { alias = name }, false, function(result)
        if type(result) == "table" then client.notify("removed: " .. name, vim.log.levels.INFO) end
      end)
    end)
  end

  usage()
end

M.complete = function(cmdline)
  local partial = cmdline:match("/skills%s+(%S*)$")
  if not partial then return nil end
  local out = {}
  for _, subcommand in ipairs({ "add", "discover", "enable", "disable", "remove" }) do
    if vim.startswith(subcommand, partial) then out[#out + 1] = subcommand end
  end
  table.sort(out)
  return out
end

return M
