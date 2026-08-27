-- Membership gutter signs. On entering a project file (and after any members
-- mutation), ask the daemon what each visible project file resolves to —
-- worker.members.discover on its project-relative path — and place a line-1
-- gutter sign for that VERDICT — daemon-resolved, ZERO client glob-matching
-- (the daemon owns git + the overlay; the client only signs what it's told).
-- Only the EXCEPTION is signed — a member (the default) gets nothing, and an
-- untracked or ignored file is dark by default, so the gutter stays quiet:
--   excluded  🚫  — a file a `!glob` definition removed from membership
-- No cache: the daemon is co-located, so discover is a cheap local call on
-- each BufEnter (membership is not money — nothing here is worth staleness).
local M = {}
local ns = vim.api.nvim_create_namespace("plurnk_membership_signs")

-- Safe width-2 plane-1 emoji (the width-stable glyph discipline — NOT BMP
-- ornament emoji that a font may render width-1). Operator-pickable.
local SIGN = {
  excluded = { text = "🚫", hl = "PlurnkSignExcluded" },
}

M.setup_highlights = function()
  pcall(vim.api.nvim_set_hl, 0, "PlurnkSignExcluded", { fg = "#666666", default = true })  -- grey
end

local function place(bufnr, kind)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local s = kind and SIGN[kind]  -- member / candidate / ignored / nil → no sign (the quiet default)
  if not s then return end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, 0, 0, { sign_text = s.text, sign_hl_group = s.hl })
end

-- The project-relative path of one real file buffer; nil for scratch /
-- scheme buffers (only real project files carry membership).
local function project_path(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return nil end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or name:match("^%a[%w+.-]*://") then return nil end
  if vim.bo[bufnr].buftype ~= "" then return nil end
  return require("plurnk.state").get_relative_path(name)
end

-- Ask the daemon's verdict for one buffer → sign it. A refusal (a headless
-- workspace has no file members) leaves the gutter quiet.
local function sign_buf(bufnr, path)
  require("plurnk.client").send("worker.members.discover", { query = path }, false, function(result)
    if type(result) ~= "table" or type(result.candidates) ~= "table" then return end
    local candidate = result.candidates[1]
    local provenance = type(candidate) == "table" and type(candidate.provenance) == "table" and candidate.provenance or {}
    place(bufnr, provenance.kind)
  end, { quiet = true })
end

-- Re-sign every visible project buffer. No cache: called on BufEnter and after
-- every members mutation.
M.refresh = function(workspace)
  if not workspace then return end
  local seen = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local bufnr = vim.api.nvim_win_get_buf(win)
    if not seen[bufnr] then
      seen[bufnr] = true
      local path = project_path(bufnr)
      if path then sign_buf(bufnr, path) end
    end
  end
end

M.setup = function()
  M.setup_highlights()
  local grp = vim.api.nvim_create_augroup("PlurnkMembershipSigns", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = grp,
    callback = function()
      local workspace = require("plurnk.state").get_active_workspace_name()
      if workspace then M.refresh(workspace) end
    end,
  })
end

return M
