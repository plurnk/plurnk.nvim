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

- **The SSE consumer is pure and reassembles split frames** —
  `agui.parse_sse` decodes `data:` frames from accumulated chunks, retaining the
  incomplete tail; events un-project to the daemon notification shapes dispatch
  already routes.
- **The workspace (world) rides every run** — the `threadId` IS the
  workspace name, verbatim (no prefix, no forging), and the client sends it as
  `forwardedProps.plurnk.workspace` on every run. The front door — `:PlurnkWorkspaces` →
  pick → attached — binds by exact name; a failing attach delivers NIL plus a surfaced
  error, never a truthy empty.
- **No fabricated success** — a stream that dies without terminal
  truth is 502; a missing action result is an error; resolve acks are nil on failed
  delivery. Errors cross every layer intact.
- **Standard run lifecycle** — every request carries a fresh `runId`; proposals end
  their run with an AG-UI interrupt outcome, and the decision arrives in a new run
  through `RunAgentInput.resume`. A proposal tool call without its matching declared
  interrupt is a protocol error, never an invitation to infer private lifecycle state.
- **The stale-daemon probe** — `discover` runs once per
- **Cold no-daemon onboarding** — a management run against a dead
  port surfaces one WARN notify naming the condition with the quick-start (`npx
  @plurnk/plurnk-service start`) and install lines — one message with the CLI's
  `client:connection:refused` block; never a silent nil result.
  instance; a manifest missing the AG-UI+ markers this client depends on (`op.exec`,
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
- **Raw DSL passes through** — `<<…` input-buffer lines go to
  `op.parse` verbatim; plain text routes to a conversation worker.
- **`<<LOOK` inspects off-worker** — a READ for the human, not the model:
  routed to `op.look` (the module rewrites LOOK→READ; no log row minted), content
  rendered into the waterfall locally; a failed look surfaces, never a silent nothing.
- **Completion** — `:AI` cmdline completion offers verbs and model
  aliases.

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
  focus on the input.
- **Two glyph lanes** — every waterfall row carries identity ·
  status (🐹 client; the model SEND lane is status-flavored: 💭 102, 💡 200, 💤 202,
  🤔 300), the status code in one column; width-stable glyphs only.
- **Stream windows** — channel prefixes + interleave, batched
  flush (one `entry.read` per tick burst), partial-line hold, a conclusion footer, and
  `BufWipeout` → SEND[499] cancel.
- **Telemetry severity is producer-set** — `event.level`
  maps error → ErrorMsg, warn → WarningMsg, info/absent → Comment; no kind heuristic.
- **The abacus** — `engine:derivation embed_progress` collapses to an
  edge-toggled 🧮 on the statusline, never a waterfall line; `engine:turn` liveness is
  the ⏳ gutter, dropped from the waterfall; the abacus never outlives the loop.
- **Search acquisition progress** — `exec:* search_progress`
  collapses to `🔎 N%` on the statusline and clears on its terminal phase. Milestones
  never append to the waterfall; materialized pages remain available in durable history.
- **Membership signs mark exceptions only** — view 🔒 and
  hidden 🚫 get a line-1 extmark; plain members and non-members get no sign.
- **The statusline is lean** — 🐹 + one status glyph + 🔥 when
  YOLO is armed (+ 🧮 while embedding); the rich detail lives in the winbar.
- **The cockpit gauge is the daemon's number** — the winbar shows
  the LAST loop's usage snapshot, never a client-side tally.

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
  `autoReadAgents`, the execs policy, `questions`, and `filesItems` (the CLI's
  `--files-items`, converged: -1 full / 0 off / N first-N) travel on `workspace.create`;
  creation is atomic, nothing arrives later.
- **Model selection sticks** — a picked alias persists past one
  loop.
- **Client-side alias resolution** — `PLURNK_MODEL_<alias>`
  resolves to `<provider>/<model>` from nvim's fresh env and rides `model` on the run,
  so a stale long-lived daemon can't reject an unknown alias; case-folded suffix.
- **Execs policy forwards; secrets never do** — `PLURNK_EXECS_*`
  enable/disable grammar rides verbatim for the daemon's subtractive intersection;
  `PLURNK_EXECS_MCP_*` server configs (URLs, bearer tokens) never touch the wire.
- **Auth is the device grant** — `auth.authorize` → show
  verificationUri + userCode → poll until authorized/denied/expired; no redirect, no
  local server, works over a remote daemon.
- **Membership verbs converge with the TUI** — pick/hide/view/
  drop/members speak the service vocabulary live via `workspace.constrain`/`unconstrain`/
  `constraints`.
