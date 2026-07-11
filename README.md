# plurnk.nvim

Neovim client for [plurnk-service](https://github.com/plurnk/plurnk-service). JSON-RPC 2.0 over WebSocket from inside Neovim; no Node, no CLI subprocess. The pitch: **use LLMs the vim way** — your buffers, your motions, your `:` line.

Requires: Neovim ≥ 0.10, a running plurnk-service daemon (default `127.0.0.1:3044`).

```lua
require("plurnk").setup({ host = "127.0.0.1", port = 3044 })
require("plurnk").apply_default_keymaps()  -- optional; only fills unmapped keys
```

## The `:AI` language

`:AI/` prints this table in-editor.

| Form | Effect |
|---|---|
| `:AI` | toggle session tab ⇄ where you came from |
| `:AI {text}` | prompt (act) |
| `:AI? {text}` | **ask** — read-only loop: `flags.mode="ask"`, the engine 403s edits/exec |
| `:AI: {text}` | act (the default) |
| `:AI! {cmd}` | exec `{cmd}` via the daemon; bare `:AI!` execs the visual selection |
| `:AI??` / `::` | new session, then prompt |
| `:AI???` | new headless session (no project root) |
| `:AI????` | new run in the current session (fork) |
| `:AI... {text}` | inject into the running loop (a mid-loop prompt steers too) |
| `:AI/{verb}` | `models sessions runs session run rename log yolo ping`, membership `pick hide view drop members`, `open accept reject next prev stop clear` |

Visual mode prepends the selection: `'<,'>AI? explain this`. No-space forms (`:AI?? hi`) work via cmdline abbreviations.

## Layout

One tab per **run** (a conversation); a **session** is the workspace containing runs. One session is live per Neovim instance; switching notifies. Each run tab: glyph waterfall on top (the run's log, exactly what the model sees), 3-line input below — `<CR>` in normal mode submits; `? `/`: `/`! ` prefixes and raw `<<DSL` work there too. Streams (exec output) open as `1│`/`2│`-prefixed splits; wiping a live stream buffer cancels it.

## Proposals

Side-effecting ops pause for review. EDIT opens a diffsplit (left disk, right proposed): `<localleader>a` accept, `<localleader>e` accept-with-edits, `r` reject, `c` cancel. EXEC opens a scratch: `a`/`r`/`c`. Global: `<leader>ay/ae/an`, `<leader>a]`/`a[` cycle pending, `:PlurnkYolo` auto-accepts.

## Statusline

```lua
vim.opt.statusline = "%f %{v:lua.require('plurnk').statusline()} %l/%L"
-- plurnk[session·run] · 🤖 alias · L3·T2 · ✅ 200 · $0.0042
```

## Internals (for agents)

- Transport: AG-UI+ over HTTP/SSE (`curl -N` under `vim.system`) against the daemon's in-process module; events un-project to the daemon shapes dispatch renders. The threadId is the session name, verbatim; the session (world) rides `forwardedProps.plurnk.session` on every run.
- Client contract: `SPEC.md` (this repo) — every `{§nvim-*}` promise is cited by a spec and the lockstep spec (38) enforces it. Wire contract: the plurnk-agui SPEC; machine model: plurnk-service SPEC.
- Notifications consumed: `log/entry` (routed per-run by `entry.run_id`), `loop/proposal` (server-resolved `flags.yolo/noProposals` are skipped), `loop/terminated`, `telemetry/event`, `stream/event`, `stream/concluded`.
- Tests: `./tests/runner.sh` — one headless nvim per spec; boots a private daemon from the sibling `../plurnk-service` checkout (tmp DB, ephemeral port) unless `PLURNK_PORT` is set. `PLURNK_SERVICE_DIR` overrides the daemon location.
- Project management: `AGENTS.md` (local). Audit + roadmap: [#16](https://github.com/plurnk/plurnk.nvim/issues/16).
