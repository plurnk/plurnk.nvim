# plurnk.nvim — Client SPEC

The Neovim client's contract. The external protocol is the plurnk-agui SPEC
(AG-UI+); the runtime model is the plurnk-service SPEC. This document states
what this client guarantees. Tests are organized by observable behavior under
`tests/specs/`; documentation citations are not a substitute for coverage.

## §1 Posture

- **Use LLMs the vim way** — one `<CR>` normal-mode mapping in
  plugin buffers, no `startinsert`, no `<Esc><Esc>` remaps, no shortcuts that duplicate
  vim built-ins. The optional default keymap set fills only unmapped keys.
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
- §nvim-agui-interrupt-resume **Standard run lifecycle** — every request carries a fresh `runId`; proposals end
  their run with an AG-UI interrupt outcome, and the decision arrives in a new run
  through `RunAgentInput.resume`. A proposal tool call without its matching declared
  interrupt is a protocol error, never an invitation to infer private lifecycle state.
  A proposal-gated management action remains one logical action across its interrupt
  and resume runs and retains the serialized management lane until its action result.
  A model-loop proposal resumes by exact interrupt identity independently of that
  lane. Each transport segment owns its own terminal evidence, so a delayed completion
  from an interrupted segment cannot settle or corrupt its resumed logical run.
  `RUN_FINISHED` and `RUN_ERROR` alone settle the client run; `plurnk.terminated`
  supplies family-specific status and usage metadata but is not a competing lifecycle.
- **Cold no-daemon onboarding** — a management run against a dead
  port surfaces one WARN notify naming the condition with the quick-start (`npx
  @plurnk/plurnk-service start`) and install lines — one message with the CLI's
  `client:connection:refused` block; never a silent nil result.
- **The stale-daemon probe** - `discover` runs once per instance; a response
  missing the schema-bearing AG-UI+ markers this client depends on (`op.exec`,
  `op.look`) warns bluntly that the daemon is older than the client.
- §nvim-agui-conformance **The public surface is exhaustively accounted for** -
  `conformance/agui-client.json` classifies every live discovery action and
  notification as native, losslessly generic, or explicitly unsupported. The
  contracts reporter requires exact key equality, declared verification
  dimensions, and existing evidence; it emits one record per member. The Lua
  transport consumes the shared SSE/lifecycle corpus, and a separate AG-UI
  connection observes every durable editor-exposed control.
- **Control-plane liveness** — `ping` answers an empty-object result;
  `providers.list` returns the small declared-alias directory used by completion
  and the statusline. `models.list` returns bounded pages from the daemon's
  release-pinned catalog without contacting a provider.
- **The push pipeline** — a dispatched op (e.g. `op.parse`)
  produces a `log/entry` notification that advances client state; rendering is
  push-driven, never polled.
- §nvim-worker-status **Worker status projects the authoritative AG-UI gauge** —
  each stream begins from `STATE_SNAPSHOT` and applies only its subsequent RFC
  6902 `replace` deltas. The client presents lifecycle → model → exact packet
  count before reasoning and terminal accounting; the editor statusline owns
  replaceable activity. Rows, turns, and local callbacks never reconstruct
  status or masquerade as provider packets. Missing, malformed, or unsupported
  state is a transport failure rather than a partial display.
- §nvim-stream-recovery **A broken stream is observation loss, not permission
  to rerun inference.** Neovim settles partial reasoning, displays a client-owned
  reconnecting overlay, and makes bounded read-only `log.read` action Runs until
  standard `STATE` reports a non-running lifecycle. The successful observation
  appends only durable rows beyond that worker's last observed row, in canonical
  order and without duplication. If losslessness cannot be established or the
  public result bound is exhausted, the client fails visibly rather than
  presenting a partial reconciliation. If the daemon cannot be observed, the
  overlay becomes explicitly stale and names
  `:AI/reconnect` or reopening the worker as recovery; neither path resubmits the
  prompt or rewrites the daemon-owned lifecycle.

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
- §nvim-command-discovery **One command contract** — one registry owns `:AI/`
  dispatch, the complete root inventory, concise `/help <verb>` guidance,
  contextual completion, and default key descriptions. Completion offers
  declared model aliases, child inheritance, daemon-supported reasoning
  policies, and local files only where a command consumes one. MCP, Skill,
  A2A, and file members aliases are fetched lazily from the current Worker only
  at alias-taking positions and cached per Worker; a failed lookup changes no
  command or durable state. It never caches the full model catalog; exact-route discovery remains
  explicit through `/models [search]`. Editor-native `/open`, `/reconnect`,
  `/next`, `/prev`, and `/clear` are presentation controls rather than a second
  operation vocabulary.
