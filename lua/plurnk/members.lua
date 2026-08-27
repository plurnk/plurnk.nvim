-- Thin client projection of the daemon-owned file members Functionality
-- family: the common lifecycle (list | discover | add | enable | disable |
-- remove) over the Worker's `members` actions. Git-tracked files are members
-- on their own; a definition is one gitignore-style glob that includes
-- untracked files or, with a leading `!`, excludes members. The client
-- composes exact definitions and renders the daemon's states; resolution, the
-- model's ceiling, and enablement policy live in the service.

local M = {}
local arguments_of = require("plurnk.arguments").parse

local function count(n, noun)
  return string.format("%d %s%s", n, noun, n == 1 and "" or "s")
end

-- `!glob` excludes matching members; anything else includes matching files.
local function effect_of(glob)
  if vim.startswith(glob, "!") then return "exclude", glob:sub(2) end
  return "include", glob
end

local function resolution(effect, detail)
  if type(detail.matched) ~= "number" then return "" end
  if effect == "exclude" then return " → " .. count(detail.matched, "member") end
  local ignored = type(detail.ignored) == "number" and detail.ignored > 0 and (" (" .. detail.ignored .. " ignored)") or ""
  return " → " .. count(detail.matched, "file") .. ignored
end

-- The vim move: a bare `discover` asks about the file in the current buffer.
M.current_file = function()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or name:match("^%a[%w+.-]*://") or vim.bo.buftype ~= "" then return nil end
  return require("plurnk.state").get_relative_path(vim.fn.fnamemodify(name, ":p"))
end

local function definition_line(entry)
  entry = type(entry) == "table" and entry or {}
  local definition = type(entry.definition) == "table" and entry.definition or {}
  local detail = type(entry.detail) == "table" and entry.detail or {}
  local effect, pattern = effect_of(type(definition.glob) == "string" and definition.glob or "unknown")
  local problem = type(entry.problem) == "table" and type(entry.problem.detail) == "string" and ("  — " .. entry.problem.detail) or ""
  return string.format(
    "%s  %s  %s %s%s%s%s",
    type(entry.alias) == "string" and entry.alias or "(unnamed)",
    type(entry.state) == "string" and entry.state or "unknown",
    effect,
    pattern,
    resolution(effect, detail),
    entry.origin == "service" and "  (service)" or "",
    problem
  )
end

local function candidate_line(candidate)
  candidate = type(candidate) == "table" and candidate or {}
  local definition = type(candidate.definition) == "table" and candidate.definition or {}
  local provenance = type(candidate.provenance) == "table" and candidate.provenance or {}
  return string.format(
    "%s  %s%s%s",
    type(candidate.alias) == "string" and candidate.alias or "(unnamed)",
    type(provenance.kind) == "string" and provenance.kind or "candidate",
    type(definition.glob) == "string" and ("  " .. definition.glob) or "",
    type(candidate.summary) == "string" and ("  " .. candidate.summary) or ""
  )
end

local function notify_mutation(result, verb, alias_hint, workspace_name)
  if type(result) ~= "table" then return end
  require("plurnk.functionality").invalidate_aliases("members")
  local client = require("plurnk.client")
  local alias = type(result.alias) == "string" and result.alias or alias_hint
  local definition = type(result.definition) == "table" and result.definition or {}
  local state = type(definition.state) == "string" and (" (" .. definition.state .. ")") or ""
  local problem = type(definition.problem) == "table" and type(definition.problem.detail) == "string" and ("  — " .. definition.problem.detail) or ""
  client.notify(verb .. ": " .. alias .. state .. problem, vim.log.levels.INFO)
end

local function usage(subcommand)
  local exact = require("plurnk.command_registry").usage("members", subcommand)
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
      client.send("worker.members.list", {}, false, function(result)
        if type(result) ~= "table" or type(result.definitions) ~= "table" then return end
        require("plurnk.functionality").remember_aliases("members", result.definitions)
        if #result.definitions == 0 then
          client.notify("file members: none", vim.log.levels.INFO)
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
    if query == "" then query = M.current_file() end
    if query == nil or query == "" then
      usage("discover")
      return
    end
    return with_workspace(function()
      client.send("worker.members.discover", { query = query }, false, function(result)
        if type(result) ~= "table" or type(result.candidates) ~= "table" then return end
        if #result.candidates == 0 then
          client.notify("file member candidates: none", vim.log.levels.INFO)
          return
        end
        local lines = {}
        for _, candidate in ipairs(result.candidates) do lines[#lines + 1] = candidate_line(candidate) end
        client.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
      end)
    end)
  end

  if command == "add" then
    local glob = table.concat(argv, " ", 3)
    if #argv < 3 or alias == "" or glob == "" then
      usage("add")
      return
    end
    local params = { alias = alias, definition = { glob = glob } }
    return with_workspace(function(workspace_name)
      client.send("worker.members.add", params, false, function(result)
        notify_mutation(result, "added", alias, workspace_name)
      end)
    end)
  end

  if command == "enable" or command == "disable" then
    if #argv ~= 2 or alias == "" then
      usage(command)
      return
    end
    return with_workspace(function(workspace_name)
      client.send("worker.members." .. command, { alias = alias }, false, function(result)
        notify_mutation(result, command == "enable" and "enabled" or "disabled", alias, workspace_name)
      end)
    end)
  end

  if command == "remove" then
    if #argv ~= 2 or alias == "" then
      usage("remove")
      return
    end
    return with_workspace(function(workspace_name)
      client.send("worker.members.remove", { alias = alias }, false, function(result)
        if type(result) == "table" then
          require("plurnk.functionality").invalidate_aliases("members")
          client.notify("removed: " .. alias, vim.log.levels.INFO)
        end
      end)
    end)
  end

  usage()
end

return M
