-- Authoritative :AI/ command vocabulary. Routing, contextual help, completion,
-- and key descriptions all consume these records.

local M = {}

local function invoke(module, method, shape)
  return function(args)
    local fn = require(module)[method]
    if shape == "options" then return fn({ args = args }) end
    if shape == "argument" then return fn(args) end
    return fn()
  end
end

local function functionality(family)
  return function(args) return require("plurnk.functionality").run(family, args) end
end

local MCP_SUBCOMMANDS = {
  { name = "discover", usage = "discover <url|command>", summary = "Inspect one MCP source without adding it." },
  { name = "add", usage = "add <alias> <target> [options.json]", summary = "Add and enable an MCP server.", path_arg = 4 },
  { name = "enable", usage = "enable <alias> [options.json]", summary = "Enable or specialize a current MCP server.", alias = true, path_arg = 3 },
  { name = "disable", usage = "disable <alias>", summary = "Disable a current MCP server.", alias = true },
  { name = "remove", usage = "remove <alias>", summary = "Remove a current MCP server.", alias = true },
  { name = "oauth", usage = "oauth <alias> <callback-url>", summary = "Complete authorization for an MCP server.", alias = true },
}

local SKILL_SUBCOMMANDS = {
  { name = "discover", usage = "discover <query|source>", summary = "Search or inspect an Agent Skill source." },
  { name = "add", usage = "add <name> <source> [--global]", summary = "Install and enable an Agent Skill." },
  { name = "enable", usage = "enable <name>", summary = "Enable a current Agent Skill.", alias = true },
  { name = "disable", usage = "disable <name>", summary = "Disable a current Agent Skill.", alias = true },
  { name = "remove", usage = "remove <name>", summary = "Remove a current Agent Skill.", alias = true },
}

local AGENT_SUBCOMMANDS = {
  { name = "discover", usage = "discover <url>", summary = "Inspect one A2A Agent Card without adding it." },
  { name = "add", usage = "add <alias> <url> [options.json]", summary = "Add and enable an outbound A2A agent.", path_arg = 4 },
  { name = "enable", usage = "enable <alias>", summary = "Enable a current outbound A2A agent.", alias = true },
  { name = "disable", usage = "disable <alias>", summary = "Disable a current outbound A2A agent.", alias = true },
  { name = "remove", usage = "remove <alias>", summary = "Remove a current outbound A2A agent.", alias = true },
}

local MEMBERS_SUBCOMMANDS = {
  { name = "discover", usage = "discover [path|glob]", summary = "Explain a file's visibility (the current file by default), or preview what a glob would include or exclude.", path_arg = 2 },
  { name = "add", usage = "add <alias> <glob>", summary = "Add and enable a members glob; a leading ! excludes.", path_arg = 3 },
  { name = "enable", usage = "enable <alias>", summary = "Enable a current members glob.", alias = true },
  { name = "disable", usage = "disable <alias>", summary = "Disable a current members glob.", alias = true },
  { name = "remove", usage = "remove <alias>", summary = "Remove a current members glob.", alias = true },
}

local GROUPS = {
  { id = "inspect", label = "inspect" },
  { id = "policy", label = "policy" },
  { id = "workspace", label = "workspace" },
  { id = "functionality", label = "functionality" },
  { id = "compose", label = "compose" },
  { id = "review", label = "review" },
  { id = "session", label = "session" },
  { id = "editor", label = "editor" },
}

