# plurnk.nvim

Neovim client for [plurnk-service](https://github.com/plurnk/plurnk-service), the AI agent daemon. Talks JSON-RPC 2.0 over WebSocket directly from inside Neovim — no subprocess shelling out to the `@plurnk/plurnk` CLI, no embedded Node.

> [!NOTE]
> Requires a running [plurnk-service](https://github.com/plurnk/plurnk-service) (default `localhost:3044`). See the service repo for setup.

## Status

v0.3.0 — full rummy-parity command surface: `:AI` with rummy mode-prefix passthrough, buffer-agnostic proposal review commands, chat input scratch buffer. Glyph waterfall, polished statusline, `:diffsplit` proposals, headless e2e suite all carry over from v0.2.0. The virtual-text HUD and deeper `:checkhealth` are still being ported from rummy.nvim.

## Architecture

Same pattern as [rummy.nvim](https://github.com/possumtech/rummy.nvim) — the deliberate trick for keeping off Neovim's main event loop:

```
   main nvim  ←─stdio JSON-RPC─→  background headless nvim  ←─WebSocket─→  plurnk-service
```

The background nvim holds the WebSocket via `vim.loop`/libuv; the main nvim only ever reads and writes JSON-RPC frames over stdio. Main nvim never touches the socket directly, never blocks on I/O.

## Commands

| Command | What |
|---|---|
| `:AI` | Open the chat input scratch buffer scoped to the current session. |
| `:AI {text}` | Submit `{text}` as a prompt (alias of `:PlurnkPrompt`). |
| `:AI? {text}` / `:AI: {text}` / `:AI! {text}` | Same as `:AI {text}` — the rummy mode prefixes are stripped (plurnk has no modes; the model decides what ops to emit). |
| `:AI?? {text}` | Create a fresh session, then submit `{text}`. |
| `:AI/stop`, `:AI/clear` | Cancel all currently pending proposals on this connection. |
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
| `:PlurnkAccept` / `:PlurnkAcceptEdits` / `:PlurnkReject` | Resolve the current proposal as accept-as-proposed / accept-with-edits / reject — works from any buffer. |
| `:PlurnkNext` / `:PlurnkPrev` | Step through the pending-proposal stack. |

## Installation

```lua
-- lazy.nvim
{
  "plurnk/plurnk.nvim",
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
  config = function()
    require("plurnk").setup()
    require("plurnk").apply_default_keymaps()
  end,
}
```

## Default keymaps

`apply_default_keymaps()` binds (only if the keys aren't already mapped):

The layout mirrors [rummy.nvim](https://github.com/possumtech/rummy.nvim) so muscle memory carries over. Plurnk strips rummy's mode prefixes (`?`/`:`/`!`) because plurnk has no mode taxonomy.

| Key | Mode | Command |
|---|---|---|
| `<leader>aa` | n, x | `:AI<CR>` — open chat input |
| `<leader>a?` | n, x | `:AI? ` — prompt (rummy "ask") |
| `<leader>a:` | n, x | `:AI: ` — prompt (rummy "act") |
| `<leader>a!` | n, x | `:AI! ` — prompt (rummy "run") |
| `<leader>aN` | n | `:AI?? ` — fresh session + prompt |
| `<leader>ax` | n | `:AI/stop` — cancel pending proposals |
| `<leader>aX` | n | `:AI/clear` — cancel pending proposals |
| `<leader>am` | n | `:PlurnkModels` |
| `<leader>as` | n | `:PlurnkSessions` |
| `<leader>aR` | n | `:PlurnkSessionRuns` |
| `<leader>aP` | n | `:PlurnkPersona ` |
| `<leader>aL` | n | `:PlurnkLog` |
| `<leader>aO` | n | `:PlurnkOpen` |
| `<leader>aY` | n | `:PlurnkYolo` |
| `<leader>ay` | n | `:PlurnkAccept` |
| `<leader>ae` | n | `:PlurnkAcceptEdits` |
| `<leader>an` | n | `:PlurnkReject` |
| `<leader>a]` | n | `:PlurnkNext` |
| `<leader>a[` | n | `:PlurnkPrev` |

## Statusline

```lua
vim.opt.statusline = "%f %h%w%m%r %=%{v:lua.require('plurnk').statusline()} %y %l/%L"
```

Reports the buffer's bound session, current model alias, current loop id, and final status when present.

## Requirements

- Neovim ≥ 0.10
- A running [plurnk-service](https://github.com/plurnk/plurnk-service)

## Distribution

This plugin does **not** publish to npm. It's installed via your Neovim plugin manager from the GitHub repo, like every other Neovim plugin.

## Roadmap

Still to port from [rummy.nvim](https://github.com/possumtech/rummy.nvim):

- Virtual-text HUD per-buffer
- `:checkhealth plurnk` deeper checks (provider config, model alias resolution, etc.)

Ported as of v0.2.0:

- Glyph waterfall renderer shared with the npm `@plurnk/plurnk` TUI (🤖 ✏️ 📖 🔍 ✉️ ⚙️ 📋 📦 ➕ ➖) — `lua/plurnk/render.lua`.
- `:diffsplit`-based proposal review with accept-as-proposed / accept-with-edits / reject / cancel — `lua/plurnk/resolve.lua`.
- Polished statusline reporting session, model, loop·turn, status glyph, cost, and YOLO state.
- Inline telemetry (`📡 source:kind`) in the session waterfall.
- Isolated-XDG `demo.sh` for trying the plugin without touching your real config.
- Headless e2e test suite under `tests/specs/` driven by `tests/runner.sh`.

Ported as of v0.1.1:

- Streaming (`stream/event` + `stream/concluded`) — daemon-pushed channel growth is fetched via `entry.read` and rendered into a split.

## License

MIT.
