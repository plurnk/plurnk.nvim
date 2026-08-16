# plurnk.nvim — Client SPEC

The Neovim client's contract. The external protocol is the plurnk-agui SPEC
(AG-UI+); the runtime model is the plurnk-service SPEC. This document states
what this client guarantees. Tests are organized by observable behavior under
`tests/specs/`; documentation citations are not a substitute for coverage.

## §1 Posture

- **Use LLMs the vim way** — one `<CR>` normal-mode mapping in
  plugin buffers, no `startinsert`, no `<Esc><Esc>` remaps, no shortcuts that duplicate
  vim built-ins. The default keymap set converges the verb vocabulary (fork > loop >
  turn > op) without colonizing the user's namespace.
- **Dumb client** — decisions about loop flow belong to the daemon; this client parses
  commands, holds the transport, marshals actions, renders. It never second-guesses a
  number or a status.

## §2 Transport (AG-UI+)

- **The SSE consumer is pure and standards-conformant** —
  the dependency-free Lua parser preserves Neovim portability while handling
  split chunks, CRLF/LF/CR endings, comments, ignored fields, multiline `data`,
  and EOF dispatch. Malformed AG-UI JSON is a surfaced 502 transport failure,
  never a dropped event; decoded events un-project to the daemon notification
  shapes dispatch already routes.
- **The workspace (world) rides every run** — the `threadId` IS the
  workspace name, verbatim (no prefix, no forging), and the client sends it as
  `forwardedProps.plurnk.workspace` on every run. The front door — `:PlurnkWorkspaces` →
  pick → attached — binds by exact name; a failing attach delivers NIL plus a surfaced
  error, never a truthy empty.
- **No fabricated success** — a stream that dies without terminal
  truth is 502; a missing action result is an error; resolve acks are nil on failed
  delivery. Errors cross every layer intact.
- **Problem fidelity** - `application/problem+json`, `CUSTOM plurnk.problem`,
  failed action results, and `plurnk.terminated.result.problem` preserve the
  exact RFC 9457 object through the Lua bridge. `RUN_ERROR` is never used to
  rebuild the richer Problem; receiving it without the exact Problem is a
  client-owned `problem-missing` transport failure. The UI renders `detail`
  and an optional `recovery`. `plurnk.terminated.result.status` is the
  family-specific terminal status; there is no sibling `finalStatus` field.
- **Standard run lifecycle** — every request carries a fresh `runId`; proposals end
  their run with an AG-UI interrupt outcome, and the decision arrives in a new run
  through `RunAgentInput.resume`. A proposal tool call without its matching declared
  interrupt is a protocol error, never an invitation to infer private lifecycle state.
  A proposal-gated management action remains one logical action across its interrupt
  and resume runs and retains the serialized management lane until its action result.
  `RUN_FINISHED` and `RUN_ERROR` alone settle the client run; `plurnk.terminated`
  supplies family-specific status and usage metadata but is not a competing lifecycle.
- **Cold no-daemon onboarding** — a management run against a dead
  port surfaces one WARN notify naming the condition with the quick-start (`npx
  @plurnk/plurnk-service start`) and install lines — one message with the CLI's
  `client:connection:refused` block; never a silent nil result.
- **The stale-daemon probe** - `discover` runs once per instance; a manifest
  missing the AG-UI+ markers this client depends on (`op.exec`,
  `op.look`) warns bluntly that the daemon is older than the client.
- **Control-plane liveness** — `ping` answers an empty-object
  result; `providers.list` returns the alias table the pickers and statusline consume.
- **The push pipeline** — a dispatched op (e.g. `op.parse`)
  produces a `log/entry` notification that advances client state; rendering is
  push-driven, never polled.

## §3 The `:AI` language

- **One metacommand** — cmdline abbreviations (`:AI?` without a
  space), full `/` verb routing, and the bare `:AI` toggle; `:AI/` prints the language
  and sends nothing.
- **Mode is a per-line prefix** — `?` = ask
  (`flags.mode="ask"`), `:` = act (the daemon default, send nothing), `!` = exec.
  Converged with the TUI and the CLI; never an `--ask` flag.