local COMMANDS = {
  { name = "help", usage = "/help [verb]", summary = "Show the command index or one command's usage.", group = "inspect",
    run = function(args) require("plurnk.language").help(args) end, completion = "commands" },
  { name = "models", usage = "/models [search]", summary = "Search the bounded model catalog.", group = "inspect",
    run = invoke("plurnk.generation", "models", "argument") },
  { name = "workspaces", usage = "/workspaces", summary = "List daemon workspaces.", group = "inspect",
    run = invoke("plurnk.workspaces", "list") },
  { name = "workers", usage = "/workers", summary = "Pick a conversation from this workspace's worker topology.", group = "inspect",
    run = invoke("plurnk.workspaces", "workers") },
  { name = "log", usage = "/log [limit]", summary = "Read recent log entries.", group = "inspect",
    run = invoke("plurnk.workspaces", "log", "options") },
  { name = "ping", usage = "/ping", summary = "Check daemon reachability.", group = "inspect",
    run = invoke("plurnk.controls", "ping") },

  { name = "model", usage = "/model [selector]", summary = "Inspect or select this worker's durable model.", group = "policy",
    run = invoke("plurnk.generation", "set_model", "argument"), completion = "model" },
  { name = "child", usage = "/child [selector|inherit]", summary = "Inspect or select the inherited child model.", group = "policy",
    run = invoke("plurnk.generation", "set_child", "argument"), completion = "child" },
  { name = "reasoning", usage = "/reasoning [policy]", summary = "Inspect or select durable reasoning policy.", group = "policy",
    run = invoke("plurnk.generation", "set_reasoning", "argument"), completion = "reasoning" },
  { name = "capabilities", usage = "/capabilities [json]", summary = "Inspect or restrict this worker's capabilities.", group = "policy",
    run = invoke("plurnk.capabilities", "run", "argument") },
  { name = "yolo", usage = "/yolo", summary = "Toggle local proposal auto-accept.", group = "policy",
    run = invoke("plurnk.controls", "yolo") },

  { name = "workspace", usage = "/workspace [name]", summary = "Create and enter a fresh workspace.", group = "workspace",
    run = invoke("plurnk.workspaces", "create", "options") },
  { name = "rename", usage = "/rename <name>", summary = "Rename this workspace's mutable handle.", group = "workspace",
    run = invoke("plurnk.workspaces", "rename", "options") },
  { name = "worker", usage = "/worker [name]", summary = "Fork and enter a new worker.", group = "workspace",
    run = invoke("plurnk.workspaces", "fork", "options") },
  { name = "attach", usage = "/attach <name>", summary = "Bind this tab to a conversation worker by name.", group = "workspace",
    run = invoke("plurnk.workspaces", "attach", "argument"), completion = "worker" },
  { name = "parent", usage = "/parent", summary = "Hop to the bound worker's parent (<leader>ah).", group = "workspace",
    run = function() require("plurnk.workspaces").hop("parent") end },
  { name = "enter", usage = "/enter", summary = "Hop into the bound worker's newest child (<leader>al).", group = "workspace",
    run = function() require("plurnk.workspaces").hop("enter") end },
  { name = "older", usage = "/older", summary = "Hop to the next older sibling worker, wrapping (<leader>aj).", group = "workspace",
    run = function() require("plurnk.workspaces").hop("next") end },
  { name = "newer", usage = "/newer", summary = "Hop to the next newer sibling worker, wrapping (<leader>ak).", group = "workspace",
    run = function() require("plurnk.workspaces").hop("prev") end },
  { name = "mcp", usage = "/mcp [subcommand]", summary = "List or manage this worker's MCP servers.", group = "functionality",
    run = functionality("mcp"), subcommands = MCP_SUBCOMMANDS },
  { name = "skills", usage = "/skills [subcommand]", summary = "List or manage this worker's Agent Skills.", group = "functionality",
    run = functionality("skills"), subcommands = SKILL_SUBCOMMANDS },
  { name = "agents", usage = "/agents [subcommand]", summary = "List or manage this worker's outbound A2A agents.", group = "functionality",
    run = functionality("agents"), subcommands = AGENT_SUBCOMMANDS },
  { name = "members", usage = "/members [subcommand]", summary = "List or manage this worker's file members.", group = "functionality",
    run = functionality("members"), subcommands = MEMBERS_SUBCOMMANDS },

  { name = "script", usage = "/script <path>", summary = "Submit a local .plk program through op.parse.", group = "compose",
    run = invoke("plurnk.controls", "script", "options"), path_arg = 1 },

  { name = "accept", usage = "/accept", summary = "Accept the pending proposal.", group = "review",
    run = invoke("plurnk.controls", "accept") },
  { name = "reject", usage = "/reject", summary = "Reject the pending proposal.", group = "review",
    run = invoke("plurnk.controls", "reject") },
  { name = "cancel", usage = "/cancel", summary = "Cancel the pending proposal.", group = "review",
    run = invoke("plurnk.controls", "cancel") },
  { name = "edit", usage = "/edit", summary = "Edit and resolve the pending proposal.", group = "review",
    run = invoke("plurnk.controls", "accept_edits") },
  { name = "next", usage = "/next", summary = "Focus the next pending proposal.", group = "review",
    run = invoke("plurnk.controls", "next") },
  { name = "prev", usage = "/prev", summary = "Focus the previous pending proposal.", group = "review",
    run = invoke("plurnk.controls", "prev") },

  { name = "stop", usage = "/stop", summary = "Cancel the running loop.", group = "session",
    run = invoke("plurnk.controls", "stop") },
  { name = "clear", usage = "/clear", summary = "Cancel activity and close the workspace tab.", group = "session",
    run = invoke("plurnk.controls", "clear") },

  { name = "open", usage = "/open", summary = "Toggle the workspace tab.", group = "editor",
    run = invoke("plurnk.workspaces", "toggle") },
  { name = "reconnect", usage = "/reconnect", summary = "Reconcile a worker after observation loss.", group = "editor",
    run = invoke("plurnk.workspaces", "reconnect") },
}