- §nvim-workspace-mcp-controls **Workspace MCP controls are daemon actions** —
  the client tokenizes quoted alias/target arguments and JSON-decodes an
  optional local options file. The daemon owns normalization, schema
  validation, connection behavior, persistence, protocol compatibility, and
  exact Problem Details; symbolic credential references remain unchanged.

  | Input | AG-UI+ action |
  |---|---|
  | `:AI/mcp` | `worker.mcp.list {}` |
  | `:AI/mcp discover <url\|command>` | `worker.mcp.discover {source}` |
  | `:AI/mcp add <alias> <target> [options.json]` | `worker.mcp.add {alias, definition}` — the client composes the exact `McpServerDefinition`: `name = alias`; an absolute `http(s)://` target is `{transport: "http", url}`, anything else `{transport: "stdio", command, args: {}}`; `options.json` supplies the remaining definition members |
  | `:AI/mcp enable <alias> [options.json]` | Without options, `worker.mcp.enable {alias}`. With options, list the current definition and send `worker.mcp.add {alias, definition: {...current, ...options}}` to specialize it for this Worker. |
  | `:AI/mcp disable <alias>` | `worker.mcp.disable {alias}` |
  | `:AI/mcp remove <alias>` | `worker.mcp.remove {alias}` |
  | `:AI/mcp oauth <alias> <callback-url>` | `worker.mcp.oauth.complete {alias, callbackUrl}` |

  Interactive authorization prints the URL and exact completion command.
  Unreadable or invalid local JSON stops before dispatch. Daemon Problems,
  including unsupported protocol revisions, use the existing lossless Problem
  path and are neither rewritten nor retried.

- §nvim-universal-agent-skills **Agent Skills are daemon actions** —
  `:AI/skills` is a thin projection of the Worker's `skills` Functionality
  family, the same common lifecycle as `:AI/mcp`. The client composes one
  exact `SkillDefinition` and renders the daemon's states; it runs no package
  manager, reads no registry, parses no frontmatter, and keeps no package
  metadata. The universal roots (`.agents/skills` in the project,
  `~/.agents/skills` globally) stay interoperable with every other agent; a
  skill installed there by any other tool is admitted by the daemon at the
  next turn.

  | Input | AG-UI+ action |
  |---|---|
  | `:AI/skills` | `worker.skills.list {}` |
  | `:AI/skills discover <query>` | `worker.skills.discover {query}` — registry search |
  | `:AI/skills discover <source>` | `worker.skills.discover {source}` — a single term holding `/`, `:`, or `\\`, or starting with `.` or `~`, is a package reference |
  | `:AI/skills add <name> <source> [--global]` | `worker.skills.add {alias, definition: {name, scope, source}}` with `scope` `project` unless `--global` |
  | `:AI/skills enable <name>` | `worker.skills.enable {alias}` |
  | `:AI/skills disable <name>` | `worker.skills.disable {alias}` |
  | `:AI/skills remove <name>` | `worker.skills.remove {alias}` |

  Daemon Problems use the existing lossless Problem path and are neither
  rewritten nor retried.

