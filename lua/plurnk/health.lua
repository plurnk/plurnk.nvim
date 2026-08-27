-- :checkhealth plurnk. Diagnostics use only local inspection and the worldless
-- AG-UI+ discover action: no workspace, provider, Functionality, or model work.

local M = {}

local function plugin_root()
  local source = debug.getinfo(1, "S").source:gsub("^@", "")
  return vim.fn.fnamemodify(source, ":p:h:h:h")
end

local function run_git(root, args)
  if vim.fn.executable("git") ~= 1 then return nil end
  local command = { "git", "-C", root }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true }):wait(2000)
  if result.code ~= 0 then return nil end
  local value = vim.trim(result.stdout or "")
  return value ~= "" and value or nil
end

local function public_url(value)
  if type(value) ~= "string" then return nil end
  local scheme, authority = value:match("^([%a][%w+.-]*://)([^/?#]+)")
  if not scheme then return value:gsub("[?#].*$", "") end
  return scheme .. authority:gsub("^.*@", "")
end

local function provenance()
  local root = plugin_root()
  local inside = run_git(root, { "rev-parse", "--is-inside-work-tree" }) == "true"
  return {
    root = root,
    version = inside and run_git(root, { "describe", "--tags", "--always", "--dirty" }) or nil,
    remote = inside and public_url(run_git(root, { "remote", "get-url", "origin" })) or nil,
  }
end

local function probe(target, timeout_ms)
  local segment
  local handle = require("plurnk.agui").rpc(
    target,
    "nvim-health",
    "discover",
    {},
    function(value) segment = value end
  )
  if not vim.wait(timeout_ms or 3000, function() return segment ~= nil end, 20) then
    if handle then pcall(function() handle:kill(15) end) end
    return nil, { detail = "discover did not answer within the health-check timeout" }
  end
  if segment.state ~= "complete" then return nil, segment.problem end
  return segment.result, nil
end

local function add(records, level, message)
  records[#records + 1] = { level = level, message = message }
end

function M.collect(overrides)
  local options = overrides or {}
  local records = {}
  local source = options.provenance or provenance()
  local target = options.target or require("plurnk.bridge").target()
  local curl = options.curl
  if curl == nil then curl = vim.fn.executable("curl") == 1 end

  add(records, "start", "plurnk.nvim installation")
  add(records, "ok", "Plugin: " .. (source.version or "unversioned source") .. " at " .. source.root)
  if source.remote then add(records, "info", "Source: " .. source.remote) end
  if vim.fn.has("nvim-0.10") == 1 then
    add(records, "ok", "Neovim >= 0.10")
  else
    add(records, "error", "Neovim >= 0.10 is required")
  end

  add(records, "start", "dependencies")
  if curl then
    add(records, "ok", "curl available for AG-UI+ HTTP/SSE")
  else
    add(records, "error", "curl is required for AG-UI+ HTTP/SSE")
  end
  local renderer = options.renderer
  if renderer == nil then
    local available, path, problem = require("plurnk.markdown").available()
    renderer = { available = available, path = path, problem = problem }
  end
  if renderer.available then
    add(records, "ok", "Optional GFM/Mermaid renderer: " .. renderer.path)
  else
    add(records, "warn", "Optional renderer unavailable (" .. (renderer.problem or "unknown")
      .. "); model Markdown remains faithful source")
  end

  add(records, "start", "daemon")
  add(records, "info", "Endpoint: " .. (public_url(target and target.url) or "unconfigured"))
  if curl and target and target.url then
    local discover, problem
    if options.probe then discover, problem = options.probe(target)
    else discover, problem = probe(target, options.timeout_ms) end
    if problem ~= nil then
      add(records, "error", "Daemon unreachable: " .. tostring(problem.detail or problem.title or problem))
    else
      add(records, "ok", "Daemon reachable through worldless AG-UI+ discovery")
      local assessed, assessment = pcall(require("plurnk.compatibility").assess, discover)
      if not assessed then
        add(records, "error", "Client compatibility contract unreadable: " .. tostring(assessment))
      elseif assessment.compatible then
        add(records, "ok", "AG-UI+ discovery schema " .. assessment.schema_version
          .. " supplies every client capability")
      else
        add(records, "error", "Incompatible daemon: " .. assessment.detail)
      end
    end
  end

  add(records, "start", "optional default mappings")
  local keymaps = options.keymaps or require("plurnk.keymaps")
  local mappings_enabled = options.mappings_enabled
  if mappings_enabled == nil then mappings_enabled = keymaps.enabled() end
  if not mappings_enabled then
    add(records, "info", "Default mappings are not enabled")
  else
    local mappings = options.mappings or keymaps.inspect()
    local healthy = 0
    for _, mapping in ipairs(mappings) do
      if mapping.status == "installed" then
        healthy = healthy + 1
      elseif mapping.status == "conflict" then
        add(records, "warn", string.format(
          "%s %s is owned by %s; Plurnk left it unchanged",
          mapping.mode,
          mapping.lhs,
          mapping.owner or "an unknown mapping"
        ))
      else
        add(records, "warn", string.format(
          "%s %s is missing after default mappings were enabled",
          mapping.mode,
          mapping.lhs
        ))
      end
    end
    if healthy > 0 then add(records, "ok", healthy .. " default mode mappings verified") end
  end
  return records
end

function M.check()
  local health = vim.health or require("health")
  local reporters = {
    start = health.start or health.report_start,
    ok = health.ok or health.report_ok,
    info = health.info or health.report_info or health.ok or health.report_ok,
    warn = health.warn or health.report_warn,
    error = health.error or health.report_error,
  }
  for _, record in ipairs(M.collect()) do reporters[record.level](record.message) end
end

return M
