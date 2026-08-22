# plurnk.nvim

Neovim client for [plurnk-service](https://github.com/plurnk/plurnk-service).
It consumes the daemon's AG-UI+ HTTP/SSE interface directly; it never shells
through the terminal client. The pitch: **use LLMs the vim way** — your
buffers, your motions, your `:` line.

Requires: Neovim ≥ 0.10, a running plurnk-service daemon (default `127.0.0.1:3044`).

```lua
require("plurnk").setup({ host = "127.0.0.1", port = 3044 })
require("plurnk").apply_default_keymaps()  -- optional; only fills unmapped keys
```

## The `:AI` language

`:AI/` prints this table in-editor.

| Form | Effect |
|---|---|
| `:AI` | toggle workspace tab ⇄ where you came from |
| `:AI {text}` | prompt (act) |
| `:AI? {text}` | **ask** — read-only loop: `flags.mode="ask"`, the engine 403s edits/exec |
| `:AI: {text}` | act (the default) |
| `:AI! {cmd}` | exec `{cmd}` via the daemon; bare `:AI!` execs the visual selection |
| `:AI??` / `::` | new workspace, then prompt |
| `:AI???` | new headless workspace (no project root) |
| `:AI????` | new worker in the current workspace (fork) |
| `:AI... {text}` | inject into the running loop (a mid-loop prompt steers too) |
| `:AI/{verb}` | `models model child reasoning workspaces workers workspace worker rename log yolo ping`, membership `pick hide view drop members`, workspace MCP `mcp`, universal Agent Skills `skills`, `open accept reject next prev stop clear` |

Visual mode prepends the selection: `'<,'>AI? explain this`. No-space forms (`:AI?? hi`) work via cmdline abbreviations.
`/model <selector>` selects the parent; `/child <selector>` selects WORK/FORK/BARE calls, and `/child inherit` follows the spawning loop. A selector is a declared alias or exact `provider/model`. `/models [search]` lazily searches the daemon's bounded model catalog; it is never loaded at startup.
`/reasoning` reports the worker's durable policy and supported choices;
`/reasoning <policy>` persists a daemon-validated selection.

`:AI/skills` lists project skills; `add`, `remove`, `find`, and `update` invoke the standard `npx skills` CLI directly with its `universal` target. Project skills live in `.agents/skills`; global skills use `~/.agents/skills`.

## Layout

One tab per **worker** (a conversation); a **workspace** is the world containing workers. One workspace is live per Neovim instance; switching notifies. Each worker tab: glyph waterfall on top (the worker's log, exactly what the model sees), 3-line input below — `<CR>` in normal mode submits; `? `/`: `/`! ` prefixes and raw `# PLAN0` / `## OP0` PLURNK work there too. Readable provider reasoning appears before its SEND as a distinct `💭` block; multiline blocks begin folded. Streams (exec output) open as `1│`/`2│`-prefixed splits; wiping a live stream buffer cancels it.

## Proposals

Side-effecting ops pause for review. EDIT opens a diffsplit (left disk, right proposed): `<localleader>a` accept, `<localleader>e` accept-with-edits, `r` reject, `c` cancel. EXEC opens a scratch: `a`/`r`/`c`. Global: `<leader>ay/ae/an`, `<leader>a]`/`a[` cycle pending, `:PlurnkYolo` auto-accepts.

## Statusline

```lua
vim.opt.statusline = "%f %{v:lua.require('plurnk').statusline()} %l/%L"
-- plurnk[workspace·worker] · 🤖 provider/model · 🧠 adaptive · L3·T2 · ✅ 200 · $0.0042
```

## Internals (for agents)

- Transport: AG-UI+ over HTTP/SSE (`curl -N` under `vim.system`) against the daemon's in-process module; events un-project to the daemon shapes dispatch renders. The threadId is the workspace name, verbatim; the workspace (world) rides `forwardedProps.plurnk.workspace` on every run.
- Client contract: `SPEC.md` (this repo). External protocol: the plurnk-agui SPEC. Runtime model: the plurnk-service SPEC.
- Notifications consumed: `log/entry` (routed per-run by `entry.worker_id`), `loop/proposal` (server-resolved `flags.yolo/noProposals` are skipped), `loop/terminated`, `notice/event`, `stream/event`, `stream/concluded`.
- Tests: `./tests/runner.sh` — one headless nvim per spec; boots a private daemon from the sibling `../plurnk-service` checkout (tmp DB, ephemeral port) unless `PLURNK_PORT` is set. `PLURNK_SERVICE_DIR` overrides the daemon location. `node tests/composition.mjs` copies an installed-plugin layout and exercises it against the built service.
- Project management: `AGENTS.md` (local). Audit + roadmap: [#16](https://github.com/plurnk/plurnk.nvim/issues/16).
