-- {§nvim-agui-conformance}: the language-neutral client matrix accounts for
-- every schema-bearing action and notification in the live daemon discovery.
local NAME = "48_agui_conformance"
local root = os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim"
local H = dofile(root .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local service_root = os.getenv("PLURNK_SERVICE_DIR") or (root .. "/../plurnk-service")
  local kit_path = os.getenv("PLURNK_AGUI_CONFORMANCE_KIT")
    or (service_root .. "/plurnk-contracts/conformance/agui-v1.json")
  local kit = vim.json.decode(table.concat(vim.fn.readfile(kit_path), "\n"))
  local manifest = vim.json.decode(table.concat(
    vim.fn.readfile(root .. "/conformance/agui-client.json"),
    "\n"
  ))
  local discovery = H.call("discover", {})

  H.assert_eq(manifest.schemaVersion, 1, "client conformance schema version")
  H.assert_eq(manifest.client, "plurnk.nvim", "client conformance identity")
  H.assert_eq(discovery.schemaVersion, 1, "live discovery schema version")

  local function keys(value)
    local out = {}
    for name in pairs(value or {}) do out[#out + 1] = name end
    table.sort(out)
    return out
  end
  local function joined_keys(value) return table.concat(keys(value), "\n") end
  H.assert_eq(joined_keys(manifest.actions), joined_keys(discovery.actions), "all live actions are classified")
  H.assert_eq(joined_keys(manifest.notifications), joined_keys(discovery.notifications), "all live notifications are classified")

  local function disposition(kind, name, value)
    H.assert_type(value, "table", kind .. " " .. name .. " disposition")
    H.assert_truthy(value.posture == "native" or value.posture == "generic" or value.posture == "unsupported",
      kind .. " " .. name .. " posture")
    H.assert_type(value.evidence, "table", kind .. " " .. name .. " evidence")
    H.assert_truthy(#value.evidence > 0, kind .. " " .. name .. " cites evidence")
    for _, item in ipairs(value.evidence) do
      H.assert_truthy(type(item) == "string" and item ~= "", kind .. " " .. name .. " evidence is nonempty")
    end
    if value.posture == "unsupported" then
      H.assert_truthy(type(value.reason) == "string" and value.reason ~= "", kind .. " " .. name .. " explains unsupported behavior")
    else
      H.assert_eq(value.reason, nil, kind .. " " .. name .. " has no unsupported reason")
    end
  end

  for name, contract in pairs(discovery.actions) do
    H.assert_type(contract, "table", "action " .. name)
    H.assert_truthy(contract.scope == "worldless" or contract.scope == "workspace", "action " .. name .. " scope")
    H.assert_type(contract.inputSchema, "table", "action " .. name .. " input schema")
    H.assert_type(contract.outputSchema, "table", "action " .. name .. " output schema")
    disposition("action", name, manifest.actions[name])
  end
  for name, contract in pairs(discovery.notifications) do
    H.assert_type(contract, "table", "notification " .. name)
    H.assert_type(contract.payloadSchema, "table", "notification " .. name .. " payload schema")
    disposition("notification", name, manifest.notifications[name])
  end

  local discovery_path = vim.fn.tempname() .. ".json"
  vim.fn.writefile({ vim.json.encode(discovery) }, discovery_path)
  local report = vim.system({
    vim.fn.exepath("node"),
    "--conditions=plurnk-dev",
    service_root .. "/plurnk-contracts/scriptify/agui-conformance-report.ts",
    discovery_path,
    root .. "/conformance/agui-client.json",
    root,
  }, { text = true }):wait()
  vim.fn.delete(discovery_path)
  H.assert_eq(report.code, 0, "shared conformance report: " .. tostring(report.stderr))
  local rows = vim.split(vim.trim(report.stdout), "\n", { plain = true, trimempty = true })
  H.assert_eq(#rows, #keys(discovery.actions) + #keys(discovery.notifications), "one report row per member")
  io.write(report.stdout)

  local agui = require("plurnk.agui")
  local target = require("plurnk.bridge").target()
  for name in pairs(discovery.actions) do
    local segment
    agui.rpc(target, "nvim-conformance-invalid", name, { unadvertised = true }, function(value)
      segment = value
    end)
    H.wait_for(function() return segment ~= nil end, 10000, name .. " invalid action")
    H.assert_eq(segment.state, "failed", name .. " rejects fields absent from discovery")
    H.assert_eq(segment.problem.type,
      "https://problems.plurnk.dev/agui/action/invalid-action-parameters",
      name .. " preserves the shared admission Problem")
    H.assert_eq(segment.problem.status, 400, name .. " admission status")
  end

  H.assert_eq(kit.schemaVersion, 1, "shared conformance-kit schema version")
  for _, specimen in ipairs(kit.transport) do
    local buffer, events, failure = "", {}, nil
    local function consume(eof)
      local parsed
      local parsed_ok, parsed_or_error, rest = pcall(agui.parse_sse, buffer, eof)
      if not parsed_ok then failure = parsed_or_error; return end
      parsed = parsed_or_error
      buffer = rest
      vim.list_extend(events, parsed)
    end
    for _, chunk in ipairs(specimen.chunks) do
      buffer = buffer .. chunk
      consume(false)
      if failure ~= nil then break end
    end
    if failure == nil and specimen.eof then consume(true) end
    if specimen.expect.error ~= nil then
      H.assert_truthy(failure ~= nil, specimen.name .. " rejects malformed JSON")
    else
      H.assert_eq(failure, nil, specimen.name .. " parses")
      H.assert_truthy(vim.deep_equal(events, specimen.expect.events), specimen.name .. " preserves exact events")
    end
  end

  local bridge = require("plurnk.bridge")
  local dispatch = require("plurnk.dispatch")
  local real_run = agui.run
  local real_dispatch = dispatch.handle_notification
  local real_notify = vim.notify
  for _, specimen in ipairs(kit.lifecycles) do
    local notifications, final, action_segment = {}, nil, nil
    agui.run = function(_, _, on_event, on_done)
      for _, event in ipairs(specimen.events) do on_event(event) end
      on_done(0, nil)
      return { kill = function() end }
    end
    dispatch.handle_notification = function(notification)
      notifications[#notifications + 1] = notification
    end
    vim.notify = function() end

    if specimen.expect.action ~= nil then
      agui.action_segment({ url = "http://fixture.invalid" }, {
        threadId = "fixture",
        messages = {},
        forwardedProps = { action = { kind = specimen.expect.action.kind } },
      }, function(segment) action_segment = segment end)
      H.assert_truthy(action_segment ~= nil, specimen.name .. " completes an action segment")
      H.assert_eq(action_segment.state, specimen.expect.action.ok and "complete" or "failed",
        specimen.name .. " action disposition")
      if specimen.expect.action.status ~= nil then
        local status = specimen.expect.action.ok and action_segment.result.status or action_segment.problem.status
        H.assert_eq(status, specimen.expect.action.status, specimen.name .. " action status")
      end
    else
      bridge.run("fixture", "fixture", {}, function(status) final = status end)
      if specimen.expect.completion == "interrupt" then
        H.assert_eq(final, nil, specimen.name .. " remains paused for client resolution")
      else
        H.assert_eq(final, specimen.expect.status, specimen.name .. " terminal status")
      end
    end

    local families = {}
    for _, notification in ipairs(notifications) do families[notification.method] = true end
    for _, family in ipairs(specimen.expect.families) do
      H.assert_truthy(families[family] == true, specimen.name .. " projects " .. family)
    end
  end
  agui.run = real_run
  dispatch.handle_notification = real_dispatch
  vim.notify = real_notify
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
