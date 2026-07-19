-- Chat input scratch buffer. Lives at the bottom of the workspace tab.
-- Vim-canonical: <CR> from NORMAL mode submits; <Esc> drops to normal to
-- navigate/submit; window nav is `<C-w>k` (vim's own), not a custom shortcut.
-- We DO `startinsert` on open (operator, 2026-06-19): the box is always empty
-- and inserting is the only possible action, so requiring `i` first is a
-- pointless step even thinking in vim — not the same as forcing modal habits.

local M = {}
local INPUT_HEIGHT = 3

local function buffer_name(workspace_name, worker_id)
  return "plurnk-nvim://input/" .. (workspace_name or "scratch") .. "/" .. (worker_id or "pending")
end

-- Exposed so worker_tab can re-derive the input buffer's URI on workspace.rename
-- (the workspace is a mutable handle; its open buffers follow the new name).
M.buffer_name = buffer_name

local function submit(buf, workspace_name)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = vim.fn.trim(table.concat(lines, "\n"))
  if text == "" then return end

  -- <<LOOK — the off-worker inspection (TUI parity): a READ for the HUMAN, not the
  -- model. Routed to op.look (the module rewrites LOOK→READ; Engine.look mints no
  -- log row); content renders into the waterfall locally. A failed look SURFACES.
  if text:upper():sub(1, 6) == "<<LOOK" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    require("plurnk.client").send("op.look", { text = text }, false, function(result)
      local client = require("plurnk.client")
      if type(result) ~= "table" or type(result.content) ~= "string" then
        client.notify("look failed: " .. tostring(type(result) == "table" and (result.error or result.status) or "no result"), vim.log.levels.WARN)
        return
      end
      local worker_tab = require("plurnk.worker_tab")
      for line in (result.content .. "\n"):gmatch("(.-)\n") do
        worker_tab.append_line(workspace_name, "  " .. line)
      end
    end)
    return
  end

  -- Raw DSL passthrough (TUI parity, plurnk SPEC §3.1): input starting
  -- `<<` goes to op.parse — the daemon parses and dispatches each
  -- statement as actions of one turn; results arrive as log/entry.
  if text:sub(1, 2) == "<<" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    require("plurnk.client").send("op.parse", { text = text }, false)
    return
  end

  -- Verb surface, same as :AI/ — the input buffer IS the TUI inside vim;
  -- one language across both.
  if text:sub(1, 1) == "/" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    require("plurnk.commands").ai({ args = text, range = 0 })
    return
  end

  -- Prefix language, same as :AI — `?` is ASK (flags.mode="ask"; the
  -- engine 403s excludedInAsk schemes), `:` is act (default), `!` execs
  -- the rest through the daemon (op.exec).
  local first = text:sub(1, 1)
  if first == "!" then
    local cmd = text:gsub("^!+%s*", "")
    if cmd ~= "" then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
      require("plurnk.client").send("op.exec", { command = cmd }, false)
      return
    end
  end
  local flags = first == "?" and { mode = "ask" } or nil
  text = text:gsub("^[%?%:%!]+%s*", "")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })

  -- Ensure plurnk_workspace is bound to this buffer so commands.prompt's
  -- active_workspace() picks it up — the buffer-local var is the source
  -- of truth for which workspace the prompt is going to.
  if workspace_name then vim.b[buf].plurnk_workspace = workspace_name end

  -- Prompts go to the connection's BOUND worker. Submitting in another
  -- worker's input means "switch to that worker, then speak" — rebind first.
  local target_worker = vim.b[buf].plurnk_worker_id
  local current_worker = workspace_name and require("plurnk.state").get_worker_id(workspace_name)
  if target_worker and current_worker and target_worker ~= current_worker then
    require("plurnk.commands").switch_worker(workspace_name, target_worker, function()
      require("plurnk.commands").prompt({ args = text, range = 0, flags = flags })
    end)
    return
  end

  require("plurnk.commands").prompt({ args = text, range = 0, flags = flags })
end

-- Decorate the input window (no numbers, wrap on, fixed-height). No
-- winbar: it spent a third of the 3-line split on a static hint; the
-- workspace identity lives on the waterfall winbar, <CR> submit lives in
-- the docs. All 3 rows are for typing.
local function decorate_input_win(win)
  vim.wo[win].wrap = true
  vim.wo[win].winfixheight = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = true
end

local function bind_keymaps(buf, workspace_name)
  vim.keymap.set("n", "<CR>", function() submit(buf, workspace_name) end,
    { buffer = buf, silent = true, desc = "Plurnk: submit prompt" })
end

-- Create the input split in the CURRENT tab (assumes the waterfall
-- window is already set up — called from worker_tab.open). One input per
-- (workspace, worker); worker_id may be nil pre-resolution (worker_tab adopts the
-- record and restamps plurnk_worker_id when the id is learned). Returns
-- buf, win.
M.create_in_tab = function(workspace_name, worker_id)
  -- Reuse an existing input buffer for this (workspace, worker).
  local existing = vim.fn.bufnr(buffer_name(workspace_name, worker_id))
  local buf
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    buf = existing
  else
    buf = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, buf, buffer_name(workspace_name, worker_id))
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
  end

  vim.cmd("botright " .. INPUT_HEIGHT .. "split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  decorate_input_win(win)

  if workspace_name then vim.b[buf].plurnk_workspace = workspace_name end
  if worker_id then vim.b[buf].plurnk_worker_id = worker_id end
  bind_keymaps(buf, workspace_name)
  -- Fresh empty box → start in insert; the only possible action is to type.
  vim.cmd("startinsert")
  return buf, win
end

-- Back-compat wrapper. Called by `:AI` (no args) — opens the full
-- worker-tab layout (waterfall on top, input on the bottom) and focuses
-- the input. If no workspace is attached, the caller is expected to
-- resolve one first; if none was passed we just open a scratch input.
M.open = function(workspace_name)
  if workspace_name then
    require("plurnk.worker_tab").open(workspace_name)
    return
  end
  -- No workspace — fallback: a lone scratch input split. This path is
  -- used very early in :AI flows before workspace.create returns.
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