- §nvim-outbound-agents **Outbound A2A agents are daemon actions** —
  `:AI/agents` is a thin projection of the Worker's `agents` Functionality
  family, the same common lifecycle as `:AI/mcp` and `:AI/skills`. The client
  composes one exact `A2aAgentDefinition` and renders the daemon's states; the
  remote Agent Card, connection, and enablement policy live in the service, and
  the model addresses an enabled agent as `a2a://<alias>`.

  | Input | AG-UI+ action |
  |---|---|
  | `:AI/agents` | `worker.agents.list {}` |
  | `:AI/agents discover <url>` | `worker.agents.discover {source}` — one inert card-derived candidate |
  | `:AI/agents add <alias> <url> [options.json]` | `worker.agents.add {alias, definition: {name: alias, url, ...options}}`; `options.json` supplies `cardPath`, `headers`, `authorization` |
  | `:AI/agents enable <alias>` | `worker.agents.enable {alias}` |
  | `:AI/agents disable <alias>` | `worker.agents.disable {alias}` |
  | `:AI/agents remove <alias>` | `worker.agents.remove {alias}` |

  Unreadable or invalid local JSON stops before dispatch; daemon Problems use
  the existing lossless Problem path and are neither rewritten nor retried.

- §nvim-file-members **File members are daemon actions** — `:AI/members`
  (natively `:PlurnkMembers`) is a thin projection of the Worker's `members`
  Functionality family, the same common lifecycle as `:AI/mcp`, `:AI/skills`,
  and `:AI/agents`. Git-tracked files are members on their own; a definition
  is one gitignore-style glob relative to the project root that includes
  matching untracked files or, with a leading `!`, excludes matching members —
  an exclusion wins over every inclusion. The client composes one exact
  `{glob}` definition, passing a `!` verbatim, and renders the daemon's states
  and verdicts; resolution, the model's ceiling, and enablement policy live in
  the service. The glob is tokenized exactly as the sibling families tokenize
  their arguments (quote it to keep whitespace).

  | Input | AG-UI+ action |
  |---|---|
  | `:AI/members` | `worker.members.list {}` — one line per definition with what its glob resolved to: `docs  active  include docs/** → 12 files (3 ignored)  (service)` |
  | `:AI/members discover [path\|glob]` | `worker.members.discover {query}` — one candidate explaining why a file is or is not a member, or previewing what `add` would include or exclude; without an argument, the query is the current file buffer's project-relative path, and a non-file buffer diagnoses usage |
  | `:AI/members add <alias> <glob>` | `worker.members.add {alias, definition: {glob}}` |
  | `:AI/members enable <alias>` | `worker.members.enable {alias}` |
  | `:AI/members disable <alias>` | `worker.members.disable {alias}` |
  | `:AI/members remove <alias>` | `worker.members.remove {alias}` |

  Every mutation refreshes the membership gutter signs. Daemon Problems — a
  headless workspace, an invalid pattern, a service-owned definition that
  cannot be removed — use the existing lossless Problem path and are neither
  rewritten nor retried.

## §4 Workspaces and workers

- **The name is the identity** — `workspace.create` returns
  `{id, name}` and the workspace lists by exact name; `workspace.list` is the world
  directory.
