# plurnk.nvim — Client SPEC

The Neovim client's contract. The wire protocol is the plurnk-agui SPEC (AG-UI+); the
machine model is the plurnk-service SPEC. This document states what THIS client
guarantees. Every `{§nvim-*}` anchor below is cited by a `[§nvim-*]` marker in a spec
under `tests/specs/`; the lockstep spec enforces it three ways (uncited promise /
orphan citation / rotted comment ref).

## §1 Posture

- **Use LLMs the vim way** {§nvim-vim-conventions} — one `<CR>` normal-mode mapping in
  plugin buffers, no `startinsert`, no `<Esc><Esc>` remaps, no shortcuts that duplicate
  vim built-ins. The default keymap set converges the verb vocabulary (fork > loop >
  turn > op) without colonizing the user's namespace.
- **Dumb client** — decisions about loop flow belong to the daemon; this client parses
  commands, holds the transport, marshals actions, renders. It never second-guesses a
  number or a status.

## §2 Transport (AG-UI+)

- **The SSE consumer is pure and reassembles split frames** {§nvim-sse-parser} —
  `agui.parse_sse` decodes `data:` frames from accumulated chunks, retaining the
  incomplete tail; events un-project to the daemon notification shapes dispatch
  already routes.
- **The workspace (world) rides every run** {§nvim-workspace-door} — the `threadId` IS the
  workspace name, verbatim (no prefix, no forging), and the client sends it as
  `forwardedProps.plurnk.workspace` on every run. The front door — `:PlurnkWorkspaces` →
  pick → attached — binds by exact name; a failing attach delivers NIL plus a surfaced
  error, never a truthy empty.
- **No fabricated success** {§nvim-honest-errors} — a stream that dies without terminal
  truth is 502; a missing action result is an error; resolve acks are nil on failed
  delivery. Errors cross every layer intact.
- **The stale-daemon probe** {§nvim-stale-daemon-probe} — `discover` runs once per
- **Cold no-daemon onboarding** {§nvim-connection-onboarding} — a management run against a dead
  port surfaces one WARN notify naming the condition with the quick-start (`npx
  @plurnk/plurnk-service start`) and install lines — one message with the CLI's
  `client:connection:refused` block; never a silent nil result.
  instance; a manifest missing the AG-UI+ markers this client depends on (`op.exec`,
  `op.look`) warns bluntly that the daemon is older than the client.
- **Control-plane liveness** {§nvim-control-plane} — `ping` answers an empty-object
  result; `providers.list` returns the alias table the pickers and statusline consume.
- **The push pipeline** {§nvim-push-pipeline} — a dispatched op (e.g. `op.parse`)
  produces a `log/entry` notification that advances client state; rendering is
  push-driven, never polled.

## §3 The `:AI` language

- **One metacommand** {§nvim-ai-language} — cmdline abbreviations (`:AI?` without a
  space), full `/` verb routing, and the bare `:AI` toggle; `:AI/` prints the language
  and sends nothing.
- **Mode is a per-line prefix** {§nvim-prompt-prefixes} — `?` = ask
  (`flags.mode="ask"`), `:` = act (the daemon default, send nothing), `!` = exec.
  Converged with the TUI and the CLI; never an `--ask` flag.
- **Repetition carries scope** {§nvim-scope-repetition} — `??` new workspace, `???` new
  headless workspace, `????` fork-lite (new worker in the current workspace).
- **Visual ranges wrap** {§nvim-visual-selection} — `:'<,'>AI: explain` folds the
  selection into the prompt; the `??` new-workspace form wraps the same way (the v0.3.0
  regression stays pinned).
- **Raw DSL passes through** {§nvim-input-dsl} — `<<…` input-buffer lines go to
  `op.parse` verbatim; plain text routes to a conversation worker.
- **`<<LOOK` inspects off-worker** {§nvim-look} — a READ for the human, not the model:
  routed to `op.look` (the module rewrites LOOK→READ; no log row minted), content
  rendered into the waterfall locally; a failed look surfaces, never a silent nothing.
- **Completion** {§nvim-completion} — `:AI` cmdline completion offers verbs and model
  aliases.

## §4 Workspaces and workers

- **The name is the identity** {§nvim-name-is-identity} — `workspace.create` returns
  `{id, name}` and the workspace lists by exact name; `workspace.list` is the world
  directory.
