-- Neovim projection of the universal Agent Skills package manager. This
-- client invokes the standard CLI directly; it does not route through the
-- terminal client or maintain a second registry/install implementation.

local M = {}
local arguments_of = require("plurnk.arguments").parse

local function notify(message, level)
  require("plurnk.client").notify(message, level)
end

local function project_root()
  local project = require("plurnk.client").get_project_path()
  if project == nil or project == "" then
    notify("skills require a workspace project root", vim.log.levels.WARN)
    return nil
  end
  return vim.fn.fnamemodify(vim.fn.expand(project), ":p"):gsub("/+$", "")
end

local function includes_any(values, choices)
  for _, value in ipairs(values) do
    for _, choice in ipairs(choices) do
      if value == choice then return true end
    end
  end
  return false
end

local function usage()
  notify(table.concat({
    "usage: :AI/skills [list [--global]]",
    "       :AI/skills add <source> [--skill <name> ...] [--global]",
    "       :AI/skills remove <name> ... [--global]",
    "       :AI/skills find <query>",
    "       :AI/skills update [name ...] [--global]",
  }, "\n"), vim.log.levels.WARN)
end

local function append(target, values)
  for _, value in ipairs(values) do target[#target + 1] = value end
end

local function plain(value)
  return (value:gsub("\27%[[0-?]*[ -/]*[@-~]", ""))
end

local function command_arguments(parts)
  if #parts == 0 then return { "list", "--agent", "universal" } end
  for _, part in ipairs(parts) do
    if part == "--agent" or part == "-a" or vim.startswith(part, "--agent=") then return nil end
  end

  local command = parts[1]
  local rest = {}
  for index = 2, #parts do rest[#rest + 1] = parts[index] end
  local out = {}
  if command == "list" or command == "ls" then
    out = { "list" }
    append(out, rest)
    append(out, { "--agent", "universal" })
  elseif command == "add" or command == "install" then
    if #rest == 0 or includes_any(rest, { "--all" }) then return nil end
    out = { "add" }
    append(out, rest)
    append(out, { "--agent", "universal", "--yes" })
  elseif command == "remove" or command == "rm" then
    if #rest == 0 then return nil end
    out = { "remove" }
    append(out, rest)
    append(out, { "--agent", "universal", "--yes" })
  elseif command == "find" or command == "search" then
    if #rest == 0 then return nil end
    out = { "find" }
    append(out, rest)
  elseif command == "update" or command == "upgrade" then
    out = { "update" }
    append(out, rest)
    if not includes_any(rest, { "--global", "-g", "--project", "-p" }) then
      out[#out + 1] = "--project"
    end
    out[#out + 1] = "--yes"
  else
    return nil
  end
  return out
end

local function report(result)
  local sections = {}
  if type(result.stdout) == "string" and vim.trim(result.stdout) ~= "" then
    sections[#sections + 1] = vim.trim(plain(result.stdout))
  end
  if type(result.stderr) == "string" and vim.trim(result.stderr) ~= "" then
    sections[#sections + 1] = vim.trim(plain(result.stderr))
  end
  local output = table.concat(sections, "\n")
  if result.code == 0 then
    notify(output ~= "" and output or "skills: done", vim.log.levels.INFO)
  else
    local message = "Agent Skills command failed (exit " .. tostring(result.code) .. ")"
    notify(output == "" and message or (message .. "\n" .. output), vim.log.levels.WARN)
  end
end

M.complete = function(cmdline)
  local partial = cmdline:match("/skills%s+(%S*)$")
  if not partial then return nil end
  local out = {}
  for _, subcommand in ipairs({ "add", "find", "list", "remove", "update" }) do
    if vim.startswith(subcommand, partial) then out[#out + 1] = subcommand end
  end
  table.sort(out)
  return out
end

M.run = function(args)
  local root = project_root()
  if root == nil then return nil end
  local parts = arguments_of(vim.fn.trim(args or ""))
  local command = parts ~= nil and command_arguments(parts) or nil
  if command == nil then
    usage()
    return nil
  end

  local argv = { "npx", "--yes", "skills" }
  append(argv, command)
  return vim.system(argv, { cwd = root, text = true, env = { NO_COLOR = "1" } }, function(result)
    vim.schedule(function() report(result) end)
  end)
end

return M
