# plurnk.nvim

Neovim client for [plurnk-service](https://github.com/plurnk/plurnk-service).
It consumes the daemon's AG-UI+ HTTP/SSE interface directly; protocol traffic
never passes through the terminal client. The pitch: **use LLMs the vim way** —
your buffers, your motions, your `:` line.

Requires Neovim ≥ 0.10 and a running plurnk-service daemon (default
`127.0.0.1:3044`). The optional `plurnk` terminal client on `PATH` provides the
same width-aware GFM and Beautiful Mermaid presentation as its TUI; without it,
model Markdown remains faithful source.

```lua
require("plurnk").setup({ host = "127.0.0.1", port = 3044 })
require("plurnk").apply_default_keymaps()  -- optional; only fills unmapped keys
```

## Install & releases

A source-consumed plugin — no build step, package registry, or compiled
artifact. Canonical source lives on Gitea;
`github.com/plurnk/plurnk.nvim` is the public mirror.
Two supported ways to consume it:

- **Track `main`** — rolling accepted source. Every commit on public `main`
  has passed the private daemon-backed suite.
- **Pin the newest `vX.Y.Z` tag** — a vetted point release. From `v0.28.0`
  onward every release tag is a GPG-signed annotated tag; older tags are
  historic lightweight markers and not release artifacts.

Versioning is semver `0.MINOR.PATCH`: each accepted release bumps the minor;
while pre-1.0, a minor bump may carry breaking changes (see the tag message).

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

`:AI/agents` lists this Worker's outbound A2A agents; `discover <url>`, `add <alias> <url> [options.json]`, `enable`, `disable`, and `remove` are the daemon's common Functionality actions; an enabled agent is `a2a://<alias>` to the model.

`:AI/skills` lists this Worker's Agent Skills; `discover`, `add <name> <source> [--global]`, `enable`, `disable`, and `remove` are the daemon's common Functionality actions — the client runs no package manager. Project skills live in `.agents/skills`; global skills use `~/.agents/skills`.

## Layout

One tab per **worker** (a conversation); a **workspace** is the world containing workers. One workspace is live per Neovim instance; switching notifies. Each worker tab: glyph waterfall on top (the worker's log, exactly what the model sees), 3-line input below — `<CR>` in normal mode submits; `? `/`: `/`! ` prefixes and raw `# PLAN0` / `## OP0` PLURNK work there too. Readable provider reasoning appears before its SEND as a distinct streaming `💭` block; multiline blocks begin folded. Each model body is independent, so its Markdown cannot style later Plurnk rows. When `plurnk render` is available, tables wrap with row separators, task boxes render once, code fences retain their language, and Mermaid uses Beautiful Mermaid; otherwise the semantic source remains visible. Streams (exec output) open as `1│`/`2│`-prefixed splits; wiping a live stream buffer cancels it.

## Proposals

Side-effecting ops pause for review. EDIT opens a diffsplit (left disk, right proposed): `<localleader>a` accept, `<localleader>e` accept-with-edits, `r` reject, `c` cancel. EXEC opens a scratch: `a`/`r`/`c`. Global: `<leader>ay/ae/an`, `<leader>a]`/`a[` cycle pending, `:PlurnkYolo` auto-accepts.

## Statusline

```lua
vim.opt.statusline = "%f %{v:lua.require('plurnk').statusline()} %l/%L"
-- active slot: 42% / ⌛︎ / 🔥 (progress / running / idle YOLO)
-- waterfall winbar: plurnk · workspace · worker · 🤖 provider/model · 🧠 adaptive · L3·T2 · ⏹️ · loop: $0.0042
```

## Internals (for agents)

- Transport: AG-UI+ over HTTP/SSE (`curl -N` under `vim.system`) against the daemon's in-process module; events un-project to the daemon shapes dispatch renders. The threadId is the workspace name, verbatim; the workspace (world) rides `forwardedProps.plurnk.workspace` on every run.
- Presentation: optional `plurnk render --width <columns>` over stdin/stdout, cached by semantic source and live width. It is never used for transport.
- Client contract: `SPEC.md` (this repo). External protocol: the plurnk-agui SPEC. Runtime model: the plurnk-service SPEC.
- Notifications consumed: `log/entry` (routed per worker by `entry.worker_id`), `loop/proposal` (server-resolved `flags.yolo/noProposals` are skipped), `loop/terminated`, `notice/event`, `stream/event`, `stream/concluded`.
- Tests: `./tests/runner.sh` — one headless nvim per spec; boots a private daemon from the sibling `../plurnk-service` checkout (tmp DB, ephemeral port) unless `PLURNK_PORT` is set. `PLURNK_SERVICE_DIR` overrides the daemon location. `node tests/composition.mjs` copies an installed-plugin layout and exercises it against the built service.
- Project management: `AGENTS.md` (local). Audit + roadmap: [#16](https://github.com/plurnk/plurnk.nvim/issues/16).
