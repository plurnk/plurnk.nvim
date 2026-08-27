-- The :AI prefix language, slash routing, help, and command-line completion.

local M = {}

local HELP = table.concat({
  ":AI                toggle workspace tab ⇄ where you came from",
  ":AI <text>         prompt (act)",
  ":AI? <text>        ASK — read-only loop; edits/exec 403 at dispatch",
  ":AI: <text>        act (the default)",
  ":AI! <cmd>         exec via the daemon; bare ! execs the visual selection",
  ":AI?? / ::         new workspace    ??? headless    ???? new worker (fork)",
  ":AI... <text>      inject into the running model loop (loop.inject)",
  ":AI/<verb>         models [search] · model <selector> · child <selector|inherit> · reasoning [policy]",
  "                   workspaces workers workspace worker rename log yolo ping",
  "                   pick hide view drop members (membership overlay)",
  "                   script <path> (run a .plk file via op.parse)",
  "                   mcp (list available workspace MCP servers)",
  "                       add <alias> <target> [options.json] · enable/disable/remove <alias>",
  "                       oauth <alias> <callback-url>",
  "                   agents (list this Worker's outbound A2A agents)",
  "                       discover <url> · add <alias> <url> [options.json] · enable/disable/remove <alias>",
  "                   skills (list this Worker's Agent Skills)",
  "                       discover <query|source> · add <name> <source> [--global] · enable/disable/remove <name>",
  "                   open accept reject next prev stop clear",
  "visual             '<,'>AI? … prepends the selection",
  "input buffer       ? ask · : act · ! exec · # PLAN0 / ## OP0 raw PLURNK · <CR> submits",
}, "\n")

local SLASH = {
  stop = function() require("plurnk.controls").stop() end,
  clear = function() require("plurnk.controls").clear() end,
  abort = function() require("plurnk.controls").stop() end,
  models = function(args) require("plurnk.generation").models(args) end,
  model = function(args) require("plurnk.generation").set_model(args) end,
  child = function(args) require("plurnk.generation").set_child(args) end,
  reasoning = function(args) require("plurnk.generation").set_reasoning(args) end,
  workspaces = function() require("plurnk.workspaces").list() end,
  workers = function() require("plurnk.workspaces").workers() end,
  workspace = function(args) require("plurnk.workspaces").create({ args = args }) end,
  rename = function(args) require("plurnk.workspaces").rename({ args = args }) end,
  worker = function(args) require("plurnk.workspaces").fork({ args = args }) end,
  log = function(args) require("plurnk.workspaces").log({ args = args }) end,
  pick = function(args) require("plurnk.membership").pick({ args = args }) end,
  hide = function(args) require("plurnk.membership").hide({ args = args }) end,
  view = function(args) require("plurnk.membership").view({ args = args }) end,
  drop = function(args) require("plurnk.membership").drop({ args = args }) end,
  members = function() require("plurnk.membership").list() end,
  script = function(args) require("plurnk.controls").script({ args = args }) end,
  mcp = function(args) require("plurnk.functionality").run("mcp", args) end,
  skills = function(args) require("plurnk.functionality").run("skills", args) end,
  agents = function(args) require("plurnk.functionality").run("agents", args) end,
  yolo = function() require("plurnk.controls").yolo() end,
  ping = function() require("plurnk.controls").ping() end,
  open = function() require("plurnk.workspaces").toggle() end,
  accept = function() require("plurnk.controls").accept() end,
  reject = function() require("plurnk.controls").reject() end,
  next = function() require("plurnk.controls").next() end,
  prev = function() require("plurnk.controls").prev() end,
}

function M.help()
  vim.api.nvim_echo({ { HELP, "None" } }, false, {})
end

