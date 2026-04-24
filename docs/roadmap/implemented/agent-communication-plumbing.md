# Agent Communication Plumbing — Typed Delegations, Truncation Signals, Commitment Loop

**Status**: Shipped 2026-04-24 across PRs #121-#130. See *What actually
shipped* below — two phases landed differently than specced, one was
dropped with rationale.
**Priority**: High — catches a class of silent-drop bug that looks to
operators like the agent lying or forgetting.
**Original effort estimate**: 50 / 100 / 400 LOC across phases.
**Actual landing**: 10 PRs, all small-to-medium. Build stayed green at
1861 tests throughout.

## Problem

A fresh-instance test session on 2026-04-23
(`/tmp/springdrift-fresh-20260423-182315`) surfaced a cluster of
bugs that look unrelated but share a single root cause: **the channel
between the orchestrator and specialist agents is unstructured prose.**

Three failure modes observed in that session:

1. **"Lying" (structural truncation)**. The operator asked Nemo to save
   a report and investigate a writer failure "in parallel." Nemo's
   response hit the global 2048 output cap mid-construction — the
   promise text made it out, the `tool_use` block that would have done
   the work did not. Next cycle, Nemo looked at its own message and a
   tool result it didn't recognise and rationalised the state forward.
   The framework had no way to flag "this response was length-capped,
   not naturally stopped."
2. **Cross-delegation context loss**. Writer was delegated to "finish
   the report" without receiving the artifact ID of the half-built
   draft. Writer asked its deputy for the prior work; deputy had no
   record (because the draft was never stored); writer spun calling
   `ask_deputy` three times before giving up. Nothing in the dispatch
   pipeline required the orchestrator to name the artifact it was
   continuing from.
3. **Commitments logged, never surfaced**. The post-cycle commitment
   scanner correctly captured five items — two operator asks and three
   agent self-promises made during Nemo's self-reckoning. All five sat
   `pending` in JSONL. The agent never saw them again: the sensorium
   has no `<commitments>` block, there's no `Satisfied` op to close
   them when the underlying work is done, and there's no hook that
   re-injects self-promises as a consistency check on the next cycle.

The fresh-instance context made this worse — deputies on zero memory
correctly decline, and specialists don't recognise `signal=silent`
briefings as "stop asking" — but the shape of each bug is a leak in a
prose-only channel. Raising `max_tokens` fixes (1) operationally; the
structural fix is to make the channel typed.

## What actually shipped

All ten phase units landed; two deviated from the original spec, and
one was explicitly dropped. Recording the divergence here because "the
spec" and "the shipped code" are both true histories and future readers
will want both.

| Phase | PR | Landed as specced? | Notes |
|---|---|---|---|
| 0 — Truncation detection | #121 | Yes | `AgentSuccess.truncated: Bool`; warning prefixed for orchestrator; slog warning when cognitive loop's own response is length-capped. |
| 1 — Deputy silent-signal | #122 | Yes | Silent briefings retire the deputy; specialist never gets `ask_deputy` in its tool list. |
| 3a — Sensorium `<commitments>` | #123 | Yes | Top 3 self + 2 operator captures, age-sorted, rendered each cycle. |
| 3b — `Satisfy` op + tool | #124 | Manual path only | Auto-satisfy heuristic dropped. See *Dropped* below. |
| 6a — Stale-input drop | #125 | Yes | `QueuedInput.enqueued_at_ms`, 60s threshold, sensory event on drop. |
| 3c — Self-commitment reminder | #126 | Yes | Keyword overlap ≥ 2 significant words with current user input triggers the reminder block. |
| 2 — Specialist self-check | #127 | **Diverged** | Original spec proposed a typed delegation envelope + pre-flight validator on the orchestrator with intent enums or keyword-matched required refs. Operator pushed back — enums were brittle taxonomy, keyword matching even worse. Shipped design instead: the classification stays with the specialist (which knows its job), `delegate_to_<agent>` tools gained optional ref fields, each specialist's prompt instructs it to emit `[NEEDS_INPUT: ...]` when refs are missing, cognitive loop reformats NEEDS_INPUT for the orchestrator. Smaller than the original spec, pushes judgement to the right place. |
| 4 — Handoff summary | #128 | Yes | "Before you return" paragraph added to every specialist prompt; they emit `Interpreted as: <one sentence>` at reply-end. |
| 5 — `read_hierarchy` tool | #129 | Yes | Available to all specialists via `builtin.agent_tools()`; cognitive loop mediates access to the Librarian. |
| 6b — WS writer refactor | #130 | **Scoped down** | Original spec claimed a socket-level race and proposed a single writer actor per connection. Tracing the code showed the race doesn't exist — the WS handler is a single BEAM process and writes are serialised. The real ordering concern is upstream (notification and delivery paths have different hop counts through the actor system) but that needs a bigger refactor. Shipped instead: monotonic `seq` field on every outbound ServerMessage + client-side console.warn on seq decrease. Observability, not a fix. If console never warns in production, the "hello? appears out of order" symptom was user-echo-before-reply behaviour, not server reordering. |

