# Cog-Loop Async-Boundary Audit — Monitors and Deadlines on Every Spawn

**Status**: Deferred — no current evidence of stuck-cycle pathology. Captured here so the analysis isn't lost; ship if and when a real stuck-cycle case emerges.
**Priority**: Medium when triggered, otherwise none.
**Effort**: Medium (~150-250 LOC, mostly in `src/agent/cognitive.gleam` and `src/agent/cognitive/safety.gleam`, plus an audit pass over every `spawn_*` call site).
**Source**: 2026-04-26 deliberation. The truncation incident initially looked like a stuck cycle, which prompted a polling-based liveness watchdog proposal — that was the wrong pattern. The right pattern is consistent monitor + deadline coverage at every async boundary, matching the existing `GateTimeout` design.

## Why This Doc Exists

When the operator reports "the agent is stuck," there are at least four distinct failure modes underneath:

1. **Cycle finished with bad outcome.** Status is `Idle`. The reply was truncated, vague, or unhelpful, but the cog loop itself is healthy and waiting for input. Today's incident was this. Fixed by [cog-loop-truncation-guard.md](cog-loop-truncation-guard.md).
2. **WebSocket disconnect.** Cog loop is `Idle`, operator's input never reaches it. UI looks frozen because messages aren't flowing back. Existing reconnect logic should handle, but worth auditing separately.
3. **Genuinely stuck cycle.** Cog loop's status claims `Thinking` or `WaitingForAgents` but no work is actually happening — worker crashed silently, agent process died without notifying, dispatch path silently dropped a tool_use, etc. **This is the case this doc plans for.**
4. **Cycle running legitimately for a long time.** Deep research, multi-agent debate, document study — minutes to hours. Not a bug; the operator just needs to know it's still working. Fixed by a heartbeat pattern (separate doc).

Mode 3 is the only one this plan addresses. As of this writing we have **no observed instance** of mode 3 in production — the read_skill orphan and the truncation cascade both ended `Idle`. So this work is on the shelf until evidence shows up.

## What Was Originally (Wrongly) Proposed

A periodic self-tick (`LivenessCheck` every 60s) that called `process.is_alive(worker_pid)` and compared the result to `state.status`. If status claimed `Thinking` but the worker process was dead, fire `CycleStalled` and emit a forced reply.

This is **not idiomatic OTP**. Polling for process liveness from a watchdog is a workaround for missing supervision, monitoring, or deadline primitives. If you find yourself reaching for `is_alive` from a timer tick, the right fix is upstream — make sure the state machine that *claims* the process is running has actually wired the message-driven signals that would tell it otherwise.

## What OTP Actually Provides

Three idiomatic ways to know about a process you depend on:

| Mechanism | Use when | Failure signal |
|---|---|---|
| `process.link` | "I cannot continue without this dependency." | Linked exit propagates; supervisor restarts you. |
| `process.monitor` | "I want notification if this dies, but I survive without it." | `DOWN` message in your mailbox. |
| `process.send_after(ms, msg)` | "I'm waiting for an answer that should arrive within X ms." | `msg` lands in your mailbox at the deadline. |

The `GateTimeout` pattern in `dprime/gate.gleam` is the model. Per CLAUDE.md:

> "Gate timeout (BF-12) — all gate evaluations have a configurable timeout (`gate_timeout_ms`, default 60000). If the scorer LLM hangs, a `GateTimeout` message fires via `send_after`. The output gate timeout delivers the report (fail-open) using `pending_output_reply` stored on `CognitiveState`. Late gate completions are ignored (status has already moved to Idle)."

Every async boundary in the cog loop should have this shape:

1. On entering a `Thinking` or `WaitingFor*` status, set up a deadline via `send_after` for the longest the loop will wait.
2. On the same transition, monitor the process(es) the status implies are working.
3. Either receive the expected reply (happy path), receive the deadline message (timeout), or receive a `DOWN` (process died) — whichever comes first wins.

If all three branches are wired, "stuck" becomes structurally impossible — the state machine cannot get into a state where it's claiming work-in-progress with no message ever destined to arrive.

## The Audit

Every site where the cog loop spawns or awaits something async needs to be checked for:

- Does it set a `process.monitor` on the spawned/awaited process?
- Does it set a `process.send_after` deadline appropriate to the work?
- Does the cog loop have a handler for the `DOWN` and the deadline messages, that finalises the cycle deterministically?

Known sites (non-exhaustive — the audit is part of the work):