local BY_NAME = {}
for _, command in ipairs(COMMANDS) do BY_NAME[command.name] = command end

local function sorted_matching(values, prefix, project)
  local out = {}
  for _, value in ipairs(values) do
    if vim.startswith(value.name, prefix) then out[#out + 1] = project(value) end
  end
  table.sort(out)
  return out
end

local function words_of(line)
  local words = {}
  for word in line:gmatch("%S+") do words[#words + 1] = word end
  return words, line:match("%s$") ~= nil
end

function M.commands() return COMMANDS end
function M.groups() return GROUPS end
function M.get(name) return BY_NAME[name] end
function M.summary(name) return BY_NAME[name] and BY_NAME[name].summary or nil end

function M.usage(name, subcommand)
  local command = BY_NAME[name]
  if not command then return nil end
  if subcommand then
    for _, nested in ipairs(command.subcommands or {}) do
      if nested.name == subcommand then return "/" .. name .. " " .. nested.usage end
    end
  end
  return command.usage
end

function M.dispatch(name, args)
  local command = BY_NAME[name]
  if not command then return false end
  command.run(args or "")
  return true
end

function M.completion_context(cmdline)
  local line = cmdline:match("AI%s+(.*)$") or ""
  if line:sub(1, 1) ~= "/" then return nil end

  local root = line:match("^/([%w_-]*)$")
  if root then
    return {
      kind = "syntax",
      values = sorted_matching(COMMANDS, root, function(command) return "/" .. command.name end),
    }
  end

  local body = line:sub(2)
  local words, trailing = words_of(body)
  local command = BY_NAME[words[1] or ""]
  if not command then return nil end
  local current_index = trailing and (#words + 1) or #words
  local argument_index = current_index - 1
  local partial = trailing and "" or (words[#words] or "")

  if command.completion == "commands" and argument_index == 1 then
    return {
      kind = "syntax",
      values = sorted_matching(COMMANDS, partial, function(candidate) return candidate.name end),
    }
  end

  if command.subcommands and argument_index == 1 then
    return {
      kind = "syntax",
      values = sorted_matching(command.subcommands, partial, function(candidate) return candidate.name end),
    }
  end

  local subcommand = nil
  if command.subcommands then
    for _, candidate in ipairs(command.subcommands) do
      if candidate.name == words[2] then subcommand = candidate; break end
    end
  end
  if subcommand and subcommand.alias and argument_index == 2 then
    return { kind = "functionality", family = command.name, prefix = partial }
  end
  if subcommand and subcommand.path_arg == argument_index then
    return { kind = "path", prefix = partial }
  end
  if command.path_arg == argument_index then return { kind = "path", prefix = partial } end
  if command.completion and argument_index == 1 then
    return { kind = command.completion, prefix = partial }
  end
  return nil
end

local function editor_usage(usage)
  return usage:gsub("^/", ":AI/")
end

function M.render_help(name)
  local normalized = vim.fn.trim(name or ""):gsub("^/", "")
  if normalized ~= "" then
    local command = BY_NAME[normalized]
    if not command then
      return "  unknown command " .. vim.inspect(name) .. "; use :AI/help for the command index"
    end
    local lines = { "  " .. editor_usage(command.usage), "      " .. command.summary }
    for _, nested in ipairs(command.subcommands or {}) do
      lines[#lines + 1] = "  " .. editor_usage("/" .. command.name .. " " .. nested.usage)
      lines[#lines + 1] = "      " .. nested.summary
    end
    return table.concat(lines, "\n")
  end

  local lines = {
    "  :AI              toggle the workspace tab",
    "  :AI <text>       prompt · ? ask · : act · ! exec · ... steer",
    "  :AI?? <text>     new workspace · ??? headless · ???? new worker",
  }
  for _, group in ipairs(GROUPS) do
    local names = {}
    for _, command in ipairs(COMMANDS) do
      if command.group == group.id then names[#names + 1] = "/" .. command.name end
    end
    lines[#lines + 1] = string.format("  %-15s%s", group.label, table.concat(names, " "))
  end
  lines[#lines + 1] = "  language       ## PLAN_ · ### OP_ · ### LOOK_"
  lines[#lines + 1] = "  :AI/help <verb> for exact usage"
  return table.concat(lines, "\n")
end

function M.reference()
  local lines = {}
  for _, command in ipairs(COMMANDS) do
    lines[#lines + 1] = string.format("%-32s %s", editor_usage(command.usage), command.summary)
  end
  return table.concat(lines, "\n")
end

return M