### Dropped

**Phase 3b auto-satisfy heuristic** — the original spec proposed a
post-cycle fuzzy-match pass that would auto-close pending captures
whose text overlapped with activated tasks or successful tool calls on
the same cycle. Dropped before starting: the manual `satisfy_capture`
tool from Phase 3b is sufficient for the agent to close its own
commitments; auto-match risks false positives silently closing real
commitments, and the agent already sees pending captures every cycle
via the sensorium block from Phase 3a.

### Design corrections captured from the build

Two of my earlier architectural claims were wrong and the operator
caught both:

1. The Phase 2 "intent enum + required-refs table" approach was
   brittle taxonomy dressed up as type safety. Real fix: push the
   classification to the specialist, where the LLM has full context.
2. The Phase 6b "single writer actor" was solving a race that didn't
   exist. Real concern sits upstream; Phase 6b shipped as observability
   so we can tell whether it's actually user-visible.

Both caught before merge. Noting here so future me reads *this* before
trusting a similar-shaped proposal.

## Non-goals

- **Replacing natural-language instructions.** Instructions stay prose.
  Only the *scaffolding around* the instruction becomes typed — refs
  in, completion signals out.
- **RPC-over-actors or protobuf-style contracts.** Gleam type system
  and custom types are the implementation mechanism; no new wire
  format, no codegen.
- **A workflow engine.** Not building saga orchestration, checkpointed
  long jobs, or retry DAGs. That's a different problem.
- **A UI for commitment tracking.** Sensorium surfaces them to the
  agent. Operator can read the JSONL. No dashboard.

## Proposed solution

Six independent changes, each of which stands alone. Phases 0 and 1
are cheap, pay off immediately, and don't require the envelope
redesign. Phase 2 is the unifying wire change. Phase 3 closes the
commitment loop. Phases 4 and 5 harden the layer above the wire —
semantic alignment between orchestrator and specialist, and shared
visibility across a delegation hierarchy.

### Phase 0 — Length-capped-stop detection (~50 LOC)

The adapter layer already receives `stop_reason` from the provider.
Anthropic returns `"end_turn" | "max_tokens" | "stop_sequence" | "tool_use"`.
Currently the framework treats all of them as "response arrived" and
moves on.

Add a `truncated: Bool` to `LlmResponse` populated from `stop_reason`.
Thread it into `AgentSuccess` as a `warnings: List(AgentWarning)`
field with a `TruncatedByMaxTokens` variant. The cognitive loop
prepends a `[warning: agent reply was length-capped at N tokens]`
block to the specialist's result text when present, the same shape as
the existing `tool_errors` warning.

Also apply to the cognitive loop itself: when the loop's own LLM
reply is length-capped AND the reply contained no `tool_use` blocks,
log a `cognitive/truncated_no_toolcall` warning. This is the "lying"
case made visible in operator logs.

**Touches**: `src/llm/types.gleam` (LlmResponse), `src/llm/adapters/*.gleam`
(populate stop_reason), `src/agent/framework.gleam` (propagate to
AgentSuccess), `src/agent/cognitive.gleam` (render warning, detect
own-response truncation).

### Phase 1 — Deputy silent-signal protocol (~30 LOC)

When a deputy is briefed with `signal=silent` (zero cases, zero
facts), the specialist should not call `ask_deputy` for that hierarchy
at all — the deputy has nothing to say and will decline. Currently
specialists call, get declined, call again, get declined, call a third
time, give up.

Two options, in order of preference:

- **Option A (preferred)**: at deputy spawn, if the briefing comes
  back `signal=silent`, skip installing the `ask_deputy` tool on the
  specialist entirely for that hierarchy. Specialist never sees the
  tool, never calls it.
- **Option B**: keep the tool, but the executor returns a terminal
  `NoDeputyAvailable` result on the first call. Specialist learns
  quickly from one failure instead of three.