| Site | File | Currently has monitor? | Currently has deadline? |
|---|---|---|---|
| `worker.spawn_think` | `src/agent/worker.gleam` | Yes (forwards crash to cog loop) | Per-call retry timeout exists; cycle-level deadline TBD |
| Agent delegations | `src/agent/cognitive/agents.gleam:dispatch_agent_calls` | Partial (registry tracks subjects) | TBD — check |
| Team orchestrator spawn | `src/agent/team.gleam` | TBD | TBD |
| Deputy framework | `src/deputy/framework.gleam` | TBD | TBD (deputy_timeout_ms exists for the briefing call) |
| D' input gate canary | `src/agent/cognitive/safety.gleam` | TBD | Yes (`gate_timeout_ms`) |
| D' tool gate | `src/agent/cognitive/safety.gleam` | TBD | Yes (`gate_timeout_ms`) |
| D' output gate | `src/agent/cognitive/safety.gleam` | TBD | Yes (`gate_timeout_ms`) |
| Archivist | `src/narrative/archivist.gleam` | spawn_unlinked (deliberate fire-and-forget) | N/A — runs after cycle ends |
| Sandbox manager | `src/sandbox/manager.gleam` | TBD | Per-execution timeout exists |

Each row that doesn't have both columns checked is a candidate for the same treatment as the gate flow.

## Fix Plan (When Triggered)

### Step 1 — Inventory pass

Read every `process.spawn`, `process.spawn_unlinked`, `process.start`, and any `Subject(...)` field on `CognitiveState` that represents an in-flight async operation. Confirm for each:

- The cog loop has a path to receive notification of failure (monitor, link to a supervisor that notifies, or explicit `Result` on the channel).
- The cog loop has a deadline appropriate to the operation.

Output: a checklist with verdicts: ✅ already correct / ⚠️ has one of the two / ❌ has neither.

### Step 2 — Wire the missing primitives

For each ⚠️ or ❌ row:

- Add a `process.monitor` at the spawn site, captured in the cog state's pending registry alongside the existing task subjects.
- Add a `send_after` for the operation's expected upper bound. New config knobs as needed (`think_timeout_ms`, `agent_delegation_timeout_ms`, etc.) with sensible defaults that don't kill legitimate long cycles.
- Add cog-loop message handlers for `ProcessDown(ref)` and `OperationTimeout(task_id, kind)`.

### Step 3 — Unify the failure-handling shape

Both `ProcessDown` and `OperationTimeout` should land in a single helper that:

- Logs the failure with cycle_id and operation kind.
- Updates the cycle's DAG node with the failure outcome.
- Decides whether to retry (transient + retry budget remaining) or surface a deterministic failure reply (terminal).
- Cleans up any monitors and timers still active for the cycle.
- Transitions to `Idle`.

This mirrors `handle_gate_timeout` but applies to all async boundaries.

### Step 4 — Tests

For each newly-wired site, two tests:

1. **Process death**: kill the spawned process forcibly mid-operation. Assert the cog loop receives `DOWN`, finalises the cycle, ships a deterministic failure reply, and goes `Idle`.
2. **Deadline expiry**: set a tiny deadline (e.g. 100ms), have the spawned process simulate hanging. Assert the cog loop receives the timeout message, kills the process, ships a deterministic failure reply, goes `Idle`.

### Step 5 — Documentation

Add a section to `docs/architecture/cognitive-loop.md` documenting the async-boundary contract: every spawn must wire monitor + deadline, every wait must have a handler for both signals. Operator-facing: list the new config knobs in the config-fields table.

## What Triggers This Work

Ship this **only when** one of the following is observed:

- A cycle's status is `Thinking(task_id)` for >5 minutes with no progress in cycle-log telemetry, AND the worker process for `task_id` is no longer alive (verified post-hoc — not via polling).
- A delegation appears in `active_delegations` for >10 minutes, AND the agent's process subject is unreachable.
- The cog loop's slog shows repeated `GetMessages` polls but no inbound `UserInput`/`ThinkComplete`/`ToolResult` for the active cycle, indicating the cog loop is genuinely waiting on something that will never arrive.

If none of those happen in the next ~3 months of operation, this plan should probably be archived rather than implemented — the existing supervision and gate-timeout coverage is enough.

## What's Out of Scope

- **Truncation guard.** Different problem (bad outcome, not stuck cycle). See [cog-loop-truncation-guard.md](cog-loop-truncation-guard.md).
- **Heartbeat / cycle-progress UX.** Even with this audit done, long legitimate cycles still look frozen to the operator. Heartbeat is orthogonal — separate planning doc when prioritised.
- **Sub-agent-internal liveness.** This plan covers the cog loop's view of its dependencies. The agent framework's own react loop has its own dependencies (LLM worker, tool executors); audit of that is parallel work.

## Triggers to Revisit Sooner

- A new spawn site is added to the cog loop (new subsystem, new helper). Always wire monitor + deadline on day one rather than retrofitting.
- A bug is filed where the operator reports "agent is stuck" and post-mortem shows the cog loop's status was `Thinking` or `WaitingForAgents` rather than `Idle`. That's the canary case this plan handles; ship immediately.
