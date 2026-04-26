# Real Coder — OpenCode embedded via ACP, SD as landlord

**Status**: Locked architecture. Rebuild in progress (tasks R1-R7).
**Replaces**: an earlier REST-shaped attempt against OpenCode 0.4.7. That
plan was wrong on the protocol choice and the version pin; lessons in
user memory (`feedback_check_actual_state.md`,
`feedback_no_scaffolding_for_unattended_llms.md`).

## The architecture

```
Springdrift (host, Gleam/OTP)                                    │
│                                                                │
│  Cog Loop / PM / Planner ── decide WHAT to dispatch            │
│            │                                                   │
│            ▼                                                   │
│  CoderManager (OTP actor)                                      │
│    - Owns 1 warm container + spawns extras on demand           │
│    - Per session: ACP stdio dialogue, usage tracking,          │
│      wall-clock timer, three-stage kill chain                  │
│    - Persistent containers (no --rm), janitor TTL              │
│            │                                                   │
└────────────┼───────────────────────────────────────────────────┘
             │ podman exec -i <container> opencode acp
             │ JSON-RPC over stdio
             ▼
   ┌───────────────────────────────────────────────────────────┐
   │ Container (Podman, rootless + userns=keep-id)              │
   │   springdrift-coder:1.14.25                                │
   │   - root user inside (container is the boundary)           │
   │   - opencode + git + gh + ripgrep + fd + node + python     │
   │   - project bind-mounted r/w at /workspace/project         │
   │   - SPRINGDRIFT_CODER_GITHUB_TOKEN env passed in           │
   │   - opencode auth.json under /root/.config/opencode        │
   │   - resource limits: memory, cpus, pids                    │
   │   - --security-opt no-new-privileges                       │
   │ ─────────────────────────────────────────────────────────  │
   │   In here, OpenCode is the agent. It reads, edits, runs    │
   │   tests, commits. SD does NOT look over its shoulder.      │
   └───────────────────────────────────────────────────────────┘
             │ session/update events streamed back
             │ session/prompt response with stopReason
             ▼
   CBR ingest (manager) — record outcome as CbrCase, archive
   raw session JSON. Future dispatches retrieve similar past
   work for the brief.
```

## The principles that drove this shape

1. **Container is the trust boundary.** Inside is OpenCode's domain; SD
   provides the room and the door, doesn't supervise turn-by-turn.
2. **One LLM in the loop.** Earlier design nested two LLMs (an SD coder
   agent driving the in-container LLM). That's pure overhead. The
   in-container LLM is the agent; SD dispatches and observes.
3. **No scaffolding "in case the LLM does it wrong."** For autonomous
   systems on a VPS, every hardcoded duplicate-of-LLM-work is a 3am
   debugging session. Trust the LLM; the safety nets are budget caps,
   sandboxing, and cancellation — nothing else.
4. **SD as landlord, not jailer.** SD has `podman exec` access to the
   container, can install packages, run gh, inspect state. No black
   holes.

## Configuration surface

```toml
[coder]
image                       = "springdrift-coder:1.14.25"
project_root                = "/Users/op/Repos/foo"
auth_config_path            = "~/.config/opencode"   # bind-mounted ro

# Pool
warm_pool_size              = 1
max_concurrent_sessions     = 4
container_idle_ttl_ms       = 3600000                # janitor TTL (1h)
container_name_prefix       = "springdrift-coder"
slot_id_base                = 100

# Container resource limits — kernel-enforced, can't be circumvented
container_memory_mb         = 2048
container_cpus              = "2"
container_pids_limit        = 256

# Provider (passed to opencode)
provider_id                 = "anthropic"
model_id                    = "claude-haiku-4-5-20251001"

[coder.budget]
# Defaults applied when dispatcher doesn't specify
default_max_tokens_per_task     = 200000
default_max_cost_per_task_usd   = 5.0
default_max_minutes_per_task    = 10
default_max_turns_per_task      = 20

# Ceilings — agent cannot exceed regardless of request
ceiling_max_tokens_per_task     = 1000000
ceiling_max_cost_per_task_usd   = 50.0
ceiling_max_minutes_per_task    = 60
ceiling_max_turns_per_task      = 100

# Hourly aggregate — independent wall, applies regardless
max_cost_per_hour_usd           = 100.0
```

Env vars (operator-set, two separate tokens):

- `ANTHROPIC_API_KEY` — passed into container as env, OpenCode picks it up
- `SPRINGDRIFT_CODER_GITHUB_TOKEN` — passed in for the coder's `gh` CLI
- `SPRINGDRIFT_BACKUP_GITHUB_TOKEN` — separate, for SD's `.springdrift/`
  memory backup repo (existing concern, unchanged)

No magic numbers in source code. Everything from config or computed at
boot.