Either way, emit a `deputy_unavailable` sensory event once per
hierarchy instead of three `deputy_unanswered` events.

**Touches**: `src/deputy/framework.gleam`, `src/deputy/tool.gleam`,
`src/agent/framework.gleam` (conditional tool injection if Option A).

### Phase 2 — Typed delegation envelope (~400 LOC)

The unifying change. Replace the free-text delegation channel with a
structured envelope in both directions.

#### Request side

```
DelegationRequest {
  instruction: String,
  refs: DelegationRefs {
    artifacts: List(ArtifactId),
    tasks: List(TaskId),
    prior_cycles: List(CycleId),
    prior_results: List(AgentResultId),
  },
  expected_output: OutputContract,
  hard_limits: Limits { max_tokens, max_turns, deadline_ms },
}

OutputContract = MarkdownReport | CodeDiff | StructuredPlan
               | ResearchSummary | FreeForm
```

Each `AgentSpec` declares `required_refs: List(RefRequirement)` where
a `RefRequirement` names a kind (artifact | task | cycle | result) and
a condition (`Always`, `WhenInstructionMatches(regex)`,
`Optional`). Concrete starting set:

| Agent | Required refs |
|---|---|
| writer | `artifacts` when instruction contains "continue", "finish",
"complete", "update" |
| coder | `artifacts` when referring to prior code output |
| project_manager | `tasks` on `complete_task_step`-bearing instructions |
| researcher | none required |
| observer | `cycles` when instruction contains "review", "diagnose" |

Pre-flight validator in the cognitive loop checks required refs before
dispatch. On violation, the validator returns a synthetic
`DelegationResult::NeedsInput` to the orchestrating LLM's next turn
instead of dispatching. The orchestrating LLM sees: *"Writer requires
an artifact_id when the instruction says 'finish'. Provide one, or
rephrase."* This surfaces the missing context at the point of dispatch,
not three turns later through a declined deputy.

#### Response side

```
DelegationResult {
  status: Ok | NeedsInput | Truncated | Failed,
  output: AgentFindings,      // typed per-agent, as today
  missing: List(MissingInput),// when NeedsInput
  truncation_reason: Option(String),
  caveats: List(String),
  tool_errors: List(ToolError),
}
```

`NeedsInput` is the specialist's structured "I can't proceed for lack
of X" signal. Replaces today's "write a prose refusal and hope the
orchestrator notices." `Truncated` surfaces Phase 0's signal at the
delegation boundary. `Failed` carries a structured error with an
`ErrorClass` (Retryable | MissingInput | Unrecoverable) so the
orchestrating LLM knows whether retry is sensible.

#### Delegation tool generation

Today `cognitive.gleam` builds `delegate_to_<agent>` tools from
`AgentSpec`. Extend the builder to declare each required ref as a
tool parameter. A writer continuation becomes:

```json
{
  "name": "delegate_to_writer",
  "input_schema": {
    "properties": {
      "instruction": {"type": "string"},
      "artifacts": {"type": "array", "items": {"type": "string"},
                    "description": "Required when continuing prior work"},
      ...
    },
    "required": ["instruction"]
  }
}
```

The schema itself carries the hint. The pre-flight validator enforces.

**Touches**: `src/agent/types.gleam` (envelope types), `src/agent/framework.gleam`
(consume envelope, return envelope), `src/agent/cognitive.gleam`
(delegation tool builder + pre-flight validator), each
`src/agents/*.gleam` (declare `required_refs`), `src/tools/*.gleam`
(specialist-side tool executors that surface `NeedsInput`).

### Phase 3 — Commitment tracker feedback loop (~150 LOC)

The scanner works. The loop doesn't close. Three pieces:

#### 3a. Sensorium `<commitments>` block

Add a `<commitments pending="N">` section to the Curator's sensorium
XML, rendering the top 3 oldest `agent_self` captures plus the top 2
`operator_ask` captures by age. Omitted when the set is empty.

```xml
<commitments pending="5">
  <self age="4h">Check results before reporting success on tool calls</self>
  <self age="4h">Acknowledge delegation failures immediately</self>
  <operator age="5h">Save the agentic AI marketplace report</operator>
</commitments>
```

The agent sees this every cycle. No tool call required.

**Touches**: `src/narrative/curator.gleam` (sensorium assembly),
`src/captures/log.gleam` (query by age/source).

#### 3b. Satisfied op + auto-satisfy heuristic

