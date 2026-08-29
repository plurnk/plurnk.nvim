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
  local tab = require("plurnk.worker_tab").current_alias()
  if tab then return tab end
  if vim.b.plurnk_workspace then return vim.b.plurnk_workspace end
  return require("plurnk.state").get_active_workspace_name()
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

function M.warn_if_switching_live()
  local state = require("plurnk.state")
  local workspace = state.get_active_workspace_name()
  if not workspace or not state.is_loop_inflight(workspace) then return end
  local worker = state.get_worker_name(workspace)
  require("plurnk.client").notify(
    "switching away — the running loop in " .. workspace .. (worker and ("·" .. worker) or "")
      .. " continues on the daemon; reopen the worker to catch up",
    vim.log.levels.WARN)
end

function M.resolve(callback)
  local client = require("plurnk.client")
  local workspace = M.active()
  if workspace then
    client.check_daemon_once()
    require("plurnk.generation").persist_picked_policies(client, workspace, function()
      callback(workspace)
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
    require("plurnk.generation").persist_picked_policies(client, result.name, function()
      require("plurnk.generation").hydrate(result.name)
      callback(result.name)
    end)
  end)
end

function M.create(options, callback)
  local client = require("plurnk.client")
  local previous = M.active()
  M.warn_if_switching_live()
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
    if previous and previous ~= result.name then
      client.notify(
        "live workspace: " .. result.name .. " — tabs for " .. previous .. " are now static",
        vim.log.levels.INFO)
    end
    client.check_daemon_once()
    require("plurnk.generation").persist_picked_policies(client, result.name, function()
      require("plurnk.generation").hydrate(result.name)
      callback(result.name)
    end)
  end)
end

function M.fork(workspace_name, callback, name)
  local client = require("plurnk.client")
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
      local worker_id = (type(attached) == "table" and attached.workerId) or result.workerId
      local worker_name = (type(attached) == "table" and attached.workerName) or result.workerName
      M.note_model_worker(workspace_name, worker_id, worker_name)
      callback(workspace_name)
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
  M.warn_if_switching_live()
  require("plurnk.client").send("workspace.attach", {
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
  require("plurnk.client").send("log.read", {
    workerId = worker_id,
    limit = 500,
  }, false, function(result)
    if type(result) ~= "table" or type(result.entries) ~= "table" then return end
    require("plurnk.worker_tab").hydrate(workspace_name, worker_id, result.entries)
  end)
end

function M.adopt_model_worker(workspace_name, on_done)
  local workspace_id = require("plurnk.state").get_workspace_id(workspace_name)
  if not workspace_id then
    if on_done then on_done() end
    return
  end
  require("plurnk.client").send("workspace.workers", {
    id = workspace_id,
  }, false, function(result)
    if type(result) == "table" and type(result.workers) == "table" then
      for _, worker in ipairs(result.workers) do
        if worker.origin == "model" then
          M.note_model_worker(workspace_name, worker.id, worker.name)
          break
        end
      end
    end
    if on_done then on_done() end
  end)
end

return M
