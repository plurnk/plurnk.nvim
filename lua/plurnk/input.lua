-- Chat input scratch buffer. Lives at the bottom of the session tab.
-- Vim-canonical: <CR> from NORMAL mode submits. The user enters insert
-- mode with `i`/`a`/`o` like any other buffer, leaves with <Esc>, then
-- hits <CR> to send. Window nav is `<C-w>k` (vim's own), not a custom
-- shortcut. We don't `startinsert` on open either — the user chooses
-- their mode.

local M = {}
local INPUT_HEIGHT = 3

local function buffer_name(session_name, run_id)
  return "plurnk://input/" .. (session_name or "scratch") .. "/" .. (run_id or "pending")
end

local function submit(buf, session_name)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = vim.fn.trim(table.concat(lines, "\n"))
  if text == "" then return end

  -- Raw DSL passthrough (TUI parity, plurnk SPEC §3.1): input starting
  -- `<<` goes to op.parse — the daemon parses and dispatches each
  -- statement as actions of one turn; results arrive as log/entry.
  if text:sub(1, 2) == "<<" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    require("plurnk.client").send("op.parse", { text = text }, false)
    return
  end

  -- Strip rummy mode prefixes that users still reach for out of habit
  -- (?, :, ! — plurnk has no modes, the model decides what ops to emit).
  text = text:gsub("^[%?%:%!]+%s*", "")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })

  -- Ensure plurnk_session is bound to this buffer so commands.prompt's
  -- active_session() picks it up — the buffer-local var is the source
  -- of truth for which session the prompt is going to.
  if session_name then vim.b[buf].plurnk_session = session_name end

  -- Prompts go to the connection's BOUND run. Submitting in another
  -- run's input means "switch to that run, then speak" — rebind first.
  local target_run = vim.b[buf].plurnk_run_id
  local current_run = session_name and require("plurnk.state").get_run_id(session_name)
  if target_run and current_run and target_run ~= current_run then
    require("plurnk.commands").switch_run(session_name, target_run, function()
      require("plurnk.commands").prompt({ args = text, range = 0 })
    end)
    return
  end

  require("plurnk.commands").prompt({ args = text, range = 0 })
end

-- Decorate the input window (no numbers, wrap on, fixed-height). No
-- winbar: it spent a third of the 3-line split on a static hint; the
-- session identity lives on the waterfall winbar, <CR> submit lives in
-- the docs. All 3 rows are for typing.
local function decorate_input_win(win)
  vim.wo[win].wrap = true
  vim.wo[win].winfixheight = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = true
end

local function bind_keymaps(buf, session_name)
  vim.keymap.set("n", "<CR>", function() submit(buf, session_name) end,
    { buffer = buf, silent = true, desc = "Plurnk: submit prompt" })
end

-- Create the input split in the CURRENT tab (assumes the waterfall
-- window is already set up — called from run_tab.open). One input per
-- (session, run); run_id may be nil pre-resolution (run_tab adopts the
-- record and restamps plurnk_run_id when the id is learned). Returns
-- buf, win.
M.create_in_tab = function(session_name, run_id)
  -- Reuse an existing input buffer for this (session, run).
  local existing = vim.fn.bufnr(buffer_name(session_name, run_id))
  local buf
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    buf = existing
  else
    buf = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, buf, buffer_name(session_name, run_id))
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
  end

  vim.cmd("botright " .. INPUT_HEIGHT .. "split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  decorate_input_win(win)

  if session_name then vim.b[buf].plurnk_session = session_name end
  if run_id then vim.b[buf].plurnk_run_id = run_id end
  bind_keymaps(buf, session_name)
  return buf, win
end

-- Back-compat wrapper. Called by `:AI` (no args) — opens the full
-- run-tab layout (waterfall on top, input on the bottom) and focuses
-- the input. If no session is attached, the caller is expected to
-- resolve one first; if none was passed we just open a scratch input.
M.open = function(session_name)
  if session_name then
    require("plurnk.run_tab").open(session_name)
    return
  end
  -- No session — fallback: a lone scratch input split. This path is
  -- used very early in :AI flows before session.create returns.
  vim.cmd("botright " .. INPUT_HEIGHT .. "split")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, buffer_name(nil))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.api.nvim_win_set_buf(win, buf)
  decorate_input_win(win)
  bind_keymaps(buf, nil)
  return buf
end

return M
