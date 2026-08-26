local M = {}

local cache = {}
local inflight = {}
local failures = {}
local renderer_checked = false
local renderer_path
local renderer_problem

local function source_lines(source)
  if source == "" then return {} end
  local normalized = source:gsub("\r\n", "\n")
  local lines = vim.split(normalized, "\n", { plain = true })
  if normalized:sub(-1) == "\n" then table.remove(lines) end
  return lines
end

local function projected(lines, indent)
  local output = {}
  for _, line in ipairs(lines) do output[#output + 1] = (indent or "") .. line end
  return { lines = output }
end

local function renderer()
  if not renderer_checked then
    renderer_checked = true
    local path = vim.fn.exepath("plurnk")
    if path == "" then
      renderer_problem = "plurnk executable not found"
    else
      -- An older client treats an unknown positional as a model prompt. Prove
      -- this exact local filter through its harmless help surface before any
      -- semantic model content is allowed to cross the process boundary.
      local result = vim.system({ path, "render", "--help" }, { text = true }):wait()
      if result.code == 0 and (result.stdout or ""):match(
          "^usage: plurnk render %[%-%-width <columns>%]\n") then
        renderer_path = path
      else
        renderer_problem = "plurnk executable does not expose the render filter"
      end
    end
  end
  return renderer_path
end

local function cache_key(source, width)
  return tostring(width) .. "\0" .. source
end

local function request(source, width, key, on_change)
  local executable = renderer()
  if not executable or cache[key] ~= nil then return end
  if inflight[key] then
    if type(on_change) == "function" then inflight[key][#inflight[key] + 1] = on_change end
    return
  end

  inflight[key] = type(on_change) == "function" and { on_change } or {}
  vim.system({ executable, "render", "--width", tostring(width) }, {
    stdin = source,
    text = true,
  }, function(result)
    vim.schedule(function()
      if result.code == 0 then
        cache[key] = source_lines(result.stdout or "")
      else
        cache[key] = false
        if not failures[key] then
          failures[key] = true
          local detail = vim.trim(result.stderr or "")
          vim.notify(
            "plurnk: local Markdown projection failed; showing source"
              .. (detail == "" and "" or (": " .. detail)),
            vim.log.levels.WARN
          )
        end
      end

      local waiters = inflight[key] or {}
      inflight[key] = nil
      for _, callback in ipairs(waiters) do callback() end
    end)
  end)
end

M.looks_like_markdown = function(source)
  if type(source) ~= "string" then return false end
  return source:match("^%s*#+%s") ~= nil
    or source:match("\n%s*#+%s") ~= nil
    or source:match("^%s*[-*+]%s") ~= nil
    or source:match("\n%s*[-*+]%s") ~= nil
    or source:match("^%s*%d+[.)]%s") ~= nil
    or source:match("\n%s*%d+[.)]%s") ~= nil
    or source:match("```[%w_-]*") ~= nil
    or source:match("~~~[%w_-]*") ~= nil
    or source:match("|.-|%s*\n%s*|?%s*:?-+") ~= nil
    or source:match("%[.-%]%([^)]+%)") ~= nil
    or source:match("%*%*.-%*%*") ~= nil
end

M.render = function(source, width, indent, on_change)
  if type(source) ~= "string" then error("Markdown source must be a string", 0) end
  local columns = math.max(1, math.floor(width or 80))
  local key = cache_key(source, columns)
  local cached = cache[key]
  if type(cached) == "table" then return projected(cached, indent) end

  request(source, columns, key, on_change)
  return projected(source_lines(source), indent)
end

M.available = function()
  local executable = renderer()
  return executable ~= nil, executable, renderer_problem
end

M.setup = function() end

M.reset = function()
  cache = {}
  inflight = {}
  failures = {}
  renderer_checked = false
  renderer_path = nil
  renderer_problem = nil
end

return M