- **Repetition carries scope** — `??` new workspace, `???` new
  headless workspace, `????` fork-lite (new worker in the current workspace).
- **Visual ranges wrap** — `:'<,'>AI: explain` folds the
  selection into the prompt; the `??` new-workspace form wraps the same way (the v0.3.0
  regression stays pinned).
- **Raw PLURNK passes through** — input beginning with a recognized operation
  heading (`# PLAN…` or `## OP…`) goes to `op.parse` verbatim; plain text routes
  to a conversation worker. Prefix `: ` to force prompt treatment when prose
  intentionally begins with a reserved operation heading.
- **`## LOOK…` inspects off-worker** — a READ for the human, not the model:
  routed to `op.look` (the module rewrites LOOK→READ; no log row minted), content
  rendered into the waterfall locally; a failed look surfaces, never a silent nothing.
- **Completion** — `:AI` cmdline completion offers verbs, model aliases,
  child inheritance, and local files where a verb consumes one.
- §nvim-workspace-mcp-controls **Workspace MCP controls are daemon actions** —
  the client tokenizes quoted alias/target arguments and JSON-decodes an
  optional local options file. The daemon owns normalization, schema
  validation, connection behavior, persistence, protocol compatibility, and
  exact Problem Details; symbolic credential references remain unchanged.

  | Input | AG-UI+ action |
  |---|---|
  | `:AI/mcp` | `workspace.mcp.list` |
  | `:AI/mcp add <alias> <target> [options.json]` | `workspace.mcp.add {alias, target, options?}` |
  | `:AI/mcp enable <alias>` | `workspace.mcp.enable {alias}` |
  | `:AI/mcp disable <alias>` | `workspace.mcp.disable {alias}` |
  | `:AI/mcp remove <alias>` | `workspace.mcp.remove {alias}` |
  | `:AI/mcp oauth <alias> <callback-url>` | `workspace.mcp.oauth.complete {alias, callbackUrl}` |

  Interactive authorization prints the URL and exact completion command.
  Unreadable or invalid local JSON stops before dispatch. Daemon Problems,
  including unsupported protocol revisions, use the existing lossless Problem
  path and are neither rewritten nor retried.

## §4 Workspaces and workers

- **The name is the identity** — `workspace.create` returns
  `{id, name}` and the workspace lists by exact name; `workspace.list` is the world
  directory.
