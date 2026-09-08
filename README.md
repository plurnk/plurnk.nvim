# plurnk.nvim

Neovim client for [plurnk-service](https://github.com/plurnk/plurnk-service).
It consumes the daemon's AG-UI+ HTTP/SSE interface directly; protocol traffic
never passes through the terminal client. The pitch: **use LLMs the vim way** —
your buffers, your motions, your `:` line.

Requires Neovim ≥ 0.10 and a running plurnk-service daemon (default
`127.0.0.1:1066`). The optional `plurnk` terminal client on `PATH` provides the
same width-aware GFM and Beautiful Mermaid presentation as its TUI; without it,
model Markdown remains faithful source.

```lua
require("plurnk").setup({ host = "127.0.0.1", port = 1066 })
require("plurnk").apply_default_keymaps()  -- optional; only fills unmapped keys
```

Run `:checkhealth plurnk` for the installed checkout/version, redacted daemon
endpoint, AG-UI+ compatibility, optional renderer, and every enabled default
mapping. If an occupied key prevents a default mapping, setup emits one
aggregate warning and health names the owner when Neovim can identify it.

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
| `:AI {text}` | prompt with the configured loop policy |
| `:AI? {text}` | ask profile — deny EXEC for this loop; review any admitted side effect |
| `:AI: {text}` | ordinary configured loop policy |
| `:AI! {cmd}` | exec `{cmd}` via the daemon; bare `:AI!` execs the visual selection |
| `:AI??` / `::` | new workspace, then prompt |
| `:AI???` | new headless workspace (no project root) |
| `:AI????` | new worker in the current workspace (fork) |
| `:AI... {text}` | inject into the running loop (a mid-loop prompt steers too) |
| `:AI/attach {name}` | bind this tab to a conversation worker by name (`:AI/workers` picks from the topology) |
| `:AI/parent` `:AI/enter` `:AI/older` `:AI/newer` | hop the worker tree — parent, newest child, older/newer sibling (`<leader>ah` `al` `aj` `ak`); the tab then speaks to that worker, the winbar shows its lineage `[/main/fork-1/~recheck]` |
| `:AI/` | show the compact grouped command index |
| `:AI/help {verb}` | show one command's exact usage and purpose |

Visual mode prepends the selection: `'<,'>AI? explain this`. No-space forms (`:AI?? hi`) work via cmdline abbreviations.
`/model <selector>` selects the parent; `/child <selector>` selects WORK/FORK/BARE calls, and `/child inherit` follows the spawning loop. A selector is a declared alias or exact `provider/model`. `/models [search]` lazily searches the daemon's bounded model catalog; it is never loaded at startup.
`/reasoning` reports the worker's durable policy and supported choices;
`/reasoning <policy>` persists a daemon-validated selection.
`/capabilities` reports the service/workspace/inherited/Worker capability cascade and effective intersection;
`/capabilities <json>` replaces its mutable Worker layer through the daemon's canonical policy contract.

Command routing, completion, contextual help, and default key descriptions use
one registry. Completion demand-loads model and Functionality choices only at
the positions that consume them. `/open`, `/reconnect`, `/next`, `/prev`, and
`/clear` are deliberate editor controls; the operation and Functionality
vocabulary otherwise matches the terminal client.

`:AI/agents` lists this Worker's outbound A2A agents; `discover <url>`, `add <alias> <url> [options.json]`, `enable`, `disable`, and `remove` are the daemon's common Functionality actions; an enabled agent is `a2a://<alias>` to the model.

`:AI/skills` lists this Worker's Agent Skills; `discover`, `add <name> <source> [--global]`, `enable`, `disable`, and `remove` are the daemon's common Functionality actions — the client runs no package manager. Project skills live in `.agents/skills`; global skills use `~/.agents/skills`.

`:AI/mcp` lists this Worker's MCP servers. `enable <alias> [options.json]`
either enables an available definition or specializes its current definition
for the Worker; `/help mcp` shows the complete lifecycle.

`:AI/members` lists this Worker's file members — what the model may see; `discover [path|glob]`, `add <alias> <glob>`, `enable`, `disable`, and `remove` are the daemon's common Functionality actions. Git-tracked files are members on their own; a gitignore-style glob adds untracked files, and a leading `!` excludes matching members. A bare `discover` explains the current buffer's file. `:PlurnkMembers` (`<leader>aM`) is the native spelling.

## Layout

One tab per **worker** (a conversation); a **workspace** is the world containing workers. One workspace is live per Neovim instance; switching notifies. Each worker tab: glyph waterfall on top (the worker's log, exactly what the model sees), 3-line input below — `<CR>` in normal mode submits; `? `/`: `/`! ` prefixes and raw `# PLAN_` / `## OP0` PLURNK work there too. Readable provider reasoning appears before its SEND as a distinct streaming `💭` block; multiline blocks begin folded. Each model body is independent, so its Markdown cannot style later Plurnk rows. When `plurnk render` is available, tables wrap with row separators, task boxes render once, code fences retain their language, and Mermaid uses Beautiful Mermaid; otherwise the semantic source remains visible. Streams (exec output) open as `1│`/`2│`-prefixed splits; wiping a live stream buffer cancels it.

## Proposals

Side-effecting ops pause for review. EDIT opens a diffsplit (left disk, right proposed): `<localleader>a` accept, `<localleader>e` accept-with-edits, `r` reject, `c` cancel. EXEC opens a scratch: `a`/`r`/`c`. Global: `<leader>ay/ae/an`, `<leader>a]`/`a[` cycle pending; `:AI/accept`, `/edit`, `/reject`, and `/cancel` expose the same decisions. `:PlurnkYolo` auto-accepts.

## Statusline

```lua
vim.opt.statusline = "%f %{v:lua.require('plurnk').statusline()} %l/%L"
-- active slot: 42% / ⌛︎ / 🔥 (progress / running / idle YOLO)
-- waterfall winbar: plurnk · workspace · worker · ⌛︎ · 🤖 model · L3·T2 · 🧠 adaptive · loop: $0.0042
```

## Internals (for agents)

- Transport: AG-UI+ over HTTP/SSE (`curl -N` under `vim.system`) against the daemon's in-process module; events un-project to the daemon shapes dispatch renders. The threadId is the workspace name, verbatim; the workspace (world) rides `forwardedProps.plurnk.workspace` on every run.
- Presentation: optional `plurnk render --width <columns>` over stdin/stdout, cached by semantic source and live width. It is never used for transport.
- Client contract: `SPEC.md` (this repo). External protocol: the plurnk-agui SPEC. Runtime model: the plurnk-service SPEC.
- Notifications consumed: `log/entry` (routed per worker by `entry.worker_id`), client-owned `loop/proposal`, `loop/terminated`, `notice/event`, `stream/event`, `stream/concluded`. Loop-owned proposal dispositions settle before AG-UI projection.
- Tests: `./tests/runner.sh` — one headless nvim per spec; boots a private daemon from the sibling `../plurnk-service` checkout (tmp DB, ephemeral port) unless `PLURNK_PORT` is set. `PLURNK_SERVICE_DIR` overrides the daemon location. `node tests/composition.mjs` copies an installed-plugin layout and drives its default multiline prompt, review/resume, and two-turn completion journey through the built service and a deterministic local provider fixture.
- Project management: `AGENTS.md` (local). Audit + roadmap: [#16](https://github.com/plurnk/plurnk.nvim/issues/16).
