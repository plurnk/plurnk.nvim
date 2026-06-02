# plurnk.nvim

Neovim client for [plurnk-service](https://github.com/plurnk/plurnk-service), the AI agent daemon. Talks JSON-RPC 2.0 over WebSocket directly from inside Neovim — no subprocess shelling out to the `@plurnk/plurnk` CLI, no embedded Node.

> [!NOTE]
> Requires a running [plurnk-service](https://github.com/plurnk/plurnk-service) (default `localhost:3044`). See the service repo for setup.

## Status

v0.1.0 — wire fully working, commands and basic transcript surface in place. The rich rummy.nvim UX (`:diffsplit` proposal resolution, statusline polish, virtual-text HUD, stream rendering) is being ported one piece at a time. See `:Plurnk*` commands below for what's wired today.

## Architecture

Same pattern as [rummy.nvim](https://github.com/possumtech/rummy.nvim) — the deliberate trick for keeping off Neovim's main event loop:

```
   main nvim  ←─stdio JSON-RPC─→  background headless nvim  ←─WebSocket─→  plurnk-service
```

The background nvim holds the WebSocket via `vim.loop`/libuv; the main nvim only ever reads and writes JSON-RPC frames over stdio. Main nvim never touches the socket directly, never blocks on I/O.

## Commands

| Command | What |
|---|---|
| `:PlurnkPrompt {text}` | Fire a `loop.run` with `{text}` (visual selection auto-prepended). Creates a session if needed. |
| `:PlurnkSessions` | Picker over `session.list`, attach to selection. |
| `:PlurnkSessionNew [name]` | Create a fresh session (`session.create`) with optional name. |
| `:PlurnkSessionRuns` | Picker over `session.runs` of the active session, attach the chosen run. |
| `:PlurnkModels` | Picker over `providers.list`. Selection feeds `alias` on the next `loop.run`. |
| `:PlurnkPersona [path]` | Set the persona file used on subsequent `loop.run`. No arg clears it. |
| `:PlurnkLog [limit]` | Show recent entries (`log.read`) from the active session in the session buffer. |
| `:PlurnkYolo` | Toggle client-side auto-accept of proposals. |
| `:PlurnkOpen` | Open (or focus) the active session's transcript tab. |
| `:PlurnkPing` | Sanity check the wire. |

## Installation

```lua
-- lazy.nvim
{
  "plurnk/plurnk.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  config = function()
    require("plurnk").setup({
      host = "127.0.0.1",
      port = 3044,
    })
    require("plurnk").apply_default_keymaps()
  end,
}
```

```lua
-- packer.nvim
use {
  "plurnk/plurnk.nvim",
  requires = { "nvim-lua/plenary.nvim" },
  config = function()
    require("plurnk").setup()
    require("plurnk").apply_default_keymaps()
  end,
}
```

## Default keymaps

`apply_default_keymaps()` binds (only if the keys aren't already mapped):

| Key | Mode | Command |
|---|---|---|
| `<leader>aa` | n, x | `:PlurnkPrompt ` |
| `<leader>am` | n | `:PlurnkModels` |
| `<leader>as` | n | `:PlurnkSessions` |
| `<leader>aR` | n | `:PlurnkSessionRuns` |
| `<leader>aY` | n | `:PlurnkYolo` |
| `<leader>aP` | n | `:PlurnkPersona ` |
| `<leader>aN` | n | `:PlurnkSessionNew` |
| `<leader>aL` | n | `:PlurnkLog` |
| `<leader>aO` | n | `:PlurnkOpen` |

## Statusline

```lua
vim.opt.statusline = "%f %h%w%m%r %=%{v:lua.require('plurnk').statusline()} %y %l/%L"
```

Reports the buffer's bound session, current model alias, current loop id, and final status when present.

## Requirements

- Neovim ≥ 0.10
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- A running [plurnk-service](https://github.com/plurnk/plurnk-service)

## Distribution

This plugin does **not** publish to npm. It's installed via your Neovim plugin manager from the GitHub repo, like every other Neovim plugin.

## Not in v0.1.0 (port roadmap)

- `:diffsplit`-based proposal review with accept-with-edits
- Streaming `stream/event` rendering
- Virtual-text HUD per-buffer
- Telemetry events rendered inline in the session waterfall (currently they fall back to `vim.notify`)
- Rich statusline with token counts and cost
- `:checkhealth plurnk` deeper checks (provider config, model alias resolution, etc.)

These were all present in [rummy.nvim](https://github.com/possumtech/rummy.nvim) and are being ported piece-by-piece.

## License

MIT.
