-- Thin operator projection of workspace Agent Skills management. The client
-- reads and writes the workspace's skills/ directory directly; the daemon
-- republishes the worker://plurnk/skills/ surface on its next refresh, so
-- changes are discoverable by the model from the following turn.

local M = {}

local function notify(message, level)
  require("plurnk.client").notify(message, level)
end

local function skills_dir()
  local client = require("plurnk.client")
  local project = client.get_project_path()
  if project == nil or project == "" then
    notify("skills require a workspace project root", vim.log.levels.WARN)
    return nil
  end
  local base = vim.fn.fnamemodify(vim.fn.expand(project), ":p"):gsub("/+$", "")
  return base .. "/skills"
end

local function valid_name(name)
  return name ~= nil and name:match("^[A-Za-z0-9][A-Za-z0-9._-]*$") ~= nil
end

local function frontmatter(raw)
  local name, description = nil, nil
  if raw[1] == "---" then
    for index = 2, #raw do
      local line = raw[index]:gsub("%s+$", "")
      if line == "---" then break end
      local key, value = line:match("^(%a+):%s*(.*)$")
      if key == "name" and value ~= "" then name = value end
      if key == "description" and value ~= "" then description = value end
    end
  end
  return name, description
end

local function list(dir)
  local folders = vim.fn.glob(dir .. "/*", false, true)
  if #folders == 0 then
    notify("skills: none", vim.log.levels.INFO)
    return
  end
  local lines = {}
  for _, folder in ipairs(folders) do
    if vim.fn.isdirectory(folder) == 1 then
      local read_ok, raw = pcall(vim.fn.readfile, folder .. "/SKILL.md")
      local name, description = nil, nil
      if read_ok then name, description = frontmatter(raw) end
      local label = name or vim.fn.fnamemodify(folder, ":t")
      lines[#lines + 1] = description == nil and label or (label .. " — " .. description)
    end
  end
  notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

local function add(dir, name, path)
  if name == "" or path == "" then
    notify("usage: :AI/skills add <name> <path-to-SKILL.md>", vim.log.levels.WARN)
    return
  end
  if not valid_name(name) then
    notify("skill name '" .. name .. "' must match [A-Za-z0-9][A-Za-z0-9._-]*", vim.log.levels.WARN)
    return
  end
  local source = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  if vim.fn.filereadable(source) == 0 then
    notify("skills file not readable: " .. source, vim.log.levels.WARN)
    return
  end
  vim.fn.mkdir(dir .. "/" .. name, "p")
  local write_ok, write_err = pcall(vim.fn.writefile, vim.fn.readfile(source, "b"), dir .. "/" .. name .. "/SKILL.md", "b")
  if not write_ok then
    notify("skills write failed: " .. tostring(write_err), vim.log.levels.WARN)
    return
  end
  notify("added: " .. name, vim.log.levels.INFO)
end

local function remove(dir, name)
  if name == "" then
    notify("usage: :AI/skills remove <name>", vim.log.levels.WARN)
    return
  end
  if not valid_name(name) then
    notify("skill name '" .. name .. "' must match [A-Za-z0-9][A-Za-z0-9._-]*", vim.log.levels.WARN)
    return
  end
  if vim.fn.isdirectory(dir .. "/" .. name) == 0 then
    notify("skills: no skill named " .. name, vim.log.levels.INFO)
    return
  end
  vim.fn.delete(dir .. "/" .. name, "rf")
  notify("removed: " .. name, vim.log.levels.INFO)
end

M.complete = function(cmdline)
  local file_partial = cmdline:match("/skills%s+add%s+%S+%s+(%S*)$")
  if file_partial then return vim.fn.getcompletion(file_partial, "file") end
  local partial = cmdline:match("/skills%s+(%S*)$")
  if not partial then return nil end
  local out = {}
  for _, subcommand in ipairs({ "add", "remove" }) do
    if vim.startswith(subcommand, partial) then out[#out + 1] = subcommand end
  end
  table.sort(out)
  return out
end

M.run = function(args)
  local dir = skills_dir()
  if dir == nil then return end
  local raw = vim.fn.trim(args or "")
  local parts = vim.fn.split(raw, "\\s\\+")
  if #parts == 0 then
    list(dir)
    return
  end
  local command = parts[1]
  if command == "add" then
    add(dir, parts[2] or "", parts[3] or "")
  elseif command == "remove" then
    remove(dir, parts[2] or "")
  else
    notify("usage: :AI/skills [add <name> <path-to-SKILL.md> | remove <name>]", vim.log.levels.WARN)
  end
end

return M