## Cog-loop tools (one entry per concern)

| Tool | What it does |
|---|---|
| `dispatch_coder(brief, ...budget)` | Send a coding task. Optional per-task budget overrides — clamp-and-report against ceilings if exceeded. Returns: commit metadata, cost, outcome summary, session_id |
| `cancel_coder_session(session_id)` | Three-stage kill chain (see below) |
| `list_coder_sessions` | Inspect what sessions exist on which containers |
| `resume_coder_session(session_id, additional_brief)` | Use ACP's `session/load` capability — pick up yesterday's work |

That's it. No multi-tool surface micromanaging the in-container LLM. The
cog loop / PM does CBR retrieval as a separate step, formats it into
the brief, dispatches.

## The kill chain (real safety, not scaffolding)

| Trigger | Action |
|---|---|
| `usage_update` shows cost > per-task cap | Manager fires cancel immediately (synchronous on event) |
| Wall-clock timer fires (`per_task_minutes`) | Manager fires cancel |
| Operator clicks Cancel in web GUI | `cancel_coder_session` tool fires cancel |
| Hourly aggregate exceeds cap | Reject new dispatches; ongoing ones run to per-task cap |

Cancel itself is four layers, each with its own short timeout:

1. **Graceful** — send ACP `session/cancel`, wait 5s for `stopReason: cancelled`
2. **Subprocess** — kill the `podman exec opencode acp` child, wait 3s
3. **Container** — `podman kill <container_id>`, wait 2s
4. **Operator escape hatch** — `podman rm -f` from host shell always works

## What's kept from the prior attempt

- `Containerfile.coder` — already updated for 1.14.25 + root + gh
- All `scripts/*.sh` — build, smoke, discover, vendor, probe, e2e
- `coder/types.gleam` — most of it (some error variants will shift)
- `coder/circuit.gleam` — finally meaningful with real ACP usage data
- `coder/ingest.gleam` — CBR mapping, gets richer with tool_result events
- `paths.gleam` — `coder_sessions_dir`
- The `--userns=keep-id` and `/tmp` learnings (in operator manual)

## What's deleted

- `coder/client.gleam` — REST client, replaced by ACP
- `coder/supervisor.gleam` — collapses into manager
- `http_probe_get` FFI in `springdrift_ffi.erl`
- `tools/coder.gleam` host-side `run_tests` / `run_build` / `run_format`
  and their `ProjectCommands` infrastructure (LLM runs them in-container,
  ACP carries `tool_result` evidence)
- The Springdrift "coder agent" as an LLM-driven react loop
  (`agents/coder.gleam` collapses or disappears — dispatch is a tool,
  not an agent)
- All three legacy modes (real-coder / sandbox-only / reasoning-only)
- The detailed "engineering loop" system prompt that taught OpenCode
  how to code

## Implementation chunks (current task list)

1. **R1** Rewrite this doc to reflect locked architecture *(in progress)*
2. **R2** Add `[coder.budget]` config + container resource limits
3. **R3** Build `coder/acp.gleam` — JSON-RPC over stdio
4. **R4** Rewrite `coder/manager.gleam` for ACP + N sessions + kill chain
5. **R5** Cog-loop tools: `dispatch_coder` etc.
6. **R6** Delete obsolete REST plumbing
7. **R7** Update e2e + CBR ingest for ACP shape, update CLAUDE.md +
   operator manual

## Carried forward as durable findings

These are operator-facing facts independent of protocol choice:

- **`--userns=keep-id` is required**. Without it, bind-mounted project
  surfaces as `nobody:nogroup` inside the container and OpenCode fails
  silently.
- **`/tmp` cannot be `project_root`** on macOS podman (root-owned, idmap
  collision). Use a user-owned directory.
- **OpenCode catalog tracks Anthropic releases imperfectly**. Bump
  OpenCode versions periodically to pick up new model IDs (procedure
  in operator manual). The pinned 1.14.25 has Claude 4.x and 4.5/4.7
  variants.
- **Container persistence enables resume**. Janitor reaps idle
  containers after TTL, but until then sessions on them are accessible
  via ACP `session/load`.

## Out of scope (deferred or rejected)

- **MCP**: OpenCode supports MCP servers natively. Not blocking; we
  could later expose Springdrift's memory as an MCP server so the
  in-session LLM pulls CBR / facts as tools. Useful, not urgent.
- **Real-time SSE**: ACP `session/update` notifications cover this
  natively. No separate SSE client needed.
- **MCP-shaped Springdrift memory exposure**: future cycles work.
- **Multi-project routing**: one project_root per coder configuration.
  Operators with multiple projects run multiple Springdrift instances
  with different configs.
- **Network policy inside container**: keep open by default. Operator
  can set `container_network = "none"` later if they want stricter.
