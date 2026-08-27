-- User-facing workspace and conversation-worker controls.

local M = {}

local context = require("plurnk.workspace_context")

function M.list()
  local client = require("plurnk.client")
  client.send("workspace.list", {}, false, function(result)
    if type(result) ~= "table" or type(result.workspaces) ~= "table" then return end
    if #result.workspaces == 0 then
      client.notify("No workspaces on the daemon", vim.log.levels.INFO)
      return
    end
    vim.ui.select(result.workspaces, {
      prompt = "Plurnk workspace",
      format_item = function(workspace)
        return string.format("%s  (%s)", workspace.name, workspace.project_root or "(headless)")
      end,
    }, function(choice)
      if not choice then return end
      context.warn_if_switching_live()
      client.send("workspace.attach", { id = choice.id }, false, function(attached)
        if type(attached) ~= "table" then return end
        local state = require("plurnk.state")
        state.set_workspace_id(choice.name, choice.id)
        state.set_active_workspace_name(choice.name)
        context.associate_buffer(vim.api.nvim_get_current_buf(), choice.name)
        context.adopt_model_worker(choice.name, function()
          require("plurnk.worker_tab").open(choice.name)
          context.hydrate_worker(choice.name)
          require("plurnk.generation").hydrate(choice.name)
        end)
      end)
    end)
  end)
end

function M.create(opts)
  context.create({ name = opts.args }, function(name)
    require("plurnk.worker_tab").open(name)
    require("plurnk.client").notify("Workspace created: " .. name, vim.log.levels.INFO)
  end)
end

function M.rename(opts)
  local new_name = (opts.args or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if new_name == "" then
    require("plurnk.client").notify(":AI/rename needs a new name", vim.log.levels.WARN)
    return
  end
  local workspace = context.active()
  if not workspace then
    require("plurnk.client").notify("No active workspace to rename", vim.log.levels.WARN)
    return
  end
  context.resolve(function()
    require("plurnk.client").send("workspace.rename", { name = new_name }, false, function(result)
      if type(result) ~= "table" or not result.name then return end
      local state = require("plurnk.state")
      local workspace_id = state.get_workspace_id(workspace)
      state.rename_workspace(workspace, result.name)
      if workspace_id then state.set_workspace_id(result.name, workspace_id) end
      state.set_active_workspace_name(result.name)
      require("plurnk.worker_tab").rename(workspace, result.name)
      context.associate_buffer(vim.api.nvim_get_current_buf(), result.name)
      require("plurnk.client").notify(
        "renamed " .. workspace .. " → " .. result.name,
        vim.log.levels.INFO)
    end)
  end)
end

function M.workers()
  local workspace = context.active()
  if not workspace then
    require("plurnk.client").notify("No active workspace", vim.log.levels.WARN)
    return
  end
  local workspace_id = require("plurnk.state").get_workspace_id(workspace)
  if not workspace_id then
    require("plurnk.client").notify(
      "Workspace " .. workspace .. " not resolved",
      vim.log.levels.WARN)
    return
  end
  local client = require("plurnk.client")
  client.send("workspace.workers", { id = workspace_id }, false, function(result)
    if type(result) ~= "table" or type(result.workers) ~= "table" then return end
    local workers = {}
    for _, worker in ipairs(result.workers) do
      if worker.origin == "model" then workers[#workers + 1] = worker end
    end
    if #workers == 0 then
      client.notify("No conversations in " .. workspace, vim.log.levels.INFO)
      return
    end
    vim.ui.select(workers, {
      prompt = "Plurnk conversation (workspace " .. workspace .. ")",
      format_item = function(worker)
        return worker.name .. "  (" .. (worker.created_at or "?") .. ")"
      end,
    }, function(choice)
      if not choice then return end
      context.switch_worker(workspace, choice.id, function()
        require("plurnk.worker_tab").open(workspace)
        context.hydrate_worker(workspace)
      end)
    end)
  end)
end

function M.fork(opts)
  local name = (opts.args or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local workspace = context.active()
  if not workspace then
    require("plurnk.client").notify("No active workspace to fork", vim.log.levels.WARN)
    return
  end
  context.resolve(function()
    context.fork(workspace, function(resolved_workspace)
      require("plurnk.worker_tab").open(resolved_workspace)
      require("plurnk.client").notify(
        "forked" .. (name ~= "" and (" → " .. name) or ""),
        vim.log.levels.INFO)
    end, name ~= "" and name or nil)
  end)
end

function M.log(opts)
  local workspace = context.active()
  if not workspace then
    require("plurnk.client").notify("No active workspace", vim.log.levels.WARN)
    return
  end
  local params = {}
  if opts.args and tonumber(opts.args) then params.limit = tonumber(opts.args) end
  require("plurnk.client").send("log.read", params, false, function(result)
    if type(result) ~= "table" then return end
    require("plurnk.worker_tab").open(workspace)
    require("plurnk.worker_tab").append_history(workspace, result.entries or {})
  end)
end

local return_tabpage

function M.toggle()
  local worker_tab = require("plurnk.worker_tab")
  if worker_tab.workspace_for_tabpage(vim.api.nvim_get_current_tabpage()) then
    if return_tabpage and vim.api.nvim_tabpage_is_valid(return_tabpage) then
      vim.api.nvim_set_current_tabpage(return_tabpage)
    else
      pcall(vim.cmd, "tabprevious")
    end
    return_tabpage = nil
    return
  end
  return_tabpage = vim.api.nvim_get_current_tabpage()
  local workspace = context.active()
  if workspace then
    worker_tab.open(workspace)
    return
  end
  context.resolve(function(workspace_name) worker_tab.open(workspace_name) end)
end

return M