- **The waterfall shows THE CONVERSATION** — only the model
  worker renders in the workspace waterfall; client-worker rows (the connection's op.* scratch)
  stay out. The conversation worker is adopted from events arriving while a loop is in
  flight.
- **Run-keyed routing** — entries route to their run's buffer by
  `entry.worker_id`, no interleaving; a pending record is adopted by the first run seen.
- **Fork branches the conversation** — `:PlurnkFork` / `:AI????` →
  `worker.fork`, optionally named at instantiation (immutable after), then binds to the
  new worker.
- **Rename is a mutable handle on the world** — `workspace.rename`
  rekeys local state and the worker tab in place; a worker's name is immutable.
- **Project root defaults to the editor cwd** — `workspace.create`
  is not headless by accident; file ops depend on it.

## §5 Rendering

- **The run tab** — `:AI` opens a workspace tabpage with two windows:
  waterfall on top, input at the bottom; submitting populates the waterfall and leaves
  focus on the input; an actionless `prompt` row renders as 🐹 speech from `rx.content`.
- **Two glyph lanes** — every waterfall row carries identity ·
  status (🐹 client; the model SEND lane is status-flavored: 💭 102, 💡 200, 💤 202,
  🤔 300), the status code in one column; width-stable glyphs only.
- **Broadcast prose remains source-faithful except for exact terminal typography** —
  the common inline token `$\rightarrow$` renders as `→`; this is not general LaTeX
  or Markdown interpretation.
- **Stream windows** — channel prefixes + interleave, batched
  flush (one `entry.read` per tick burst), partial-line hold, a conclusion footer, and
  `BufWipeout` → an `op.send` cancellation carrying status 499.
- **Notice severity is producer-set** — required `notice.level`
  maps error → ErrorMsg, warn → WarningMsg, info → Comment; no kind heuristic.
- **The abacus** — `engine:derivation embed_progress` collapses to an
  edge-toggled 🧮 on the statusline, never a waterfall line; `engine:turn` liveness is
  the ⏳ gutter, dropped from the waterfall; the abacus never outlives the loop.
- **Search acquisition progress** — `exec:* search_progress`
  collapses to `🔎 N%` on the statusline and clears on its terminal phase. Milestones
  never append to the waterfall; materialized pages remain available in durable history.
- **Serialized branch progress** — `CUSTOM plurnk.branch_batch` un-projects to
  `workspace/branch-batch`; queued/running state collapses to `🌿 N%` on the
  statusline. Completion or failure appends one summary and clears it;
  `recovery_required` appends one error and remains visible as `🌿 ❌`.
- **Membership signs mark exceptions only** — view 🔒 and
  hidden 🚫 get a line-1 extmark; plain members and non-members get no sign.
- **The statusline is lean** — 🐹 + one status glyph + 🔥 when
  YOLO is armed (+ compact 🧮, 🔎, or 🌿 work state); the rich detail lives in the winbar.
- **The cockpit gauge preserves cardinal accounting** — the winbar reads the LAST
  loop's `plurnk.terminated.usage` envelope without rewriting it: conventional
  aggregate `inputTokens`/`outputTokens`, independent curation
  `curationWeight`/`curationBudget` and physical-context
  `contextTokens`/`contextCapacity` gauges, and exact decimal
  `accounting.costUsd` or `$unknown`. Weight is never compared with tokens.
  Ordered physical-request evidence remains in `accounting.requests`; the client
  has no accounting setter, floating-point conversion, projection, or workspace tally.

## §6 Loops

- **The conversation answers end to end** — the exact command
  a user types drives a live loop to `loop/terminated` 200 and the waterfall carries
  the terminal 💡 200 SEND.
- **Exec streams live** — `:AI!` dispatches `op.exec` through the
  engine; stdout arrives over `stream/event` and renders prefixed.
- **Stop is real** — `/stop` and `:PlurnkStop` fire the `loop.cancel`
  action against the daemon; a failed cancel surfaces.

## §7 Proposals and questions

- **Review is a diffsplit** — accept-with-edits regenerates a
  valid udiff from the edited buffer.
- **Server-resolved proposals never prompt** — `flags.yolo`
  (server auto-accept) and `flags.noProposals` (server auto-reject) settle in-process
  on the daemon; dispatch drops them client-side.
- **[300] questions elicit** — a SEND carrying `attrs.question`
  picks via `vim.ui.select` (+ a Free Response escape) or `vim.ui.input`, resolving
  with `decision=accept` and the answer as body.

## §8 Config and policy

- **Workspace-open settings ride creation** — the client id,
  execs policy, `questions`, and `filesItems` (the CLI's
  `--files-items`, converged: -1 full / 0 off / N first-N) travel on `workspace.create`;
  creation is atomic, nothing arrives later.
- **Model selection sticks** — a picked alias persists past one
  loop.
- §nvim-child-provider-selection **Child selection sticks per workspace** —
  `/child` reports, `/child <alias>` selects WORK/FORK/BARE calls, and `/child inherit` sends explicit inheritance; `PLURNK_MODEL_CHILD` supplies the initial alias.
- **Client-side alias resolution** — `PLURNK_MODEL_<alias>`
  resolves to `<provider>/<model>` from nvim's fresh env and rides `model` on the run,
  so a stale long-lived daemon can't reject an unknown alias; case-folded suffix.
- **Execs policy forwards; secrets never do** — `PLURNK_EXECS_*`
  enable/disable grammar rides verbatim for the daemon's subtractive intersection;
  `PLURNK_EXECS_MCP_*` server configs (URLs, bearer tokens) never touch the wire.
- **Interactive provider authentication belongs to third-party MCP tooling.**
- **Membership verbs converge with the TUI** — pick/hide/view/
  drop/members speak the service vocabulary live via `workspace.constrain`/`unconstrain`/
  `constraints`.
