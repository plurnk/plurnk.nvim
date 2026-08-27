-- -- Membership gutter signs: worker.members.discover on each visible project
-- file → a line-1 extmark sign for the EXCEPTION only (excluded 🚫); a
-- member, an untracked candidate, and an ignored file get NO sign (the quiet
-- default), and a refused verdict raises nothing.
local NAME = "27_signs"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local state = require("plurnk.state")
  state.set_active_workspace_name("s")
  state.set_project_path("/proj")

  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, "/proj/src/a.lua")
  vim.bo[buf].buftype = ""
  vim.api.nvim_set_current_buf(buf)

  local ns = vim.api.nvim_create_namespace("plurnk_membership_signs")
  local signs = require("plurnk.signs")
  signs.setup_highlights()

  local verdict, asked = nil, {}
  require("plurnk.client").send = function(method, params, _, cb, options)
    asked[#asked + 1] = { method = method, params = params, options = options }
    if method == "worker.members.discover" and cb then cb(verdict) end
  end

  local function sign_for(kind)
    verdict = kind and { candidates = { { alias = "a-lua", definition = { glob = "src/a.lua" }, provenance = { kind = kind, source = "src/a.lua" } } } } or nil
    signs.refresh("s")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    if #marks == 0 then return nil end
    return marks[1][4].sign_text, marks[1][4].sign_hl_group
  end

  -- excluded → 🚫 / PlurnkSignExcluded
  local txt, hl = sign_for("excluded")
  H.assert_match(txt, "🚫", "excluded → 🚫 sign")
  H.assert_eq(hl, "PlurnkSignExcluded", "excluded highlight")
  H.assert_truthy(vim.deep_equal(asked[1], {
    method = "worker.members.discover",
    params = { query = "src/a.lua" },
    options = { quiet = true },
  }), "the daemon is asked about the project-relative path, quietly")

  -- member → NO sign (a member is the quiet default — only the exception signs)
  txt = sign_for("member")
  H.assert_truthy(txt == nil, "a member gets no sign")

  -- candidate (untracked) and ignored → NO sign (dark by default, resolved daemon-side)
  txt = sign_for("candidate")
  H.assert_truthy(txt == nil, "an untracked candidate gets no sign")
  txt = sign_for("ignored")
  H.assert_truthy(txt == nil, "an ignored file gets no sign")

  -- a refused verdict (a headless workspace) → the last verdict stands, nothing raised
  sign_for("excluded")
  txt = sign_for(nil)
  H.assert_match(txt, "🚫", "a refused verdict leaves the last verdict standing and raises nothing")
  txt = sign_for("member")
  H.assert_truthy(txt == nil, "the next verdict replaces it")

  -- only real project files are asked about: a scheme buffer sends nothing
  asked = {}
  local scratch = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(scratch, "plurnk-nvim://workspace/x")
  vim.api.nvim_set_current_buf(scratch)
  signs.refresh("s")
  H.assert_eq(#asked, 0, "a scheme buffer is never asked about")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