Add a `Satisfied(cap_id, evidence: SatisfyEvidence)` variant to
`CaptureOp`. `SatisfyEvidence` is `ManualByAgent(reason) |
AutoTaskCompleted(task_id) | AutoToolSucceeded(tool_name, tool_use_id)`.

Heuristic runs in the same post-cycle pass as the scanner: for each
`pending` capture whose text semantically matches an activated task's
title or a successful tool call on this cycle, emit `Satisfied` with
`Auto*` evidence. Cheap fuzzy-match (shared significant-word overlap
≥ 60%) suffices; false positives are auditable in JSONL.

Also add a `satisfy_capture(cap_id, reason)` tool for the agent to
close commitments explicitly.

**Touches**: `src/captures/types.gleam`, `src/captures/log.gleam`,
`src/captures/scanner.gleam` (post-scan auto-satisfy pass),
`src/tools/captures.gleam` (new tool).

#### 3c. Self-promise consistency check

When rendering the sensorium, if any `agent_self` capture's text
contains intent phrasing that overlaps with the cycle's *current* user
input or draft response (detected by keyword overlap), surface it in a
`<self_commitment_reminder>` block instead of the generic
`<commitments>` list:

```xml
<self_commitment_reminder age="4h">
  You previously committed: "Check results before reporting success on
  tool calls." Apply this to the current response.
</self_commitment_reminder>
```

This is the only place the commitment system actively intervenes. It's
narrow-scope by design — only fires on keyword overlap with the
current cycle.

**Touches**: `src/narrative/curator.gleam` (consistency check + block
render).

### Phase 4 — Cross-agent semantic contract (~150 LOC)

Typed envelopes stop drops at the wire but don't prevent disagreement
about what the instruction meant. "Finish the report" can mean
*continue drafting the missing sections*, *write the final
conclusion*, or *polish the existing draft*. Writer and orchestrator
can both be certain — and certain of different things.

Two complementary changes, both cheap, neither perfect.

#### 4a. Per-agent intent enum

Each `AgentSpec` declares an `intents: List(Intent)` — the bounded
set of things it is designed to do. Writer: `Draft | Continue |
Revise | Polish | Extract | Summarise`. Coder: `Implement | Fix |
Refactor | Review | Port`. Researcher: `Search | Synthesise |
Verify | Compare`.

The generated `delegate_to_<agent>` tool gains an `intent` enum
parameter, required. The orchestrator LLM has to pick one — "finish
the report" no longer dispatches ambiguously; it dispatches as
`intent=Continue` with an artifact ref, or `intent=Polish` with no
new content expected, etc.

The specialist receives the intent as a first-class field in its
prompt template: *"You have been asked to Continue the work stored in
artifact art-123."* — the specialist's interpretation is now
constrained by the enum, not just the prose instruction.

This is the same move the D' gate made for tool calls: the LLM still
writes natural language, but a structured classification step
precedes dispatch and is auditable.

#### 4b. Handoff summary on return

Every `DelegationResult` includes a mandatory one-sentence
`interpreted_as: String` field: *"I interpreted the request as
continuing the draft in art-123 by adding sections 6 through 10."*

The orchestrator sees this alongside the output and can detect drift
one turn later: if the interpretation doesn't match the original
intent, the orchestrator can redispatch or flag to the operator. Not
prevention, but early detection — the current design has *no* way to
catch interpretive drift at all.

Combined, (4a) narrows the space before dispatch and (4b) surfaces
mismatches after. Neither solves the problem completely. Full
solution would need reasoning-level alignment, which is a research
problem; this is the engineering approximation.

**Touches**: `src/agent/types.gleam` (Intent enum per agent spec,
`interpreted_as` field), `src/agent/cognitive.gleam` (delegation tool
builder + drift detection on return), `src/agents/*.gleam` (declare
intents), `src/agent/framework.gleam` (inject intent into specialist
prompt, require interpreted_as in return).

### Phase 5 — Hierarchy visibility / inter-agent read channel (~100 LOC)

Specialist agents today can't see what the orchestrator told other
specialists in the same hierarchy. A writer doesn't know the
researcher was just called and returned an artifact; a coder doesn't
see the project_manager's task decomposition. Each specialist gets
a lonely instruction string and makes it up from there.

The DAG already records this. `cycle_tree.gleam` builds a
hierarchical `CycleNode` tree from `parent_cycle_id` links, and the
Librarian already supports `QueryNodeWithDescendants`. The data is
there; no tool exposes it to agents.

#### 5a. `read_hierarchy` tool

New builtin tool available to all specialists (and optionally the
cognitive loop). Signature:

```
read_hierarchy(cycle_id: String, scope: "ancestors" | "siblings" | "full")
```

Returns a compact rendering of the delegation tree: each node's
agent, instruction summary, result summary (first 200 chars), and
outcome (ok / failed / truncated). Uses the existing Librarian
query; no new persistence.

Default scope is `"siblings"` — everything the orchestrator dispatched
in the current hierarchy, so the specialist sees its peers' inputs
and outputs. `"ancestors"` walks up to the root. `"full"` returns
the entire tree; gated behind a size limit to prevent context blowup.

Use case: writer asked to "integrate the researcher's findings"
can call `read_hierarchy(my_cycle_id, "siblings")` and see the
researcher's actual result, not a paraphrase in the instruction.
Reduces "please repeat what the other agent told you" round-trips.

#### 5b. Shared-channel option (deferred)

A more ambitious version: a per-conversation or per-hierarchy JSONL
log ("agent chatter") that every agent in the hierarchy can append
to and read. Useful for genuinely collaborative tasks where multiple
agents iterate. Risks becoming a noisy second memory system.

Defer until a concrete scenario demands it. (5a) covers the
read-what-happened case, which is what the fresh-instance session
actually needed. Collaborative-iteration scenarios haven't surfaced
yet.

**Touches**: `src/tools/builtin.gleam` or new `src/tools/hierarchy.gleam`
(the read tool), `src/narrative/librarian.gleam` (may need a new
query variant for sibling scope), `src/agents/*.gleam` (tool
registration per agent).

### Phase 6 — WebSocket message ordering + stale-queue hygiene (~80 LOC)

Observed in the same test session: a user message ("hello?") rendered
below an agent response it had been typed *before*, and a cycle fired
against a stale queued input at the end of the session (19975 in / 19
out, producing "I'm here. Was my diagnostic report too long?").

Two root causes, both in `src/web/`:

#### 6a. Multiple concurrent writers to one socket

`src/web/gui.gleam` has a notification relay (`forward_loop`) that
translates `Notification` events into `ServerMessage`s on the
WebSocket, alongside the direct chat-reply path that writes to the
same socket. No serialising actor in front of the socket means two
sends can race: a `ToolNotification` and a chat reply can reach the
client in an order different from the order they were produced.

Fix: all WebSocket writes go through a single per-connection writer
actor. Messages enqueue into a `Subject(ServerMessage)` and the writer
actor drains them in receive order. Adds one process per connection;
trivial at our scale.

Also add a monotonic `seq: Int` field to `ServerMessage` so the client
can detect gaps (if the writer actor does crash-restart) and either
request replay or show a diagnostic banner.

#### 6b. Stale pending-input handling

When a user types during a long cycle, the input is queued. Today the
cognitive loop drains that queue unconditionally once the current
cycle ends — even if the queued input is now several cycles old or the
operator has sent a newer input that implicitly supersedes it.

The "I'm here. Was my diagnostic report too long?" cycle is what this
looks like operationally: an old queued input gets fired against
stale context and produces a near-empty reply because the agent has
nothing useful to say.

Fix: mark each queued input with `enqueued_at_ms`. When draining,
if the input is older than a configurable threshold (default 60s) AND
subsequent inputs exist in the queue, skip the stale one and log
`cognitive/stale_input_dropped`. Single-queued old inputs still fire
(the operator may have stepped away and come back).

Surface dropped inputs as a sensory event so the agent can mention it
if relevant: *"an earlier message from you was skipped because it had
been queued for N minutes behind other work."*

**Touches**: `src/web/gui.gleam` (writer actor, seq field),
`src/web/protocol.gleam` (ServerMessage gains seq), `src/web/html.gleam`
(client-side gap detection — minimal, just render a banner on gap),
`src/agent/types.gleam` (QueuedInput gains enqueued_at_ms),
`src/agent/cognitive.gleam` (stale-drop logic on queue drain).

## Phasing

Ship in order; each phase is independently useful.

### Phase 0 — Length-capped-stop detection

- LOC: ~50
- Dependencies: none
- Acceptance: a delegation that hits `max_tokens` returns a warning
  surfaced to the orchestrator; the cognitive loop's own truncated-
  no-tool-call responses are logged as warnings.
- Scenario: extend `test/scenarios/` with a `writer-truncation.toml`
  that sets `[agents.writer] max_tokens = 256` and asserts the reply
  carries a truncation warning.

### Phase 1 — Deputy silent-signal protocol

