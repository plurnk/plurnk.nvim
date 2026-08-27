-- Optional default mappings. Each mode is filled independently, never
-- overwritten; the same inventory drives setup diagnostics and checkhealth.

local M = {}
local registry = require("plurnk.command_registry")
local enabled = false

local function describe(command)
  return "Plurnk: " .. registry.summary(command)
end

local MAPS = {
  { modes = { "n" }, lhs = "<leader>aa", rhs = ":AI<CR>", desc = describe("open") },
  { modes = { "n", "x" }, lhs = "<leader>a?", rhs = ":AI? ", desc = "Plurnk: ask prompt" },
  { modes = { "n", "x" }, lhs = "<leader>a:", rhs = ":AI: ", desc = "Plurnk: act prompt" },
  { modes = { "n", "x" }, lhs = "<leader>a!", rhs = ":AI! ", desc = "Plurnk: exec command" },
  { modes = { "n" }, lhs = "<leader>aN", rhs = ":AI?? ", desc = describe("workspace") },
  { modes = { "n" }, lhs = "<leader>af", rhs = ":PlurnkFork<CR>", desc = describe("worker") },
  { modes = { "n" }, lhs = "<leader>ax", rhs = ":AI/stop<CR>", desc = describe("stop") },
  { modes = { "n" }, lhs = "<leader>aX", rhs = ":AI/clear<CR>", desc = describe("clear") },

  { modes = { "n" }, lhs = "<leader>am", rhs = ":PlurnkModels<CR>", desc = describe("models") },
  { modes = { "n" }, lhs = "<leader>as", rhs = ":PlurnkWorkspaces<CR>", desc = describe("workspaces") },
  { modes = { "n" }, lhs = "<leader>aR", rhs = ":PlurnkWorkspaceWorkers<CR>", desc = describe("workers") },
  { modes = { "n" }, lhs = "<leader>aL", rhs = ":PlurnkLog<CR>", desc = describe("log") },
  { modes = { "n" }, lhs = "<leader>aO", rhs = ":PlurnkOpen<CR>", desc = describe("open") },
  { modes = { "n" }, lhs = "<leader>aY", rhs = ":PlurnkYolo<CR>", desc = describe("yolo") },

  { modes = { "n" }, lhs = "<leader>aM", rhs = ":PlurnkMembers<CR>", desc = describe("members") },

  { modes = { "n" }, lhs = "<leader>ay", rhs = ":PlurnkAccept<CR>", desc = describe("accept") },
  { modes = { "n" }, lhs = "<leader>ae", rhs = ":PlurnkAcceptEdits<CR>", desc = describe("edit") },
  { modes = { "n" }, lhs = "<leader>an", rhs = ":PlurnkReject<CR>", desc = describe("reject") },
  { modes = { "n" }, lhs = "<leader>a]", rhs = ":PlurnkNext<CR>", desc = describe("next") },
  { modes = { "n" }, lhs = "<leader>a[", rhs = ":PlurnkPrev<CR>", desc = describe("prev") },
}

local function mapping(lhs, mode)
  local exact = vim.fn.maparg(lhs, mode, false, true)
  if type(exact) == "table" and next(exact) ~= nil then return exact, true end
  local overlap = vim.fn.mapcheck(lhs, mode)
  if overlap ~= "" then return { rhs = overlap }, false end
  return nil, false
end

local function owner_of(value)
  if type(value) ~= "table" then return "unknown owner" end
  local script_name = nil
  if type(value.sid) == "number" and value.sid > 0 and vim.fn.exists("*getscriptinfo") == 1 then
    local ok, scripts = pcall(vim.fn.getscriptinfo, { sid = value.sid })
    local script = ok and type(scripts) == "table" and scripts[1] or nil
    if type(script) == "table" and type(script.name) == "string" and script.name ~= "" then
      script_name = script.name
    end
  end
  if type(value.desc) == "string" and value.desc ~= "" then
    return value.desc .. (script_name and (" (" .. script_name .. ")") or "")
  end
  if script_name then return script_name end
  if type(value.rhs) == "string" and value.rhs ~= "" then return value.rhs end
  return "unknown owner"
end

function M.inspect()
  local out = {}
  if not enabled then return out end
  for _, spec in ipairs(MAPS) do
    for _, mode in ipairs(spec.modes) do
      local current, exact = mapping(spec.lhs, mode)
      local status = current == nil and "missing"
        or (exact and current.rhs == spec.rhs) and "installed"
        or "conflict"
      out[#out + 1] = {
        mode = mode,
        lhs = spec.lhs,
        rhs = spec.rhs,
        desc = spec.desc,
        status = status,
        owner = status == "conflict" and owner_of(current) or nil,
      }
    end
  end
  return out
end

function M.enabled() return enabled end

function M.setup()
  enabled = true
  local conflicts = 0
  for _, spec in ipairs(MAPS) do
    for _, mode in ipairs(spec.modes) do
      local current, exact = mapping(spec.lhs, mode)
      if current == nil then
        vim.keymap.set(mode, spec.lhs, spec.rhs, { silent = false, desc = spec.desc })
      elseif not (exact and current.rhs == spec.rhs) then
        conflicts = conflicts + 1
      end
    end
  end
  if conflicts > 0 then
    vim.notify(string.format(
      "plurnk: %d default mapping%s skipped because the key is already owned; run :checkhealth plurnk",
      conflicts,
      conflicts == 1 and " was" or "s were"
    ), vim.log.levels.WARN)
  end
end

return M
