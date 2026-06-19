-- Membership gutter signs (svc#243). On entering a project file, place a
-- single line-1 gutter sign showing its RESOLVED membership effect from
-- session.members — daemon-resolved, ZERO client glob-matching (the daemon owns
-- git + the overlay; the client only signs what it's told):
--   member  ● green  — in the model's universe, editable
--   view    ◐ amber  — a member, but read-only to the model (/view)
--   hidden  ○ grey   — a tracked file the model can't see (/hide)
-- A non-member project file (untracked, un-picked) gets no sign.
local M = {}
local ns = vim.api.nvim_create_namespace("plurnk_membership_signs")

local SIGN = {
  member = { text = "●", hl = "PlurnkSignMember" },
  view   = { text = "◐", hl = "PlurnkSignView" },
  hidden = { text = "○", hl = "PlurnkSignHidden" },
}

M.setup_highlights = function()
  -- member green = the #148800 conversation band; view amber; hidden grey.
  pcall(vim.api.nvim_set_hl, 0, "PlurnkSignMember", { fg = "#148800", default = true })
  pcall(vim.api.nvim_set_hl, 0, "PlurnkSignView",   { fg = "#b8a200", default = true })
  pcall(vim.api.nvim_set_hl, 0, "PlurnkSignHidden", { fg = "#666666", default = true })
end

-- session name → { by_path = {["/rel"]=effect}, hidden = {["/rel"]=true} }.
local cache = {}

local function effect_for(session, rel)
  local c = cache[session]
  if not c then return nil end
  if c.hidden[rel] then return "hidden" end
  return c.by_path[rel]
end

local function place(bufnr, effect)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local s = effect and SIGN[effect]
  if not s then return end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, 0, 0, { sign_text = s.text, sign_hl_group = s.hl })
end

-- Resolve + sign one buffer from the cache. Skips scratch / scheme buffers.
local function sign_buf(bufnr, session)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or name:match("^%a[%w+.-]*://") then return end
  if vim.bo[bufnr].buftype ~= "" then return end
  local rel = "/" .. require("plurnk.state").get_relative_path(name)
  place(bufnr, effect_for(session, rel))
end

-- Fetch session.members → cache → re-sign every visible project buffer. Call
-- after membership changes (pick/hide/view/repo/drop) for live feedback.
M.refresh = function(session)
  if not session then return end
  require("plurnk.client").send("session.members", {}, false, function(result)
    if type(result) ~= "table" then return end
    local by_path, hidden = {}, {}
    for _, m in ipairs(result.members or {}) do by_path[m.path] = m.effect end
    for _, p in ipairs(result.hidden or {}) do hidden[p] = true end
    cache[session] = { by_path = by_path, hidden = hidden }
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      sign_buf(vim.api.nvim_win_get_buf(win), session)
    end
  end)
end

M.setup = function()
  M.setup_highlights()
  local grp = vim.api.nvim_create_augroup("PlurnkMembershipSigns", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = grp,
    callback = function(args)
      local session = require("plurnk.state").get_active_session_name()
      if not session then return end
      -- Cold cache → one fetch (signs everything); warm → cheap local sign.
      if cache[session] then sign_buf(args.buf, session) else M.refresh(session) end
    end,
  })
end

return M
