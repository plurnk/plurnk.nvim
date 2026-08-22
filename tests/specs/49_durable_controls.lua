-- {§nvim-agui-conformance}: each durable editor-exposed control is mutated
-- through the client and observed through a separate AG-UI connection.
local NAME = "49_durable_controls"
local root = os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim"
local H = dofile(root .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local workspace = "nvim-durable-" .. tostring(vim.uv.hrtime())
  local created = H.call("workspace.create", { name = workspace, projectRoot = vim.NIL })
  local state = require("plurnk.state")
  state.set_active_workspace_name(workspace)
  state.set_workspace_id(workspace, created.id)

  local agui = require("plurnk.agui")
  local target = require("plurnk.bridge").target()
  local function observe(method, params)
    local segment
    agui.rpc(target, workspace, method, params or {}, function(value) segment = value end)
    H.wait_for(function() return segment ~= nil end, 20000, "observe " .. method)
    if segment.state ~= "complete" then
      error("observer " .. method .. " failed: " .. vim.inspect(segment.problem))
    end
    return segment.result
  end

  local workspaces = observe("workspace.list").workspaces
  H.assert_truthy(vim.iter(workspaces):any(function(item)
    return item.id == created.id and item.name == workspace
  end), "separate connection observes workspace creation")

  H.call("workspace.constrain", { effect = "pick", glob = "lua/**" })
  H.assert_truthy(vim.deep_equal(observe("workspace.constraints").constraints, {
    { effect = "pick", glob = "lua/**" },
  }), "separate connection observes constraint")
  H.call("workspace.unconstrain", { effect = "pick", glob = "lua/**" })
  H.assert_eq(#observe("workspace.constraints").constraints, 0, "separate connection observes unconstrain")

  local child = H.call("run.fork", { name = "durable-child" })
  H.assert_truthy(vim.iter(observe("workspace.workers", { id = created.id }).workers):any(function(worker)
    return worker.id == child.workerId and worker.name == "durable-child"
  end), "separate connection observes fork")

  H.call("worker.model.set", { selector = "nvimtest" })
  local model = observe("worker.model.get").model
  H.assert_eq(model.alias, "nvimtest", "separate connection observes model alias")
  H.assert_eq(model.model, "nvim-family/selected", "separate connection observes model route")
  H.call("worker.child.set", { selector = "nvimtest" })
  H.assert_eq(observe("worker.model.get").spawnModel.alias, "nvimtest", "separate connection observes child model")
  H.call("worker.reasoning.set", { policy = "adaptive" })
  H.assert_eq(observe("worker.reasoning.get").policy, "adaptive", "separate connection observes reasoning")
  H.call("worker.settings.set", { settings = { requestUserInput = true } })
  H.assert_eq(observe("worker.settings.get").requestUserInput, true, "separate connection observes settings")

  local service_root = os.getenv("PLURNK_SERVICE_DIR") or (root .. "/../plurnk-service")
  local fixture = service_root .. "/plurnk-mcp/src/fixtures/echo-server.mjs"
  H.call("workspace.mcp.add", {
    alias = "durable",
    target = vim.fn.exepath("node"),
    options = { args = { fixture }, tools = { "echo" }, read = { "echo" } },
  }, 20000)
  local function server_state()
    for _, server in ipairs(observe("workspace.mcp.list").servers) do
      if server.alias == "durable" then return server.state end
    end
    return nil
  end
  H.assert_eq(server_state(), "connected", "separate connection observes MCP add")
  H.call("workspace.mcp.disable", { alias = "durable" }, 20000)
  H.assert_eq(server_state(), "disabled", "separate connection observes MCP disable")
  H.call("workspace.mcp.enable", { alias = "durable" }, 20000)
  H.assert_eq(server_state(), "connected", "separate connection observes MCP enable")
  H.call("workspace.mcp.remove", { alias = "durable" }, 20000)
  H.assert_eq(server_state(), nil, "separate connection observes MCP remove")

  local renamed = workspace .. "-renamed"
  H.call("workspace.rename", { name = renamed })
  H.assert_truthy(vim.iter(observe("workspace.list").workspaces):any(function(item)
    return item.id == created.id and item.name == renamed
  end), "separate connection observes workspace rename")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
