-- {§question-tool} — the request-user-input answer flow. The interaction's
-- request carries the MCP2 form-elicitation shape { message, requestedSchema };
-- the answer is the standard payload { action = "accept", content = { ... } }.
-- A single-property schema gets the numbered-enum / free-text menu; a
-- multi-property schema expects typed JSON; dismiss leaves it pending.

local M = {}

-- The schema's single-property enum choices, if any. Multi-property or
-- non-enum schemas yield {} (the user types a JSON answer).
function M.choices(schema)
  local properties = type(schema) == "table" and schema.properties or nil
  if type(properties) ~= "table" then return {} end
  local keys = {}
  for k in pairs(properties) do keys[#keys + 1] = k end
  if #keys ~= 1 then return {} end
  local property = properties[keys[1]]
  local enums = type(property) == "table" and property["enum"] or nil
  if type(enums) ~= "table" then return {} end
  local out = {}
  for _, c in ipairs(enums) do
    if type(c) == "string" then out[#out + 1] = c end
  end
  return out
end

-- The content object for a typed answer. Single-property: { key = value }.
-- Multi-property: the parsed JSON object. nil → re-prompt.
function M.answer(line, schema)
  local t = (line or ""):match("^%s*(.-)%s*$")
  if t == "" then return nil end
  local properties = type(schema) == "table" and schema.properties or nil
  if type(properties) ~= "table" then return nil end
  local keys = {}
  for k in pairs(properties) do keys[#keys + 1] = k end
  if #keys == 1 then
    return { [keys[1]] = t }
  end
  local ok, parsed = pcall(vim.json.decode, t)
  if not ok or type(parsed) ~= "table" then return nil end
  return parsed
end

-- Present the question and answer through the standard interaction resume.
function M.review(workspace_name, interaction)
  if type(interaction) ~= "table" or type(interaction.interactionId) ~= "number" then return end
  local req = interaction.request or {}
  local message = type(req.message) == "string" and req.message or "Provide the requested input."
  local schema = type(req.responseSchema) == "table" and req.responseSchema or {}
  local bridge = require("plurnk.bridge")

  local function send(payload)
    bridge.resolve_interaction(workspace_name, interaction.interactionId, payload, function() end)
  end
  local function free_response()
    vim.ui.input({ prompt = message .. " (Free Response): " }, function(input)
      if input == nil or input == "" then return end
      local content = M.answer(input, schema)
      if content == nil then return end
      send({ action = "accept", content = content })
    end)
  end

  local choices = M.choices(schema)
  if #choices == 0 then free_response() return end
  local items = vim.list_extend({}, choices)
  items[#items + 1] = "Free Response…"
  vim.ui.select(items, { prompt = message }, function(choice)
    if choice == nil then return end
    if choice == "Free Response…" then free_response(); return end
    send({ action = "accept", content = M.answer(tostring(choice), schema) })
  end)
end

return M
