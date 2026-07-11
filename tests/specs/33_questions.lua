-- [§nvim-questions]
-- #346: SEND[300] questions via the proposal path. process() detects a SEND
-- carrying attrs {question, choices}, picks via vim.ui.select (+ a Free Response
-- escape) or vim.ui.input, and resolves loop.resolve with decision=accept +
-- body=answer. Even a yolo loop stops the world — never auto-answered.
local NAME = "33_questions"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local resolve = require("plurnk.resolve")

  -- Pure detection
  H.assert_eq(resolve.question_from_proposal({ op = "EDIT", attrs = { question = "x" } }), nil, "non-SEND → nil")
  H.assert_eq(resolve.question_from_proposal({ op = "SEND", attrs = {} }), nil, "no attrs.question → nil")
  local q = resolve.question_from_proposal({ op = "SEND", attrs = { question = "Which?", choices = { "A", "B" } } })
  H.assert_eq(q.question, "Which?", "question extracted")
  H.assert_eq(#q.choices, 2, "choices extracted")
  H.assert_eq(#resolve.question_from_proposal({ op = "SEND", attrs = { question = "Name?" } }).choices, 0, "open → no choices")

  local captured = {}
  require("plurnk.client").send = function(method, params) table.insert(captured, { method = method, params = params }) end

  -- Multiple choice: pick the 2nd option → body = its text
  vim.ui.select = function(items, _, cb) cb(items[2]) end
  resolve.process("smoke", { logEntryId = 7, op = "SEND", attrs = { question = "Which?", choices = { "Alpha", "Beta" } } })
  H.assert_eq(#captured, 1, "one resolve sent for a pick")
  H.assert_eq(captured[1].method, "loop.resolve", "loop.resolve")
  H.assert_eq(captured[1].params.decision, "accept", "accept")
  H.assert_eq(captured[1].params.body, "Beta", "body = chosen option text")

  -- Free Response escape: last item → input → body = typed text
  captured = {}
  vim.ui.select = function(items, _, cb) cb(items[#items]) end
  vim.ui.input = function(_, cb) cb("actually, neither") end
  resolve.process("smoke", { logEntryId = 8, op = "SEND", attrs = { question = "Which?", choices = { "Alpha", "Beta" } } })
  H.assert_eq(captured[1].params.body, "actually, neither", "free response body = typed text")

  -- Open question (no choices) → straight to input
  captured = {}
  vim.ui.input = function(_, cb) cb("Bilbo") end
  resolve.process("smoke", { logEntryId = 9, op = "SEND", attrs = { question = "Name?" } })
  H.assert_eq(captured[1].params.body, "Bilbo", "open question body")

  -- YOLO never auto-answers: a question still prompts (not a client_yolo accept)
  captured = {}
  local diff = require("plurnk.diff")
  diff.is_yolo = function() return true end
  vim.ui.select = function(items, _, cb) cb(items[1]) end
  resolve.process("smoke", { logEntryId = 10, op = "SEND", attrs = { question = "Which?", choices = { "Alpha" } } })
  H.assert_eq(captured[1].params.body, "Alpha", "yolo still prompts (not auto-accepted)")
  H.assert_eq(captured[1].params.outcome, nil, "not a client_yolo auto-accept")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
