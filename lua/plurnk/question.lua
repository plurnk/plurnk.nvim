-- {§nvim-question-forms}: collect the exact response-schema payload.
local M = {}

function M.choices(schema)
  local out = {}
  for _, choice in ipairs(schema["enum"] or {}) do
    if type(choice) == "string" then out[#out + 1] = choice end
  end
  return out
end

local function parse_value(text, schema)
  local kind = schema.type
  if kind == nil or kind == "string" then return text end
  local ok, value = pcall(vim.json.decode, text)
  local matches = ok and (
    (kind == "integer" and type(value) == "number" and value % 1 == 0)
    or (kind == "number" and type(value) == "number")
    or (kind == "boolean" and type(value) == "boolean")
    or (kind == "array" and type(value) == "table" and vim.islist(value))
    or (kind == "object" and type(value) == "table" and not vim.islist(value)))
  if not matches then return nil, "requires a JSON " .. tostring(kind) .. " value" end
  return value
end

function M.review(workspace_name, interaction)
  if type(interaction) ~= "table" or type(interaction.interactionId) ~= "number" then return end
  local req = interaction.request or {}
  local message = type(req.message) == "string" and req.message or "Provide the requested input."
  local schema = type(req.responseSchema) == "table" and req.responseSchema or {}
  local properties = schema.properties or {}
  local keys = vim.tbl_keys(properties)
  table.sort(keys)
  local required = {}
  for _, key in ipairs(schema.required or {}) do required[key] = true end
  local content = vim.empty_dict()
  local bridge = require("plurnk.bridge")

  local function send(payload)
    bridge.resolve_interaction(workspace_name, interaction.interactionId, payload, function(_, problem)
      if problem ~= nil then
        vim.notify("Question answer failed: " .. (problem.detail or problem.message or vim.inspect(problem)), vim.log.levels.ERROR)
      end
    end)
  end

  local function field(index)
    local key = keys[index]
    if key == nil and #keys > 0 then
      send(content)
      return
    end
    local property = key ~= nil and properties[key] or {}
    local label = property.title and property.title .. " (" .. key .. ")" or key
    local hint = required[key] and "required" or "optional; Enter skips"
    local kind = type(property.type) == "string" and property.type .. "; " or ""
    local description = property.description and " — " .. property.description or ""
    local prompt = key == nil and "Press Enter to submit the empty form"
      or label .. " (" .. kind .. hint .. ")" .. description
    local function accept(input)
      if input == nil then send("cancel"); return end
      local text = vim.trim(input)
      if text == "" and key ~= nil and required[key] then
        vim.notify(key .. " is required.", vim.log.levels.WARN)
        field(index)
        return
      end
      if text ~= "" then
        local value, problem = parse_value(text, property)
        if key == nil or problem ~= nil then
          vim.notify(key == nil and prompt or key .. " " .. problem .. ".", vim.log.levels.WARN)
          field(index)
          return
        end
        content[key] = value
      end
      if key == nil then send(content)
      else field(index + 1) end
    end
    local function free_response()
      vim.ui.input({ prompt = message .. " — " .. prompt .. ": " }, accept)
    end
    local choices = M.choices(property)
    if #choices == 0 then free_response(); return end
    local items = vim.list_extend({}, choices)
    items[#items + 1] = "Free Response…"
    vim.ui.select(items, { prompt = message .. " — " .. prompt }, function(choice)
      if choice == "Free Response…" then free_response() else accept(choice) end
    end)
  end
  field(1)
end

return M
