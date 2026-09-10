-- {§question-tool}: exercise native form callbacks through the interaction bridge.
local NAME = "34_question"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()
local original_input, original_select, original_notify = vim.ui.input, vim.ui.select, vim.notify
local bridge = require("plurnk.bridge")
local original_resolve = bridge.resolve_interaction

local ok, err = pcall(function()
  local question = require("plurnk.question")

  local sent, prompts, notifications, replies = {}, {}, {}, {}
  local transport_error
  vim.notify = function(message) notifications[#notifications + 1] = message end
  vim.ui.input = function(opts, cb)
    prompts[#prompts + 1] = opts.prompt
    local reply = table.remove(replies, 1)
    if reply == vim.NIL then cb(nil) else cb(reply) end
  end
  bridge.resolve_interaction = function(world, id, payload, cb)
    H.assert_eq(world, "question-world")
    H.assert_eq(id, 42)
    sent[#sent + 1] = payload
    cb(transport_error == nil and 0 or nil, transport_error)
  end
  local function review(schema, answers)
    replies = answers
    question.review("question-world", { interactionId = 42, request = {
      message = "Which branch?", responseSchema = schema,
    } })
    H.assert_eq(#replies, 0, "all fields were presented")
  end

  review({ properties = { branch = { type = "string" }, credential = { type = "string" }, notes = { type = "string" } } },
    { "", "fixture-token", "" })
  H.assert_truthy(prompts[1]:match("branch") and prompts[2]:match("credential") and prompts[3]:match("notes"))
  H.assert_truthy(vim.deep_equal(sent[1], { credential = "fixture-token" }))

  review({ properties = { count = { type = "integer" }, enabled = { type = "boolean" } }, required = { "count" } },
    { "", "nope", "0", "false" })
  H.assert_match(notifications[1], "count is required")
  H.assert_match(notifications[2], "count requires a JSON integer")
  H.assert_truthy(vim.deep_equal(sent[2], { count = 0, enabled = false }))

  vim.ui.select = function(items, _, cb)
    H.assert_truthy(vim.deep_equal(items, { "main", "topic", "Free Response…" }))
    cb(items[2])
  end
  review({ properties = { branch = { type = "string", ["enum"] = { "main", "topic" } } } }, {})
  H.assert_eq(sent[3].branch, "topic")

  review({ properties = { branch = { type = "string" } } }, { vim.NIL })
  H.assert_eq(sent[4], "cancel", "dismissing the form resolves cancellation")

  review({ type = "object" }, { "unassigned text", "" })
  H.assert_eq(vim.json.encode(sent[5]), "{}", "empty content is an object, not a list")

  transport_error = { detail = "Connection closed." }
  review({ properties = { branch = { type = "string" } } }, { "main" })
  H.assert_match(notifications[#notifications], "Question answer failed: Connection closed")
end)

vim.ui.input, vim.ui.select, vim.notify = original_input, original_select, original_notify
bridge.resolve_interaction = original_resolve
if ok then H.finish(NAME) else H.fail(NAME, err) end
