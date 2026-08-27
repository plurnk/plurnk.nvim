-- The Neovim client's executable AG-UI+ compatibility contract. The
-- conformance manifest owns the capabilities this client consumes; this module
-- adds the discovery schema version that frames that manifest.

local M = { DISCOVERY_SCHEMA_VERSION = 1 }
local manifest

local function root()
  local source = debug.getinfo(1, "S").source:gsub("^@", "")
  return vim.fn.fnamemodify(source, ":p:h:h:h")
end

local function conformance()
  if manifest then return manifest end
  local path = root() .. "/conformance/agui-client.json"
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then error("Neovim client conformance manifest is unavailable: " .. path, 0) end
  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded_ok or type(decoded) ~= "table"
      or type(decoded.actions) ~= "table" or type(decoded.notifications) ~= "table" then
    error("Neovim client conformance manifest is invalid: " .. path, 0)
  end
  manifest = decoded
  return manifest
end

local function schema_bearing(value, fields)
  if type(value) ~= "table" then return false end
  for _, field in ipairs(fields) do
    if type(value[field]) ~= "table" then return false end
  end
  return true
end

function M.assess(discovery)
  if type(discovery) ~= "table" then
    return { compatible = false, kind = "invalid", detail = "discover returned no object" }
  end
  local version = discovery.schemaVersion
  if type(version) ~= "number" or version ~= math.floor(version) then
    return { compatible = false, kind = "invalid", detail = "discover omitted its integer schemaVersion" }
  end
  if version ~= M.DISCOVERY_SCHEMA_VERSION then
    return {
      compatible = false,
      kind = version < M.DISCOVERY_SCHEMA_VERSION and "stale" or "newer",
      schema_version = version,
      detail = string.format(
        "daemon discovery schema %d; this client requires %d",
        version,
        M.DISCOVERY_SCHEMA_VERSION
      ),
    }
  end

  local expected = conformance()
  local missing = {}
  for name in pairs(expected.actions) do
    if not schema_bearing(type(discovery.actions) == "table" and discovery.actions[name], {
      "inputSchema", "outputSchema",
    }) then
      missing[#missing + 1] = name
    end
  end
  for name in pairs(expected.notifications) do
    if not schema_bearing(type(discovery.notifications) == "table" and discovery.notifications[name], {
      "payloadSchema",
    }) then
      missing[#missing + 1] = name
    end
  end
  if type(discovery.display) ~= "table" then missing[#missing + 1] = "display" end
  table.sort(missing)
  if #missing > 0 then
    return {
      compatible = false,
      kind = "capabilities",
      schema_version = version,
      missing = missing,
      detail = "discovery schema 1 is missing required client capabilities: " .. table.concat(missing, ", "),
    }
  end
  return { compatible = true, kind = "compatible", schema_version = version }
end

return M