- **The waterfall shows THE CONVERSATION** — only the model
  worker renders in the workspace waterfall; client-worker rows (the connection's op.* scratch)
  stay out. The conversation worker is adopted from events arriving while a loop is in
  flight.
- **Worker-keyed routing** — entries route to their worker's buffer by
  `entry.worker_id`, no interleaving; a pending record is adopted by the first worker seen.
- **Fork branches the conversation** — `:PlurnkFork` / `:AI????` →
  `run.fork`, optionally named at instantiation (immutable after), then binds to the
  new worker.
- **Rename is a mutable handle on the world** — `workspace.rename`
  rekeys local state and the worker tab in place; a worker's name is immutable.
- **Project root defaults to the editor cwd** — `workspace.create`
  is not headless by accident; file ops depend on it.

## §5 Rendering

- **The worker tab** — `:AI` opens a workspace tabpage with two windows:
  waterfall on top, input at the bottom; submitting populates the waterfall and leaves
  focus on the input; an actionless `prompt` row renders as `❯` speech from `rx.content`.
- **The waterfall shares one visual language with the terminal client** — every
  glyph-bearing row begins at column zero. Non-SEND operations carry their operation
  glyph and a secondary-status slot; SENDs carry one lifecycle glyph regardless of
  producer. SEND lifecycle glyphs are `▶️` (102), `⏹️` (200), 💤 (202), 🤔 (300), and ✋
  (499). Broadcast and routine directed SEND codes remain wire truth without
  repeating in human output; a failed directed SEND and any other failed operation
  retain their diagnostic code.
  Targets, scopes, previews, and literal annotations use one-space separators.
- **Deliberate divergences are editor-native presentation only** — the
  durable prompt row remains visible because submission clears the input buffer;
  live streams use dedicated buffers and splits. The operation vocabulary, lifecycle
  states, GFM semantics, and row grammar do not diverge.

- §nvim-markdown-projection **Markdown is projected per model body** — the
  source entry remains authoritative while each body is independently projected at
  the live waterfall width. Plurnk control rows are never parsed as Markdown and one
  body's syntax state cannot style another block. If the public `plurnk` executable is
  on `PATH`, the client first verifies the exact daemon-free filter through
  `plurnk render --help`, then asynchronously invokes `render --width` over
  stdin/stdout and caches plain-Unicode output by source and width. An executable that
  does not advertise that capability never receives model content. That shared
  renderer owns GFM, task lists, wrapping tables with row separators, code headers,
  and Beautiful Mermaid. If discovery or projection fails, the body remains faithful
  semantic source. The filter is optional presentation only: no install, network
  access, provider call, or protocol traffic passes through it. Resize reprojects the
  retained source at the new width.

- §nvim-waterfall-folding **Multi-line blocks auto-fold** — every multi-line
  waterfall block (reasoning, PLAN, prompt bodies, non-terminal broadcast
  bodies) is created as a closed manual fold except the model's broadcast
  answer, which stays open. Folds persist per worker record and are recreated
  when a waterfall window reprojects; fold text preserves the block's first row
  without Neovim's default gutter decoration. Ordinary fold motions (za, zR) reopen
  blocks.
- **Plan entries remain structured** — PLAN consumes the ACP Plan projection and
  renders its complete entry list in source order, one line each: ✅ `completed`,
  🚧 `in_progress`, and ⬜ `pending`; `completed` content beginning "Memory: "
  renders as 💾 without the projection prefix.
  The first line carries a failed PLAN's glyph and code (a routine PLAN carries neither); later lines
  align beneath it. Entry whitespace collapses to one line, neutral `medium` priority
  is implicit, and non-neutral priority renders as `[high]` or `[low]`. An empty Plan
  renders `📭 no entries`.
- **Operation annotations stay labels** — a present durable annotation follows the
  canonical row as sanitized literal text; Markdown and HTML are not interpreted.
- **Broadcast prose remains source-faithful except for exact terminal typography** —
  the common inline token `$\rightarrow$` renders as `→`; this is not general LaTeX
  or Markdown interpretation.
- §nvim-readable-reasoning **Provider reasoning is a separate presentation lane** —
  standard AG-UI reasoning deltas update one `💭` buffer region in place as they
  arrive. The completed region precedes the paired SEND and a multiline block then
  becomes a native closed fold; absent, empty, and encrypted reasoning invent no
  readable transcript. Replaying a completed message identity is idempotent; malformed
  ordering within a live message fails at the client boundary.
  PLAN remains the model's durable working-memory inventory.
- **Stream windows** — channel prefixes + interleave, batched
  flush (one `entry.read` per tick burst), partial-line hold, a conclusion footer, and
  `BufWipeout` → an `op.send` cancellation carrying status 499.
- **Diagnostics share the terminal projection** — Problems and Notices render
  `📡 source:kind [position] ["message"]` at column zero, with snippet, recovery,
  and hint lines nested by three spaces. Required `notice.level` maps error →
  ErrorMsg, warn → WarningMsg, info → Comment; no kind heuristic.
- **Compact activity mirrors the terminal clients** — derivation, search
  acquisition, and serialized branch progress share one plain `N%` statusline
  slot and never append progress ticks to the waterfall. Below-completion
  progress supersedes exact `⌛︎` while a loop is active; completion clears the
  slot, exposing idle 🔥 only when YOLO is armed. Branch completion, failure,
  and recovery still append one durable summary.
- **Membership signs mark the exception only** — each visible project file is
  asked about through `worker.members.discover` on its project-relative path,
  quietly; a file the daemon's verdict reports as `excluded` gets a 🚫 line-1
  extmark, while members, untracked candidates, and ignored files get no sign.
  The client matches no glob itself.
- **The statusline is lean** — one activity slot only; the rich identity, terminal
  lifecycle, and accounting detail live in the winbar.
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
  the terminal `⏹️` SEND without repeating its numeric wire status.
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
- §nvim-model-discovery **Model selection is server-backed and discovery is lazy** —
  the worker owns the model ({§worker-model-selection}). `/model <selector>` accepts
  either a declared alias or exact `provider/model`; `worker.model.set {selector}`
  resolves and persists it, and the statusbar/winbar uses the returned route as truth.
  `/models [search]` opens a picker combining the small alias directory with one
  bounded `models.list` page; a continuation item fetches the next page. No catalog
  is fetched at startup, injected into a packet, or used to probe a provider. A pick
  made before workspace creation is persisted once after creation. Nothing
  model-related rides an individual loop.
- §nvim-generation-policy-admission **Deliberate generation policy is admitted before inference** —
  pending model, child-model, and reasoning selections persist in that order before
  a prompt is submitted. A rejected or malformed result retains the requested
  selections and prevents the prompt from running under stale policy.
- §nvim-child-provider-selection **Child selection sticks per workspace** —
  `/child` reports the worker's persisted override (hydrated via `worker.model.get`),
  `/child <selector>` persists it via `worker.child.set`, and `/child inherit` sends
  `selector: null` (clearing the override); `PLURNK_MODEL_CHILD` seeds the worker
  server-side from the daemon's own env.
- §nvim-reasoning-policy **Reasoning is a separate durable worker policy** —
  `/reasoning` reads the effective policy and daemon-supported choices;
  `/reasoning <policy>` persists one through `worker.reasoning.set`. A selection
  made before workspace creation is consumed once after model and child
  selection, never forwarded on `loop.run`. Attach and worker switches hydrate
  the daemon value, model changes refresh its supported choices, and the worker
  winbar renders the effective policy independently of the model selector. The
  client owns no provider-effort catalog and preserves daemon Problems.
- **Execs policy forwards; secrets never do** — `PLURNK_EXECS_*`
  enable/disable grammar rides verbatim for the daemon's subtractive intersection;
  `PLURNK_EXECS_MCP_*` server configs (URLs, bearer tokens) never touch the wire.
- **Interactive provider authentication belongs to third-party MCP tooling.**

## §9 Diagnostics

- §nvim-installed-journey **The packaged default journey is a release gate** —
  a clean installed-layout copy of the plugin uses its default mappings and native
  multiline input against the built daemon and a deterministic standards-compatible
  provider. The specimen must stop a real side effect for review, resume the same
  logical loop, complete its second inference, and render reasoning, operations,
  PLAN, SEND, and settled authoritative lifecycle without asynchronous callback
  failures. The gate admits daemon-backed specimens only after worldless AG-UI+
  `discover` succeeds; listener ownership during durable recovery is not readiness.
  Stochastic real-model dogfooding remains a separate opt-in tier.
- §nvim-health-surface **Health reports evidence without activating the
  runtime** — `:checkhealth plurnk` reports the resolved plugin path and Git
  describe/remote metadata when present, Neovim and curl requirements, the
  optional local Markdown renderer, a credential-free daemon authority, and
  every enabled default mode mapping. It invokes only worldless AG-UI+
  `discover`: no workspace is created, no Functionality is enabled, and no
  provider or model is contacted.
- **Protocol metadata, not unrelated package semver, owns compatibility** — the
  client requires AG-UI+ discovery schema 1 and every schema-bearing action,
  notification, and display member in its executable conformance manifest.
  A lower schema is stale, a higher schema is unsupported, and a same-version
  response missing a consumed capability is incompatible. Source projections
  without Git metadata are reported honestly as unversioned.
- **Optional defaults never overwrite editor state** — each requested mode
  mapping fills independently. Setup emits at most one aggregate warning when
  occupied keys are skipped; healthy setup is silent. Health checks the entire
  enabled inventory and reports the existing description and script owner when
  Neovim exposes them.
