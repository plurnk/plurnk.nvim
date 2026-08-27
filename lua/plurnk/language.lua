-- The :AI prefix language, slash routing, help, and command-line completion.

local M = {}

function M.help(name)
  vim.api.nvim_echo({ { require("plurnk.command_registry").render_help(name), "None" } }, false, {})
end

function M.complete(_arglead, cmdline, _cursor_position)
  local context = require("plurnk.command_registry").completion_context(cmdline)
  if not context then return {} end
  if context.kind == "syntax" then return context.values end
  if context.kind == "path" then return vim.fn.getcompletion(context.prefix, "file") end
  if context.kind == "functionality" then
    return require("plurnk.functionality").complete_aliases(context.family, context.prefix)
  end

  local state = require("plurnk.state")
  if context.kind == "reasoning" then
    local out = {}
    local workspace = require("plurnk.workspace_context").active()
    for _, policy in ipairs(state.get_reasoning_policies(workspace)) do
      if vim.startswith(policy, context.prefix) then out[#out + 1] = policy end
    end
    table.sort(out)
    return out
  end

  if context.kind == "model" or context.kind == "child" then
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
    if context.kind == "child" and vim.startswith("inherit", context.prefix) then out[#out + 1] = "inherit" end
    for _, alias in ipairs(aliases) do
      if (context.kind ~= "child" or alias.alias ~= "inherit")
          and vim.startswith(alias.alias, context.prefix) then
        out[#out + 1] = alias.alias
      end
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
    if subcommand == nil then return M.help() end
    if require("plurnk.command_registry").dispatch(subcommand, args or "") then return end
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
