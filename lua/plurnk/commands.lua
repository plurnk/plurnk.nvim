-- Neovim command registration. Behavioral ownership lives in focused modules;
-- this file is the single installation point for the public command surface.

local M = {}

function M.setup()
  local command = vim.api.nvim_create_user_command
  local loop = require("plurnk.loop")
  local workspaces = require("plurnk.workspaces")
  local generation = require("plurnk.generation")
  local membership = require("plurnk.membership")
  local controls = require("plurnk.controls")
  local language = require("plurnk.language")

  command("PlurnkPrompt", loop.prompt, { nargs = "*", range = true })
  command("PlurnkWorkspaces", workspaces.list, {})
  command("PlurnkWorkspaceNew", workspaces.create, { nargs = "?" })
  command("PlurnkWorkspaceRename", workspaces.rename, { nargs = "?" })
  command("PlurnkFork", workspaces.fork, { nargs = "?" })
  command("PlurnkWorkspaceWorkers", workspaces.workers, {})
  command("PlurnkModels", generation.models, { nargs = "*" })
  command("PlurnkReasoning", function(opts)
    generation.set_reasoning(opts.args)
  end, { nargs = "?" })
  command("PlurnkLog", workspaces.log, { nargs = "?" })
  command("PlurnkReconnect", workspaces.reconnect, {})
  command("PlurnkPick", membership.pick, { nargs = "?", complete = "file" })
  command("PlurnkHide", membership.hide, { nargs = "?", complete = "file" })
  command("PlurnkView", membership.view, { nargs = "?", complete = "file" })
  command("PlurnkDrop", membership.drop, { nargs = "?", complete = "file" })
  command("PlurnkMembers", membership.list, {})
  command("PlurnkScript", controls.script, { nargs = 1, complete = "file" })
  command("PlurnkYolo", controls.yolo, {})
  command("PlurnkPing", controls.ping, {})
  command("PlurnkStop", controls.stop, {})
  command("PlurnkClear", controls.clear, {})
  command("PlurnkAccept", controls.accept, {})
  command("PlurnkAcceptEdits", controls.accept_edits, {})
  command("PlurnkReject", controls.reject, {})
  command("PlurnkNext", controls.next, {})
  command("PlurnkPrev", controls.prev, {})
  command("AI", language.run, {
    nargs = "*",
    range = true,
    bang = true,
    complete = language.complete,
  })

  vim.cmd([[
    function! PlurnkAIAbbrev(chars)
      if getcmdtype() == ':' && getcmdline() ==# 'AI' . a:chars
        return 'AI ' . a:chars
      endif
      return 'AI' . a:chars
    endfunction

    cabbrev <expr> AI?    PlurnkAIAbbrev('?')
    cabbrev <expr> AI??   PlurnkAIAbbrev('??')
    cabbrev <expr> AI???  PlurnkAIAbbrev('???')
    cabbrev <expr> AI???? PlurnkAIAbbrev('????')
    cabbrev <expr> AI:    PlurnkAIAbbrev(':')
    cabbrev <expr> AI::   PlurnkAIAbbrev('::')
    cabbrev <expr> AI:::  PlurnkAIAbbrev(':::')
    cabbrev <expr> AI:::: PlurnkAIAbbrev('::::')
    cabbrev <expr> AI!    PlurnkAIAbbrev('!')
    cabbrev <expr> AI!!   PlurnkAIAbbrev('!!')
    cabbrev <expr> AI!!!  PlurnkAIAbbrev('!!!')
    cabbrev <expr> AI!!!! PlurnkAIAbbrev('!!!!')
    cabbrev <expr> AI...  PlurnkAIAbbrev('...')
    cabbrev <expr> AI/    PlurnkAIAbbrev('/')
  ]])

  command("PlurnkOpen", function()
    local workspace = require("plurnk.workspace_context").active()
    if workspace then
      require("plurnk.worker_tab").open(workspace)
      return
    end
    workspaces.create({ args = "" })
  end, {})
end

return M