function M.complete(_arglead, cmdline, _cursor_position)
  local state = require("plurnk.state")
  local reasoning_partial = cmdline:match("/reasoning%s+(%S*)$")
  if reasoning_partial then
    local out = {}
    local workspace = require("plurnk.workspace_context").active()
    for _, policy in ipairs(state.get_reasoning_policies(workspace)) do
      if vim.startswith(policy, reasoning_partial) then out[#out + 1] = policy end
    end
    table.sort(out)
    return out
  end

  local model_partial = cmdline:match("/model%s+(%S*)$")
  local child_partial = cmdline:match("/child%s+(%S*)$")
  local alias_partial = model_partial or child_partial
  if alias_partial then
    local aliases = state.get_available_aliases()
    if #aliases == 0 then
      pcall(function()
        require("plurnk.client").send("providers.list", {}, false, function(result)
          if type(result) == "table" and type(result.aliases) == "table" then
            state.set_available_aliases(result.aliases)
          end
        end)
      end)
    end
    local out = {}
    if child_partial and vim.startswith("inherit", alias_partial) then out[#out + 1] = "inherit" end
    for _, alias in ipairs(aliases) do
      if (not child_partial or alias.alias ~= "inherit")
          and vim.startswith(alias.alias, alias_partial) then
        out[#out + 1] = alias.alias
      end
    end
    table.sort(out)
    return out
  end

  local script_partial = cmdline:match("/script%s+(%S*)$")
  if script_partial then return vim.fn.getcompletion(script_partial, "file") end

  local functionality = require("plurnk.functionality").complete(cmdline)
  if functionality then return functionality end

  local verb_partial = cmdline:match("/(%S*)$")
  if verb_partial and not cmdline:match("/%S+%s") then
    local out = {}
    for verb in pairs(SLASH) do
      if vim.startswith(verb, verb_partial) then out[#out + 1] = "/" .. verb end
    end
    table.sort(out)
    return out
  end
  return {}
end

function M.run(opts)
  local raw = (opts.args or ""):gsub("^%s+", "")
  if opts.bang then raw = "!" .. raw end
  if raw == "" then return require("plurnk.workspaces").toggle() end

  if raw:sub(1, 3) == "..." then
    local message = raw:sub(4):gsub("^%s+", "")
    if message == "" then
      require("plurnk.client").notify(":AI... needs a message to inject", vim.log.levels.WARN)
      return
    end
    require("plurnk.client").send("loop.inject", { prompt = message }, false)
    return
  end

  if raw:sub(1, 1) == "/" then
    local subcommand, args = raw:match("^/(%S+)%s*(.*)$")
    if subcommand == nil or subcommand == "help" then return M.help() end
    local handler = SLASH[subcommand]
    if handler then return handler(args or "") end
    require("plurnk.client").notify(
      ":AI/" .. tostring(subcommand) .. " is unknown — :AI/ for the language",
      vim.log.levels.WARN)
    return
  end

  local first = raw:sub(1, 1)
  local prefix_length = 0
  if first == "?" or first == ":" or first == "!" then
    while raw:sub(prefix_length + 1, prefix_length + 1) == first do
      prefix_length = prefix_length + 1
    end
  end
  local rest = raw:sub(prefix_length + 1):gsub("^%s+", "")
  local flags = first == "?" and { mode = "ask" } or nil
  local context = require("plurnk.workspace_context")
  local loop = require("plurnk.loop")

  if first == "!" then
    local command = rest ~= "" and rest or loop.selection_text(opts)
    if not command or command == "" then
      require("plurnk.client").notify(
        ":AI! needs a command (text or visual selection)",
        vim.log.levels.WARN)
      return
    end
    local execute = function(workspace_name)
      require("plurnk.worker_tab").open(workspace_name)
      loop.exec(command)
    end
    if prefix_length >= 4 then
      local workspace = context.active()
      if workspace then return context.fork(workspace, execute) end
      return context.create({}, execute)
    end
    if prefix_length >= 2 then
      return context.create({ headless = prefix_length == 3 }, execute)
    end
    return context.resolve(execute)
  end

  if prefix_length >= 2 then
    local prompt = loop.wrap_with_selection(rest, opts)
    local submit = function(workspace_name)
      require("plurnk.worker_tab").open(workspace_name)
      if prompt ~= "" then loop.run(workspace_name, prompt, flags) end
    end
    if prefix_length >= 4 then
      local workspace = context.active()
      if workspace then return context.fork(workspace, submit) end
      return context.create({}, submit)
    end
    return context.create({ headless = prefix_length == 3 }, submit)
  end

  loop.prompt({
    args = rest,
    range = opts.range or 0,
    line1 = opts.line1,
    line2 = opts.line2,
    flags = flags,
  })
end

return M
