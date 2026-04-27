# Real-Coder Layer (OpenCode via ACP)

Springdrift's coder agent doesn't write code itself. It drives a separate
coding agent — [OpenCode](https://github.com/sst/opencode) — running in a
sandboxed podman container, communicating over the [Agent Client
Protocol](https://opencode.ai/docs/acp/) (ACP). The layer that owns the
container pool, drives ACP sessions, enforces per-task budgets, and
ingests completed sessions into CBR memory is the *real-coder layer*.

This document describes the layer end-to-end. The cognitive-loop side
(how `dispatch_coder` lands as a tool call, how the cog stays
responsive while the dispatch runs) is covered in
[cognitive-loop.md](cognitive-loop.md); the operator-facing setup
(image build, config, project_root safety) is in
[operators-manual.md](../operators-manual.md).

## 1. Overview — Why ACP and Why a Container

OpenCode is a polyglot coding agent. Inside its container it has shell
access, git, gh, ripgrep, fd, multiple language toolchains, and the
ability to read/edit/run arbitrary files in a bind-mounted project
directory. This is exactly what a coder agent needs and exactly what
Springdrift can't safely give the cognitive loop directly.

The trust boundary is the container, not the protocol. Rootless podman
+ `--userns=keep-id` + `--security-opt no-new-privileges` + memory /
CPU / pid caps bound the blast radius. The host bind-mount is a
single, operator-chosen project directory; the agent's own
`.springdrift/` data is structurally inaccessible (see §8).

ACP is the wire protocol: JSON-RPC over stdio. We picked it after
trying a REST-wrapped session approach (deleted in v0.10.0); ACP gave
us native session lifecycle, streaming events, cancel semantics, and
budget hooks for ~25% of the LOC.

## 2. Architecture

```
┌─────────────────────┐
│  cognitive loop     │
│  (or agent_coder)   │
└──────────┬──────────┘
           │ dispatch_coder(brief, budget)
           ▼
┌─────────────────────┐         ┌──────────────────────┐
│  CoderManager       │◄────────│  per-dispatch driver │
│  (OTP actor)        │ Driver  │  (process)           │
│  - container pool   │ Started └──────────┬───────────┘
│  - hourly cost cap  │                    │ ACP / stdio
│  - cancel routing   │                    ▼
│  - janitor TTL      │         ┌──────────────────────┐
└─────────────────────┘         │  podman exec -i      │
                                │   <container>        │
                                │   opencode acp       │
                                └──────────────────────┘
```

| Component | Source | Responsibility |
|---|---|---|
| `CoderManager` | `coder/manager.gleam` | OTP actor owning the pool. One per Springdrift instance. Allocates a container per dispatch, spawns a driver, tracks hourly cost, runs janitor. |
| Driver | `coder/manager.gleam` (`drive_session/...`) | Per-dispatch process. Owns the ACP handle for one session. Runs the prompt, enforces budget, handles cancel. |
| ACP bindings | `coder/acp.gleam` | JSON-RPC over stdio. `open` / `initialize` / `session_new` / `session_prompt(_async)` / `session_cancel` / `close`. Pure decoders pinned against probed shapes. |
| Container pool | `coder/manager.gleam` | Warm pool (default 1) + spawn-on-demand up to `max_concurrent_sessions` (default 4). Containers persist across dispatches; janitor reaps idle containers past `container_idle_ttl_ms`. |
| Ingestion | `coder/ingest.gleam` | Completed dispatch → CbrCase (CodePattern category) + raw JSON archive in `.springdrift/memory/coder/sessions/`. |
| Circuit breaker | `coder/circuit.gleam` | Pure token / cost computation. Per-task and rolling-hour caps. |
| Image build | `Containerfile.coder` + `scripts/build-coder-image.sh` | Pinned OpenCode version (1.14.25 as of v0.10.0). Auto-built on first boot if missing. |

## 3. ACP — the JSON-RPC Layer

ACP runs over the subprocess's stdio. The `acp.gleam` module spawns
`podman exec -i <container> opencode acp` and routes messages through
an Erlang controller process.

| Method | Purpose | Springdrift wrapper |
|---|---|---|
| `initialize` | Negotiate capabilities, return `agent_capabilities` | `acp.initialize/2` |
| `session/new` | Create a session, return `session_id` | `acp.session_new/2` |
| `session/prompt` | Send a prompt, block until completion | `acp.session_prompt/3` |
| `session/prompt` (async) | Send a prompt, return a reply subject + event stream | `acp.session_prompt_async/4` |
| `session/cancel` | Graceful cancel — stop_reason: `cancelled` | `acp.session_cancel/2` |

Streaming events (`session/update` notifications):

| Event | Type | Springdrift action |
|---|---|---|
| `agent_thought_chunk` | Reasoning model output | Logged at debug; not sent to cog |
| `agent_message_chunk` | Natural-language response | Accumulated into `accumulated_text` |
| `tool_call` | Agent invoked an in-container tool | Title appended to `tool_titles` (drives CBR `tools_used`) |
| `tool_call_update` | Tool status change | Logged at debug |
| `usage_update` | Cumulative tokens + cost | Drives circuit breaker; persisted on `DispatchResult` |
| `unknown` | Future ACP shapes | Decoded as `AcpUnknown(raw_json:)` so older Springdrift builds don't crash on newer OpenCode versions |

Stop reasons returned in `PromptResult`: `end_turn`, `max_tokens`,
`max_turn_requests`, `refusal`, `cancelled`.

## 4. Lifecycle of a Dispatch

```
1. cog calls dispatch_coder(brief, budget)
2. CoderManager.Dispatch arrives
3. acquire_container — reuse warm container or spawn a new one
4. spawn driver process
5. driver: acp.open → initialize → session_new
6. driver: session_prompt_async, fold events:
     - text chunks  → accumulate
     - usage updates → check budget breach
     - tool calls   → track titles
7. on completion (or breach):
     - acp.close (kills subprocess)
     - ingest_session (CBR + JSON archive)
     - reply DispatchResult to caller
     - notify manager: DriverFinished
8. manager: mark container idle, ready for next dispatch
```

Container reuse is by default. Each dispatch gets its own ACP session
inside the same container; OpenCode handles session isolation
internally. The container is reaped by the janitor only after
`container_idle_ttl_ms` (default 1h) of no use.

## 5. Three-Stage Kill Chain

When `cancel_coder_session(session_id)` arrives at the manager, or
when a budget breach fires:

1. **Graceful** — `acp.session_cancel(handle, session_id)`. OpenCode
   responds with `stop_reason: cancelled` once the current model turn
   completes. Usually within 1–2 seconds.
2. **Subprocess close** — `acp.close(handle)`. Kills the
   `podman exec -i` subprocess. OpenCode terminates without delivering
   final events. Usually unnecessary, but covers the case where the
   model loops and ignores cancel.
3. **Container teardown** — operator-only, `podman kill`. The manager
   does NOT auto-tear-down containers on cancel; that's a manual
   intervention. The container stays warm for the next dispatch.

The three stages are layered: stage 1 covers ~95% of cancels cleanly;
stages 2 and 3 are escalations.

## 6. Budget Enforcement

Per-task budget (`TaskBudget`):
- `max_tokens`, `max_cost_usd`, `max_minutes`, `max_turns`

Defaults from `[coder.budget]` config. The agent can request a higher
value via `dispatch_coder` parameters; the manager *clamps* the
request to the operator's ceiling and reports the clamp in the
result. This is "agency within bounds" — the agent expresses what
it'd like, the operator's ceiling is the wall.

Mid-session breaches:
- Token / cost budget → `acp.session_cancel` + drain to completion;
  result returns with `stop_reason: cancelled`
- Wall-clock budget (`max_minutes`) → driver-side timer fires
  `AcpTimeout`; same drain path
- Hourly aggregate cost cap (`max_cost_per_hour_usd`) → manager
  refuses new dispatches until the rolling-hour window rolls

The circuit breaker (`coder/circuit.gleam`) is a pure module — given
current usage and budget, returns Continue / Breach. Easy to test in
isolation.

## 7. CBR Ingestion

Every completed dispatch (success or failure) produces:

1. **A `CbrCase`** (category: `CodePattern`) appended to
   `.springdrift/memory/cbr/cases.jsonl` with:
   - `problem.intent = "code"`, `domain = "code"`
   - `problem.user_input` = the original brief (truncated 2000 chars)
   - `problem.keywords` = cheap token extraction from the brief
   - `solution.approach` = "OpenCode coder driven via <model_id>"
   - `solution.tools_used` = the distinct OpenCode tool titles seen
     during the session (e.g. `["Read", "Edit", "Bash"]`). Drives CBR
     retrieval — "previous session that used Read+Edit+Bash" is a
     strong signal for new code-edit briefs.
   - `solution.steps` = chronological turn-by-turn `prompt → response`
     truncated to 200 chars each
   - `outcome.status = "completed"`, `confidence = 0.5`, assessment
     names turn count + duration + tool count
2. **A raw JSON archive** at
   `.springdrift/memory/coder/sessions/<session_id>.json` containing
   the full conversation + tool_titles + duration + model_id. For
   forensics + replay; not normally read at runtime.

Future Phase 4.x work: integrate host-side test/build verdicts into
`outcome.status` and `confidence`. Today the outcome is structural
only.

## 8. Project Root Safety (v0.10.1)

The OpenCode container's bind-mount target is the operator's
`[coder] project_root`. If unset, defaults to
`${TMPDIR:-/tmp}/springdrift-coder-workspace` (auto-created,
per-user via TMPDIR on macOS, /tmp on Linux). Always disjoint from
cwd by construction.

Refused at startup (in `springdrift.maybe_build_real_coder_deps` /
`project_root_safe`):
- empty string or `"."`
- any path containing a `.springdrift/` subdirectory (would let
  the coder edit the agent's own state)
- any path that IS a `.springdrift/` data directory

The path check is "don't shoot yourself" — the actual security
boundary is the rootless-podman container + capability drops + the
trust boundary of the OpenCode model itself. The check just ensures
the operator can't accidentally point the bind-mount at the running
agent's data dir.

## 9. Two Caller Surfaces

**`dispatch_coder` on the cog/PM** (async via OTP worker):
- Cog or PM emits `dispatch_coder(brief, budget)`
- Cog spawns an unlinked worker; the worker calls
  `manager.dispatch_task` synchronously
- Cog status moves to `WaitingForAgents`; cog stays free to handle
  sensory events, scheduler ticks, queued user input
- When the worker finishes, it sends `CoderDispatchComplete` back to
  cog; cog folds the result into the message history as a
  `tool_result` and re-thinks
- `cancel_coder_session` is reachable from any subsequent cog turn

**`agent_coder` specialist** (synchronous within the agent's
process):
- `agent_coder` is a thin specialist registered when `[coder]` is
  fully configured
- Its react loop calls `dispatch_coder` synchronously inside its own
  process
- Other agents and the cog are unaffected by the block — the
  specialist's process is the worker
- Multiple sequential dispatches in one task fall out naturally
  (specialist iterates: frame → dispatch → inspect → dispatch
  again → land)

Both paths share the same `CoderManager`, so budget caps and
container pool are global.

## 10. Configuration

`[coder]` (operator-set):
- `image` (default: `springdrift-coder:1.14.25`)
- `project_root` — REQUIRED to point at a directory not containing
  `.springdrift/`; defaults to the temp scratch dir
- `provider_id` (default: `anthropic`)
- `model_id` (default: `claude-sonnet-4-6`)
- `session_timeout_ms` (default: 600000 / 10 min hard wall)
- `max_cost_per_hour_usd` (default: 20.0)
- `cost_poll_interval_ms` (default: 5000)
- `image_recovery_enabled` / `image_pull_timeout_ms` — auto-recovery
  when podman reports a corrupt image

`[coder.budget]` (per-task defaults + ceilings):
- `default_max_tokens_per_task` / `ceiling_max_tokens_per_task`
- `default_max_cost_per_task_usd` / `ceiling_max_cost_per_task_usd`
- `default_max_minutes_per_task` / `ceiling_max_minutes_per_task`
- `default_max_turns_per_task` / `ceiling_max_turns_per_task`

Container pool tuning (`[coder]`):
- `warm_pool_size` (default: 1)
- `max_concurrent_sessions` (default: 4)
- `container_idle_ttl_ms` (default: 1h)
- `container_memory_mb` (default: 2048)
- `container_cpus` (default: "2")
- `container_pids_limit` (default: 256)

Auto-wire policy: when `[coder]` is fully configured AND
`ANTHROPIC_API_KEY` is set, `agent_coder` is registered and
`dispatch_coder` is on the cog tool surface. Otherwise both are
absent (legacy modes were removed in v0.10.0).

## 11. Source Files

```
src/coder/
├── acp.gleam          # JSON-RPC stdio bindings, AcpEvent stream, decoders
├── circuit.gleam      # Pure token/cost circuit breaker
├── ingest.gleam       # Dispatch → CbrCase + JSON archive
├── manager.gleam      # OTP actor: pool, driver, kill chain, janitor
└── types.gleam        # CoderConfig, CoderError, TaskBudget, BudgetClamp,
                       # DispatchResult, SessionSummary, format_error/1

src/tools/
├── coder.gleam            # project_status / project_read / project_grep
└── coder_dispatch.gleam   # dispatch_coder / cancel / list, async worker spawn

src/agents/
└── coder.gleam        # agent_coder specialist (real-coder mode only)

Containerfile.coder    # Pinned OpenCode image
scripts/
├── build-coder-image.sh
├── smoke-coder-image.sh
├── e2e-coder.sh           # Real container + real LLM, ~$0.001/run
├── discover-coder-endpoints.sh
└── vendor-opencode-spec.sh
```

## 12. Known Limitations (v0.10.1)

- **Mid-session subprocess exit (status 0)** — OpenCode occasionally
  exits cleanly mid-dispatch. The driver flags it as failure; the
  agent re-dispatches. Root cause not yet pinned; possibly OpenCode
  treats certain `stop_reason` values as "session done, exit". Future
  work: distinguish clean exit from premature exit via the final
  `PromptResult` shape.
- **Orphan tool_use across cog↔agent boundary** — the
  `MessageHistory` state machine prevents user-side orphans inside
  cog's history but doesn't yet cover the case where an agent's
  tool_use propagates to cog when the agent's react loop dies
  mid-dispatch. See [message-history.md](message-history.md) §5 for
  the boundary discussion.
- **Long sessions are alpha.** Short paths (single dispatch, < 2 min)
  are reliable; multi-turn iteration past ~5 min is where the
  follow-on bugs live.