- **The waterfall shows THE CONVERSATION** {§nvim-model-worker-waterfall} — only the model
  worker renders in the workspace waterfall; client-worker rows (the connection's op.* scratch)
  stay out. The conversation worker is adopted from events arriving while a loop is in
  flight.
- **Run-keyed routing** {§nvim-worker-routing} — entries route to their run's buffer by
  `entry.worker_id`, no interleaving; a pending record is adopted by the first run seen.
- **Fork branches the conversation** {§nvim-worker-fork} — `:PlurnkFork` / `:AI????` →
  `worker.fork`, optionally named at instantiation (immutable after), then binds to the
  new worker.
- **Rename is a mutable handle on the world** {§nvim-workspace-rename} — `workspace.rename`
  rekeys local state and the worker tab in place; a worker's name is immutable.
- **Project root defaults to the editor cwd** {§nvim-project-root} — `workspace.create`
  is not headless by accident; file ops depend on it.

## §5 Rendering

- **The run tab** {§nvim-worker-tab} — `:AI` opens a workspace tabpage with two windows:
  waterfall on top, input at the bottom; submitting populates the waterfall and leaves
  focus on the input.
- **Two glyph lanes** {§nvim-two-lane-glyphs} — every waterfall row carries identity ·
  status (🐹 client; the model SEND lane is status-flavored: 💭 102, 💡 200, 💤 202,
  🤔 300), the status code in one column; width-stable glyphs only.
- **Stream windows** {§nvim-stream-windows} — channel prefixes + interleave, batched
  flush (one `entry.read` per tick burst), partial-line hold, a conclusion footer, and
  `BufWipeout` → SEND[499] cancel.
- **Telemetry severity is producer-set** {§nvim-telemetry-severity} — `event.level`
  maps error → ErrorMsg, warn → WarningMsg, info/absent → Comment; no kind heuristic.
- **The abacus** {§nvim-abacus} — `engine:derivation embed_progress` collapses to an
  edge-toggled 🧮 on the statusline, never a waterfall line; `engine:turn` liveness is
  the ⏳ gutter, dropped from the waterfall; the abacus never outlives the loop.
- **Membership signs mark exceptions only** {§nvim-membership-signs} — view 🔒 and
  hidden 🚫 get a line-1 extmark; plain members and non-members get no sign.
- **The statusline is lean** {§nvim-lean-statusline} — 🐹 + one status glyph + 🔥 when
  YOLO is armed (+ 🧮 while embedding); the rich detail lives in the winbar.
- **The cockpit gauge is the daemon's number** {§nvim-cockpit-gauge} — the winbar shows
  the LAST loop's usage snapshot, never a client-side tally.

## §6 Loops

- **The conversation answers end to end** {§nvim-conversation-e2e} — the exact command
  a user types drives a live loop to `loop/terminated` 200 and the waterfall carries
  the terminal 💡 200 SEND.
- **Exec streams live** {§nvim-exec-e2e} — `:AI!` dispatches `op.exec` through the
  engine; stdout arrives over `stream/event` and renders prefixed.
- **Stop is real** {§nvim-stop} — `/stop` and `:PlurnkStop` fire the `loop.cancel`
  action against the daemon; a failed cancel surfaces.

## §7 Proposals and questions

- **Review is a diffsplit** {§nvim-proposal-review} — accept-with-edits regenerates a
  valid udiff from the edited buffer.
- **Server-resolved proposals never prompt** {§nvim-server-resolved} — `flags.yolo`
  (server auto-accept) and `flags.noProposals` (server auto-reject) settle in-process
  on the daemon; dispatch drops them client-side.
- **[300] questions elicit** {§nvim-questions} — a SEND carrying `attrs.question`
  picks via `vim.ui.select` (+ a Free Response escape) or `vim.ui.input`, resolving
  with `decision=accept` and the answer as body.

## §8 Config and policy

- **Workspace-open settings ride creation** {§nvim-workspace-settings} — the client id,
  `autoReadAgents`, the execs policy, `questions`, and `filesItems` (the CLI's
  `--files-items`, converged: -1 full / 0 off / N first-N) travel on `workspace.create`;
  creation is atomic, nothing arrives later.
- **Model selection sticks** {§nvim-model-selection} — a picked alias persists past one
  loop.
- **Client-side alias resolution** {§nvim-alias-resolution} — `PLURNK_MODEL_<alias>`
  resolves to `<provider>/<model>` from nvim's fresh env and rides `model` on the run,
  so a stale long-lived daemon can't reject an unknown alias; case-folded suffix.
- **Execs policy forwards; secrets never do** {§nvim-execs-policy} — `PLURNK_EXECS_*`
  enable/disable grammar rides verbatim for the daemon's subtractive intersection;
  `PLURNK_EXECS_MCP_*` server configs (URLs, bearer tokens) never touch the wire.
- **Auth is the device grant** {§nvim-auth-device-grant} — `auth.authorize` → show
  verificationUri + userCode → poll until authorized/denied/expired; no redirect, no
  local server, works over a remote daemon.
- **Membership verbs converge with the TUI** {§nvim-membership-verbs} — pick/hide/view/
  drop/members speak the service vocabulary live via `workspace.constrain`/`unconstrain`/
  `constraints`.