- LOC: ~30
- Dependencies: none
- Acceptance: on a fresh instance (zero memory), a writer delegation
  emits at most one `deputy_unavailable` event, not three
  `deputy_unanswered` events.

### Phase 2 — Typed delegation envelope

- LOC: ~400
- Dependencies: Phase 0 (envelope's `Truncated` variant relies on it).
- Acceptance: writer delegation with instruction containing "finish"
  but no `artifacts` ref is rejected pre-flight with `NeedsInput`; the
  orchestrator's next turn sees a structured prompt naming the missing
  ref.
- Scenario: `test/scenarios/writer-continuation-missing-artifact.toml`.

### Phase 3 — Commitment tracker feedback loop

- LOC: ~150
- Dependencies: none (independent of envelope work).
- Acceptance: sensorium renders `<commitments>` when any pending
  exist; activating a task whose title matches a capture auto-satisfies
  it; self-promises surface as reminders when relevant to current cycle.
- Can ship 3a alone (sensorium block); 3b and 3c build on it.

### Phase 4 — Cross-agent semantic contract

- LOC: ~150
- Dependencies: Phase 2 (intent lives inside the envelope; handoff
  summary extends `DelegationResult`).
- Acceptance: each agent's delegation tool requires an `intent` enum
  value; `DelegationResult.interpreted_as` is non-empty; orchestrator
  can detect and log intent-vs-interpretation mismatches.

### Phase 5 — Hierarchy visibility

- LOC: ~100
- Dependencies: none (reads existing DAG via Librarian).
- Acceptance: any specialist can call `read_hierarchy` and receive a
  compact rendering of peer delegations in the same hierarchy.
- Scenario: `test/scenarios/writer-reads-researcher-output.toml` —
  orchestrator dispatches researcher then writer; writer's first turn
  includes a `read_hierarchy` call returning the researcher's output.

### Phase 6 — WebSocket hygiene

- LOC: ~80
- Dependencies: none.
- Acceptance: ServerMessages arrive at the client in produced order,
  confirmed by monotonic seq numbers; a queued user input older than
  60s with newer inputs behind it is dropped and a `stale_input_dropped`
  sensory event fires.

## Open questions

1. **`required_refs` declaration — by agent or by instruction pattern?**
   Drafting above uses both (agent declares, with optional condition).
   The condition regex is fragile — might instead make the orchestrator
   LLM classify intent ("is this a continuation?") before dispatch.
   Adds a Haiku call per delegation; probably worth it.
2. **Semantic matching for auto-satisfy.** 60% word-overlap is crude.
   Embedding similarity via the existing CBR embedder would be better
   but adds dependency on Ollama running. Keep crude for MVP; revisit
   when false positive rate is measurable.
3. **Retroactive migration.** Today's `pending` captures all stay
   pending forever. Auto-satisfy would run forward only. Existing
   pending entries age out at 14 days. Acceptable.
4. **Global `max_tokens` vs agent specs.** Not part of this spec but
   the 2048 cap in the test config appears to bleed into agent specs
   somewhere my code-read didn't catch. Needs a separate trace and
   a separate PR; not blocking this work.
5. **Intent enum granularity.** Draft uses 5–6 intents per agent.
   Too few loses expressive power; too many reintroduces the
   ambiguity the enum was meant to kill. Review after Phase 4 ships
   — expect to converge on a smaller set than the first draft.
6. **Hierarchy read and context budget.** `read_hierarchy(full)` on a
   deep delegation tree could blow a specialist's context. Need a
   sensible default size cap and a "summarise siblings" compression
   pass if the raw tree is too large.
7. **Stale-input threshold.** 60s is a guess. Should probably be
   `max(60s, cycle_duration * 2)` so fast-cycle instances don't drop
   prematurely. Revisit once telemetry exists.

## Related

- PR #118 — Scenario runner MVP (where new scenarios from this work land)
- `docs/roadmap/planned/integration-testing.md` — Phase 2 scenarios
  include the regressions this spec catches
- `docs/architecture/agents.md` — agent substrate, will need updating
  when Phase 2 lands
- `src/captures/` — existing commitment tracker (Phase 3 touches)
- `src/deputy/` — existing deputy system (Phase 1 touches)

## What this is not

- A rewrite of the agent substrate. Specialist agents keep their
  current shape; delegation framing changes around them.
- A replacement for skills or prompt engineering. Typed envelopes stop
  drops at the wire boundary; they don't improve reasoning quality.
- A commitment-tracking product feature. The loop-close work is
  scoped to what the agent itself needs to see; no operator UI.
