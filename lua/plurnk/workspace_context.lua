-- Workspace binding and conversation-worker lifecycle shared by every command.

local M = {}

local CLIENT_ID = "plurnk.nvim"

function M.settings()
  local settings = { client = CLIENT_ID }
  local capabilities = require("plurnk.config").get("workspace_capabilities")
  if type(capabilities) == "table" then
    settings.capabilities = require("plurnk.policy").capabilities(capabilities)
  end
  local files_items = require("plurnk.config").get("files_items")
  if type(files_items) == "number" then settings.filesItems = files_items end
  return settings
end

function M.active()
  if vim.b.plurnk_worker_id and vim.b.plurnk_workspace then return vim.b.plurnk_workspace end
  local tab = require("plurnk.worker_tab").workspace_for_tabpage(vim.api.nvim_get_current_tabpage())
  if tab then return tab end
  if vim.b.plurnk_workspace then return vim.b.plurnk_workspace end
  return require("plurnk.state").get_active_workspace_name()
end

function M.binding()
  local tab_workspace, tab_worker = require("plurnk.worker_tab").binding_for_tabpage(vim.api.nvim_get_current_tabpage())
  local workspace = (vim.b.plurnk_worker_id and vim.b.plurnk_workspace) or tab_workspace or M.active() or "nvim"
  local worker = vim.b.plurnk_workspace == workspace and vim.b.plurnk_worker_id or tab_worker
  return require("plurnk.state").binding(workspace, worker)
end

function M.associate_buffer(bufnr, workspace_name)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.b[bufnr].plurnk_workspace = workspace_name
  end
end

function M.note_model_worker(workspace_name, worker_id, worker_name)
  if type(worker_id) ~= "number" then return end
  local state = require("plurnk.state")
  state.set_worker_id(workspace_name, worker_id)
  if worker_name then
    state.set_worker_name(workspace_name, worker_name)
    state.set_worker_label(workspace_name, worker_id, worker_name)
  end
  require("plurnk.worker_tab").note_worker_resolved(workspace_name)
end

function M.resolve(callback)
  local client = require("plurnk.client")
  local workspace = M.active()
  if workspace then
    local binding = M.binding()
    client.check_daemon_once()
    require("plurnk.generation").persist_picked_policies(client.scoped(binding), workspace, function()
      callback(workspace, binding)
    end)
    return
  end

  local origin_buf = vim.api.nvim_get_current_buf()
  client.send("workspace.create", {
    projectRoot = client.get_project_path(),
    settings = M.settings(),
  }, false, function(result)
    if type(result) ~= "table" or not result.name then return end
    local state = require("plurnk.state")
    state.set_workspace_id(result.name, result.id)
    state.set_active_workspace_name(result.name)
    M.associate_buffer(origin_buf, result.name)
    client.check_daemon_once()
    require("plurnk.generation").persist_picked_policies(client.scoped(state.binding(result.name)), result.name, function()
      require("plurnk.generation").hydrate(result.name)
      callback(result.name, require("plurnk.state").binding(result.name))
    end)
  end)
end

function M.create(options, callback)
  local client = require("plurnk.client")
  local params = { settings = M.settings() }
  if not options.headless then params.projectRoot = client.get_project_path() end
  if options.name and options.name ~= "" then params.name = options.name end
  local origin_buf = vim.api.nvim_get_current_buf()
  client.send("workspace.create", params, false, function(result)
    if type(result) ~= "table" or not result.name then return end
    local state = require("plurnk.state")
    state.set_workspace_id(result.name, result.id)
    state.set_active_workspace_name(result.name)
    M.associate_buffer(origin_buf, result.name)
    client.check_daemon_once()
    require("plurnk.generation").persist_picked_policies(client.scoped(state.binding(result.name)), result.name, function()
      require("plurnk.generation").hydrate(result.name)
      callback(result.name, state.binding(result.name))
    end)
  end)
end

function M.fork(workspace_name, callback, name, binding)
  local client = require("plurnk.client").scoped(binding or require("plurnk.state").binding(workspace_name))
  local params = {}
  if name and name ~= "" then params.name = name end
  client.send("run.fork", params, false, function(result)
    if type(result) ~= "table" or not result.workerId then
      client.notify(
        "run.fork failed (need a model worker to fork — start a loop first)",
        vim.log.levels.WARN)
      return
    end
    local workspace_id = require("plurnk.state").get_workspace_id(workspace_name)
    client.send("workspace.attach", {
      id = workspace_id,
      workerId = result.workerId,
    }, false, function(attached)
      if type(attached) ~= "table" or attached.workerId ~= result.workerId then return end
      local worker_id = result.workerId
      M.note_model_worker(workspace_name, worker_id, result.workerName)
      callback(workspace_name, require("plurnk.state").binding(workspace_name, worker_id))
    end)
  end)
end

function M.switch_worker(workspace_name, worker_id, callback)
  local state = require("plurnk.state")
  if state.get_worker_id(workspace_name) == worker_id then return callback() end
  local workspace_id = state.get_workspace_id(workspace_name)
  if not workspace_id then
    require("plurnk.client").notify(
      "Workspace " .. workspace_name .. " not resolved",
      vim.log.levels.WARN)
    return
  end
  require("plurnk.client").scoped(state.binding(workspace_name)).send("workspace.attach", {
    id = workspace_id,
    workerId = worker_id,
  }, false, function(attached)
    if type(attached) ~= "table" then return end
    M.note_model_worker(workspace_name, attached.workerId, attached.workerName)
    require("plurnk.generation").hydrate(workspace_name)
    callback()
  end)
end

function M.hydrate_worker(workspace_name)
  local state = require("plurnk.state")
  local worker_id = state.get_worker_id(workspace_name)
  if not worker_id then return end
  require("plurnk.client").scoped(state.binding(workspace_name, worker_id)).send("log.read", {
    workerId = worker_id,
    limit = 500,
  }, false, function(result)
    if type(result) ~= "table" or type(result.entries) ~= "table" then return end
    require("plurnk.worker_tab").hydrate(workspace_name, worker_id, result.entries)
    for _, entry in ipairs(result.entries) do state.set_last_seen_log_id(workspace_name, worker_id, entry.id) end
  end)
end

function M.adopt_model_worker(workspace_name, on_done)
  local state = require("plurnk.state")
  local workspace_id = state.get_workspace_id(workspace_name)
  if not workspace_id or state.get_worker_id(workspace_name) then
    if on_done then on_done() end
    return
  end
  local client = require("plurnk.client").scoped(state.binding(workspace_name))
  -- Read the bound conversation, not whichever worker sorts first in a directory.
  -- An unused default remains pending until its first durable row identifies it.
  client.send("log.read", { limit = 1 }, false, function(result)
    if type(result) ~= "table" or type(result.entries) ~= "table" then return end
    local entry = result.entries[1]
    if not entry then if on_done then on_done() end; return end
    state.identify(client.binding, entry.worker_id)
    client.send("workspace.workers", { id = workspace_id }, false, function(directory)
      if type(directory) ~= "table" or type(directory.workers) ~= "table" then return end
      require("plurnk.workers").remember_names(workspace_name, directory.workers)
      M.note_model_worker(workspace_name, entry.worker_id, state.get_worker_label(workspace_name, entry.worker_id))
      if on_done then on_done() end
    end)
  end)
end

return M
