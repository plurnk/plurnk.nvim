-- {§nvim-agui-conformance}: each durable editor-exposed control is mutated
-- through the client and observed through a separate AG-UI connection.
local NAME = "49_durable_controls"
local root = os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim"
local H = dofile(root .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  -- A standard global Agent Skill present before the workspace's first Functionality demand.
  local daemon_home = os.getenv("PLURNK_NVIM_DAEMON_HOME")
  if daemon_home ~= nil and daemon_home ~= "" then
    vim.fn.mkdir(daemon_home .. "/.agents/skills/durable-skill", "p")
    vim.fn.writefile({ "---", "name: durable-skill", "description: Durable skill", "---", "Use it." }, daemon_home .. "/.agents/skills/durable-skill/SKILL.md")
  end
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
  H.call("workspace.capabilities.set", { policy = { deny = { { runtime = "sh" } } } })
  H.assert_eq(observe("workspace.capabilities.get").workspace.deny[1].runtime, "sh", "separate connection observes capability settings")

  local service_root = os.getenv("PLURNK_SERVICE_DIR") or (root .. "/../plurnk-service")
  local fixture = service_root .. "/plurnk-mcp/src/fixtures/echo-server.mjs"
  H.call("workspace.mcp.add", {
    alias = "durable",
    definition = { name = "durable", transport = "stdio", command = vim.fn.exepath("node"), args = { fixture }, tools = { "echo" }, read = { "echo" } },
  }, 20000)
  local function server_state()
    for _, entry in ipairs(observe("workspace.mcp.list").definitions) do
      if entry.alias == "durable" then return entry.state end
    end
    return nil
  end
  H.assert_eq(server_state(), "active", "separate connection observes MCP add")
  H.call("workspace.mcp.disable", { alias = "durable" }, 20000)
  H.assert_eq(server_state(), "disabled", "separate connection observes MCP disable")
  H.call("workspace.mcp.enable", { alias = "durable" }, 20000)
  H.assert_eq(server_state(), "active", "separate connection observes MCP enable")
  H.call("workspace.mcp.remove", { alias = "durable" }, 20000)
  H.assert_eq(server_state(), nil, "separate connection observes MCP remove")

  H.call("workspace.members.add", { alias = "durable-glob", definition = { glob = "lua/**" } }, 20000)
  local function member_definition()
    for _, entry in ipairs(observe("workspace.members.list").definitions) do
      if entry.alias == "durable-glob" then return entry end
    end
    return nil
  end
  local added = member_definition()
  H.assert_eq(added and added.state, "active", "separate connection observes members add")
  H.assert_eq(added and added.origin, "workspace", "the added definition is workspace-owned")
  H.assert_eq(added and added.definition.glob, "lua/**", "separate connection observes the exact glob")
  H.call("workspace.members.disable", { alias = "durable-glob" }, 20000)
  H.assert_eq(member_definition().state, "disabled", "separate connection observes members disable")
  H.call("workspace.members.enable", { alias = "durable-glob" }, 20000)
  H.assert_eq(member_definition().state, "active", "separate connection observes members enable")
  H.call("workspace.members.remove", { alias = "durable-glob" }, 20000)
  H.assert_eq(member_definition(), nil, "separate connection observes members remove")

  if daemon_home ~= nil and daemon_home ~= "" then
    local function skill_state()
      for _, entry in ipairs(observe("workspace.skills.list").definitions) do
        if entry.alias == "durable-skill" then return entry.state end
      end
      return nil
    end
    H.assert_eq(skill_state(), "active", "separate connection observes the installed skill")
    H.call("workspace.skills.disable", { alias = "durable-skill" }, 20000)
    H.assert_eq(skill_state(), "disabled", "separate connection observes skill disable")
    H.call("workspace.skills.enable", { alias = "durable-skill" }, 20000)
    H.assert_eq(skill_state(), "active", "separate connection observes skill enable")
  end

  local agent_url = os.getenv("PLURNK_NVIM_A2A_URL")
  if agent_url ~= nil and agent_url ~= "" then
    local function agent_state()
      for _, entry in ipairs(observe("workspace.agents.list").definitions) do
        if entry.alias == "demo" then return entry.state end
      end
      return nil
    end
    H.assert_eq(agent_state(), "active", "separate connection observes the configured outbound agent")
    H.call("workspace.agents.disable", { alias = "demo" }, 20000)
    H.assert_eq(agent_state(), "disabled", "separate connection observes agent disable")
    H.call("workspace.agents.enable", { alias = "demo" }, 20000)
    H.assert_eq(agent_state(), "active", "separate connection observes agent enable")
  end

  local renamed = workspace .. "-renamed"
  H.call("workspace.rename", { name = renamed })
  H.assert_truthy(vim.iter(observe("workspace.list").workspaces):any(function(item)
    return item.id == created.id and item.name == renamed
  end), "separate connection observes workspace rename")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
