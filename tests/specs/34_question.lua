-- -- {§question-tool} — the request-user-input answer mapping: the schema's
-- -- single-property enum choices surface; typed answers land as the standard
-- -- content object; multi-property schemas expect raw JSON.
local NAME = "34_question"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local question = require("plurnk.question")

  local enum_schema = { properties = { branch = { type = "string", ["enum"] = { "main", "feat/x" } } } }
  H.assert_eq(table.concat(question.choices(enum_schema), ","), "main,feat/x", "single-property enum choices surface")

  H.assert_eq(#question.choices({ properties = {} }), 0, "no properties → no choices")
  H.assert_eq(#question.choices({}), 0, "empty schema → no choices")
  H.assert_eq(#question.choices({ properties = { a = { type = "string" }, b = { type = "string" } } }), 0, "multi-property → no choices")

  H.assert_eq(question.answer("main", enum_schema).branch, "main", "the single property's value lands the content object")
  H.assert_eq(question.answer("anything", enum_schema).branch, "anything", "free text rides the single property")
  H.assert_eq(question.answer("   ", enum_schema), nil, "empty → re-prompt")
  H.assert_eq(question.answer("nope", { properties = { a = { type = "string" } } }).a, "nope", "single-property without enums still answers")

  local multi = { properties = { a = { type = "string" }, b = { type = "string" } } }
  local parsed = question.answer('{"a":"x","b":"y"}', multi)
  H.assert_eq(parsed.a, "x", "multi-property schema takes typed JSON")
  H.assert_eq(question.answer("not json", multi), nil, "invalid JSON → re-prompt")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
