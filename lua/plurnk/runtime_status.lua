-- Authoritative AG-UI state-gauge reduction and Neovim projection.

local M = {}

local LIFECYCLES = {
  idle = true,
  running = true,
  parked = true,
  completed = true,
  cancelled = true,
  failed = true,
}

local function is_null(value)
  return value == nil or value == vim.NIL
end

local function status_from(gauge)
  if type(gauge) ~= "table"
      or type(gauge.plurnk) ~= "table"
      or type(gauge.plurnk.status) ~= "table"
      or type(gauge.budget) ~= "table" then
    error("AG-UI state is missing plurnk.status or budget")
  end
  return gauge.plurnk.status
end

local function model_selector(route)
  if is_null(route) then return nil end
  if type(route) ~= "table" then error("AG-UI runtime model is not a model route") end
  if type(route.alias) == "string" and route.alias ~= "" then return route.alias end
  if type(route.provider) == "string" and route.provider ~= ""
      and type(route.model) == "string" and route.model ~= "" then
    return route.provider .. "/" .. route.model
  end
  error("AG-UI runtime model is not a model route")
end

function M.project(gauge)
  local raw = status_from(gauge)
  if not LIFECYCLES[raw.lifecycle] then
    error("unknown AG-UI runtime lifecycle: " .. tostring(raw.lifecycle))
  end
  if type(raw.packetCount) ~= "number"
      or raw.packetCount ~= math.floor(raw.packetCount)
      or raw.packetCount < 0 then
    error("invalid AG-UI runtime packet count: " .. tostring(raw.packetCount))
  end

  local activity
  if not is_null(raw.activity) then
    if type(raw.activity) ~= "table"
        or raw.activity.kind ~= "derivation"
        or type(raw.activity.phase) ~= "string" then
      error("unsupported AG-UI runtime activity")
    end
    local percent = tonumber(raw.activity.percent)
    activity = {
      label = raw.activity.phase == "failed"
          and "indexing failed"
          or raw.activity.phase == "preparing" and "preparing" or "indexing",
      percent = percent and math.max(0, math.min(100, math.floor(percent))) or nil,
    }
  end

  return {
    lifecycle = raw.lifecycle,
    model = model_selector(raw.model),
    loop_id = is_null(raw.loopId) and nil or raw.loopId,
    packet_count = raw.packetCount,
    activity = activity,
  }
end

function M.reduce(current, event)
  if type(event) ~= "table"
      or (event.type ~= "STATE_SNAPSHOT" and event.type ~= "STATE_DELTA") then
    return false, current
  end

  local next_gauge
  if event.type == "STATE_SNAPSHOT" then
    if type(event.snapshot) ~= "table" then error("AG-UI STATE_SNAPSHOT is not an object") end
    next_gauge = vim.deepcopy(event.snapshot)
  else
    if current == nil then error("AG-UI STATE_DELTA arrived before STATE_SNAPSHOT") end
    if type(event.delta) ~= "table" or not vim.islist(event.delta) then
      error("AG-UI STATE_DELTA is not an array")
    end
    next_gauge = vim.deepcopy(current)
    for _, patch in ipairs(event.delta) do
      if type(patch) ~= "table" or patch.op ~= "replace" or type(patch.path) ~= "string" then
        error("unsupported AG-UI state patch")
      end
      local segments = {}
      for segment in patch.path:gmatch("/([^/]*)") do
        segments[#segments + 1] = segment:gsub("~1", "/"):gsub("~0", "~")
      end
      local leaf = table.remove(segments)
      local parent = next_gauge
      for _, segment in ipairs(segments) do
        parent = type(parent) == "table" and parent[segment] or nil
      end
      if leaf == nil or type(parent) ~= "table" then
        error("AG-UI state patch has no parent: " .. patch.path)
      end
      parent[leaf] = patch.value
    end
  end

  M.project(next_gauge)
  return true, next_gauge
end

function M.lifecycle_glyph(lifecycle)
  return lifecycle == "running" and "⌛︎"
    or lifecycle == "parked" and "💤"
    or lifecycle == "completed" and "⏹️"
    or lifecycle == "cancelled" and "✋"
    or lifecycle == "failed" and "❌"
    or ""
end

function M.activity_text(activity)
  if type(activity) ~= "table" then return nil end
  if type(activity.percent) == "number" then return tostring(activity.percent) .. "%" end
  return activity.label
end

return M
