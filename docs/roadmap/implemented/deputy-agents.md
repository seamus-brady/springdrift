# Deputy Agents — Delegated Attention per Hierarchy

**Status**: Shipped 2026-04-23 (PR #103) — full 4-phase MVP
**Priority**: Architectural — addresses a real bottleneck (specialist agents lack access to cog's smarts)
**Effort**: Medium (~1400 LOC across 4 phases; MVP at Phase 1, ~400 LOC)

## Problem

The cognitive loop carries all the agent's intelligence: CBR retrieval, fact recall, sensorium synthesis, delegation strategy, pattern recognition, skill consultation, affect integration. Specialist agents (coder, researcher, writer, comms, observer, remembrancer) receive a plain instruction string, a scoped tool set, and nothing else. They reason with dramatically less context than the cog loop had.

The metaphor, coined in conversation: **a tribe of Einsteins who use Mr Bean as a valet.** The orchestration layer is rich; the execution layer is impoverished.

Two specific symptoms:

1. **Specialists can't learn from their own past.** The cog loop retrieves relevant CBR cases and puts them in the cog's own context. When it delegates to a specialist, those cases don't travel. The coder has no access to "how did I solve a similar problem three weeks ago."
2. **Specialists can't detect routine cases.** Every delegation spins up a full react loop with fresh reasoning, even when the task is a near-duplicate of something the cog has handled dozens of times. No "muscle memory."

## Architectural framing — delegated attention

Rather than inventing a separate reactive-layer mechanism, reuse the existing primitive: spawn an ephemeral, restricted cog loop alongside each subagent delegation. Same code, same react pattern, same framework — but read-only, bounded in scope, and scoped to serve one delegation hierarchy.

Conceptually this is **delegated attention**: cog's conscious attention is the scarce resource, and the deputy holds attention on one work tree on cog's behalf. Maps directly onto Global Workspace Theory (conscious attention as the broadcast bottleneck) and ACT-R (serial decision, parallel modules).

Operator-facing name: **deputy**. The deputy has delegated authority — principal (cog) is still present, the deputy works in parallel rather than in cog's absence.

## Cognitive-science precedents

Not a new architectural idea. The deputy pattern maps cleanly onto established cognitive architecture:

| Theory | Map |
|---|---|
| **Global Workspace Theory** (Baars, Dehaene) | Cog loop = global workspace (serial, conscious); deputies = parallel non-conscious modules competing for broadcast upward. Only novel/salient content wins attention. |
| **Soar — impasse/substate** | When Soar hits a knowledge gap, it auto-spawns a substate to resolve it; the substate dies after. Deputies are structurally identical — spawn on need, resolve or escalate, die. Soar's chunking pathway (substate-resolved → new production) corresponds to CBR case creation in Springdrift. |
| **ACT-R — parallel modules, serial decision** | ACT-R's modules run in parallel; the production system serialises. Deputies are the parallel modules. |
| **CLARION — two-level architecture** | Explicit two-level: implicit (bottom) handles routine, explicit (top) handles deliberation, escalation only when bottom can't resolve. Same shape. |
| **H-CogAff — reactive/deliberative/meta** | Springdrift already has the meta layer (meta observer). Deputies are the reactive layer. Cog is deliberative. Architecture becomes complete. |

Soar's impasse/substate is the closest practical precedent. Worth reading Laird's work during implementation.

## Architecture

### One deputy per delegation hierarchy

A deputy is scoped to a **hierarchy**, not a single agent. When cog delegates work to agent A, a deputy spawns. If A then delegates to B, B inherits the same deputy — no new spawn. The deputy sees the whole tree of work rooted at cog's initial delegation.

```
cog delegates to writer     → deputy-1 spawns, watches writer
writer delegates to researcher    → researcher inherits deputy-1
researcher delegates to fetcher   → fetcher inherits deputy-1
writer completes            → deputy-1 dies
```

Rationale:

- **The work is one coherent piece.** Multiple deputies would each see a fragment; one deputy develops a coherent model of the work.
- **Human subconscious doesn't fork on sub-activity switch.** You're working on a proposal, you pause to check a reference, you resume. Same subconscious throughout.
- **Escalation carries richer context for free.** If the fetcher hits `wtf` inside the writer's hierarchy, the deputy escalating to cog already knows "this was the writer's goal, the researcher's approach, the fetcher's specific failure."
- **Cost.** Cuts deputy spawns proportionally to delegation depth.

**Parallel root delegations → parallel deputies.** If cog fires `agent_writer` and `agent_coder` in parallel (existing parallel-dispatch), each is an independent hierarchy with its own deputy. They are not the same work.

**Teams.** A team orchestrator spawns the team as a unit; team members share the team's deputy. Still one-per-hierarchy.

**Lifetime.** Deputy spawns when the root delegation spawns and dies when the root delegation completes, crashes, or is cancelled. Not persistent across delegations. Not tied to cycles — tied to the hierarchy's work.

### Restriction mechanism

"Read-only" is enforced structurally, not behaviourally. Deputies get a dedicated tool subset — the read-only reachable closure of the framework's tool registry:

- `recall_recent`, `recall_search`, `recall_threads`, `recall_cases` — narrative + CBR reads
- `memory_read`, `memory_query_facts`, `memory_trace_fact` — fact reads
- `introspect`, `reflect` — system state reads
- `list_captures` (if/when it exists) — GTD reads
- `read_skill` — skill reference

No mutating tools are registered on deputies. No write path reaches them. No D' gate needs to handle a deputy's writes because there are no writes.

Additionally: deputies cannot delegate (no `agent_*` tools, no `team_*` tools). They cannot request human input. They cannot emit output to the frontdoor. A deputy reasons privately and communicates only through its return value (briefing), through answers to `ask_deputy` calls, and through sensory events / wakeups to the main cog loop.

### Deputy's own prompt and skills

A deputy is a cog loop variant — which means it needs its own system prompt and skill scope, just like any reasoning process in Springdrift.

**System prompt.** A dedicated deputy system prompt covers what a deputy is, its read-only constraint and what that means behaviourally, the hierarchy it's watching and its lifetime, when to emit sensory events vs request a wakeup, how to structure a briefing, and how to answer `ask_deputy` calls. Loaded per deputy spawn; templated with the hierarchy's root agent name and the delegation instruction.

**Deputy skills.** A new skill scope: `deputy`. Skills in this scope are about *being* a deputy, not about being a specialist. Initial skills worth shipping with Phase 1:

- `deputy-briefing-format` — how to structure the `<briefing>` XML: which fields, level of detail, when to include `known_pitfalls`
- `deputy-escalation-criteria` — when each tag applies, what counts as urgent enough for Tier 2
- `deputy-ask-response` — how to answer `ask_deputy` concisely: cite, don't speculate; if you don't know, say so (trigger `unanswered`)

Loaded by the deputy framework at spawn — same skill injection machinery that serves specialist agents, just a new scope tag.

### Three modes

MVP builds Mode 1. Later phases add Modes 2 and 3.

#### Mode 1 — Briefing (MVP)

When a hierarchy spawns, the deputy runs one-shot before the root agent's react loop starts:

1. Receives: the delegation instruction, the agent's name, read-only memory access
2. Runs ~1-3 LLM turns pulling relevant CBR cases, recent narrative entries for the domain, applicable facts
3. Returns: a `<briefing>` XML block prepended to the agent's system prompt (and available to sub-agents that inherit the deputy)

```xml
<briefing>
  <relevant_cases>
    <case id="CBR-042" similarity="0.87">Similar coding task — pitfall: test date FFI needed override</case>
    <case id="CBR-019" similarity="0.64">Related — rewrite broken tests, don't patch</case>
  </relevant_cases>
  <relevant_facts>
    <fact key="cycle_log_test_pattern">Tests use override_date_fn; see test/cycle_log_test.gleam</fact>
  </relevant_facts>
  <known_pitfalls>
    Three similar fixes in last two weeks took &gt;5 cycles each. Consider reading the test first.
  </known_pitfalls>
</briefing>
```

The agent now starts with context. Same cog-loop smarts the deputy extracted — without the cog loop having to do it synchronously and pack it into a delegation string.

Cost: one Haiku-class deputy call per root delegation, ~1-3 turns. Trivial for autonomous cycles; gate-able for chatty ones.

#### Mode 2 — Ask-for-help (follow-up phase)

The deputy stays alive for the hierarchy's lifetime. Any agent in the tree gets `ask_deputy(question, context?)`. The framing is help-seeking: the agent reaches out when stuck, unsure, or wants pre-validation.

The deputy answers from:

- Its read-only memory (CBR, narrative, facts)
- Its accumulated context from the briefing phase
- Its own reasoning (up to `deputies_max_turns` turns)

Examples:

- `ask_deputy("has the coder ever dealt with a flaky sandbox port allocation?")` — memory lookup
- `ask_deputy("I'm about to modify the scheduler runner — what should I watch for?")` — pre-validation
- `ask_deputy("this test is failing in a way I don't recognise — any similar cases?")` — diagnostic help

**When the deputy can't answer, the question escalates to cog.** The deputy emits a sensory event tagged `unanswered` with the original question, the agent's context, and what the deputy tried. Cog sees it in the next cycle's sensorium/events and can intervene. The chain:

```
agent stuck → ask_deputy → deputy resolves (agent continues)
agent stuck → ask_deputy → deputy can't help → escalates to cog (tagged unanswered)
```

This is the dual-process pattern — subconscious handles what it can, punts to conscious when it can't. The deputy gracefully degrades rather than inventing an answer.

This is pull-model from the agent. Mode 3 adds push from the deputy.

#### Mode 3 — Escalation (follow-up phase)

The deputy watches the hierarchy's turn-by-turn activity. Escalation triggers are broader than novelty alone.

**Escalation tags:**

| Tag | Meaning | Typical trigger | Tier |
|---|---|---|---|
| `routine` | Known pattern, high CBR similarity | — (no escalation) | none |
| `high_novelty` | Unfamiliar territory, low similarity | CBR confidence below threshold | Tier 1 |
| `anomaly` | Pattern is off (e.g. repeated failures, oscillating behaviour) | Pattern detector fires | Tier 1 |
| `alarm` | Safety-relevant signal in the agent's domain | D' score near threshold, output gate warning, rate limit hit | Tier 2 |
| `error` | Tool call failed or exception the deputy can't explain | Unrecognised tool error, malformed output | Tier 2 |
| `unanswered` | Agent asked via `ask_deputy`, deputy couldn't help | See Mode 2 | Tier 1 |
| `wtf` | Deputy genuinely cannot reason about what's happening | No CBR match, no fact coverage, no skill applicable, agent seems stuck | Tier 2 |
| `silent` | Briefing-only, nothing active | — | none |

Alarms, errors, and WTF are "something is going wrong right now" cases and warrant wakeup (Tier 2). Novelty and unanswered are ambient signals that can wait for the next natural cog cycle (Tier 1).

**Tier 1 — sensory event (non-waking).** Deputy emits `QueuedSensoryEvent` with the escalation payload. Event reaches cog's sensorium on cog's next cycle. Agent keeps working. Cog decides when to look.

**Tier 2 — wakeup (waking).** Deputy enqueues a scheduler job to trigger a cog cycle sooner than one would naturally occur:

```gleam
pub type ScheduledJobKind {
  // existing variants...
  DeputyWakeup(deputy_id: String, source_agent: String, reason: String)
}
```

With `due_at = now`. The scheduler fires the job subject to its existing guards — idle-gate, per-hour cycle budget, token budget, hard deferral ceiling. When it fires, cog receives a `SchedulerInput` with the deputy's message and cycles on it. Input gate runs. Normal cycle semantics.

**Why route through the scheduler.** A direct deputy→cog channel would bypass idle-gating, budget caps, and input-gate protections on autonomous inputs. Scheduler routing keeps all that intact. Deputies get no new privileges — only the ability to request a future cycle, subject to the same rules that govern every other autonomous fire.

**Gating constraints on Tier 2:**

- Signal must be `alarm`, `error`, `wtf`, or high-urgency `anomaly`
- Per-hierarchy wakeup rate limit (default: 2 wakeups/hour, configurable)
- Global budget applies via existing scheduler hourly caps
- Deputy hasn't recently woken cog for this hierarchy (dedup)
- Hard exceptions: `alarm` and `wtf` bypass the per-hierarchy rate limit (safety-relevant signals must reach cog); global budget still applies

**What cog sees when woken.** The triggered cycle has `input_source=scheduler` with `<scheduler_context source="deputy_wakeup" deputy_id="..." agent="..." />`. Cog knows why it woke up.

### What deputies explicitly do NOT do

Load-bearing constraints:

- **No autonomous response** on behalf of the agent. Deputies brief, answer, escalate. They never replace the agent's output.
- **No memory writes.** Structurally prevented by the restricted tool set.
- **No delegation.** No recursion; deputies can't spawn agents or teams.
- **No network side effects.** Email, webhooks, frontdoor output, scheduler mutations (except the DeputyWakeup schedule) — all restricted.
- **No interruption of the agent.** Deputy runs alongside; influences via briefing, ask-for-help answers, sensory events, and wakeups only.

### Lifecycle controls (cog → deputy)

Beyond natural lifetime (spawn-with-hierarchy, die-with-hierarchy), cog has control operations over active deputies.

**Recall** — cog sends `RecallDeputy(deputy_id, reply_to)` asking for a state snapshot without killing the deputy. Reply is a `DeputyStatus`:

- Current mode (briefing / asking / watching)
- Turn count
- Last reasoning summary
- Current signal tag
- Tool calls made
- Escalations emitted

Non-destructive. Use case: cog wants to check what its deputy knows before making a decision.

**Kill** — cog sends `KillDeputy(deputy_id, reason)`. Deputy logs termination, writes final audit trail, exits cleanly. The hierarchy continues *without* a deputy — agents keep working, degraded (no briefings, no ask-for-help, no escalations for the remainder).

Use cases: deputy misbehaving (escalation storm, runaway reasoning); operator intervention; cost-cutting in an emergency; deputy blocking on a slow LLM call.

**Replace — deferred.** Replacing a mid-flight deputy would require state transfer (briefing context, ask-for-help history). Complex, unclear trigger conditions, and kill + respawn achieves the same end state when needed. Revisit if a concrete use case emerges.

Control operations appear in the DAG: recall events log as deputy state snapshots; kill events log as termination records with cog's cycle as source.

## Impact on introspection

Deputies are first-class in the agent's self-awareness.

### `introspect` tool surfaces active deputies

Current `introspect` shows: identity, agent roster, D' config, cycle ID. Extended to include:

```
Active deputies:
  - deputy[writer] for task cyc-xyz, hierarchy depth 2, turn 3, 1 escalation
  - deputy[researcher] for task cyc-abc, hierarchy depth 1, turn 1
```

### Sensorium — deputy activity block

Two channels deliver deputy feedback to the cog loop; each plays a different role.

**Active push — sensory events and wakeups.** When a deputy detects something worth escalating, it emits a sensory event (Tier 1) or a wakeup (Tier 2). Those reach cog through the existing input/events paths.

**Passive pull — sensorium.** The `<deputies>` block gives cog ambient awareness of what deputies are doing now and what they recently reported. No action required; awareness only. This is the "I've been driving on autopilot and I know it" analogue.

```xml
<deputies active="2" escalations_last_cycle="1" briefings_last_cycle="4">
  <deputy agent="writer" turn="3" signal="high_novelty"/>
  <deputy agent="researcher" turn="1" signal="routine"/>
  <recent_escalation agent="coder"
                     summary="Test repeatedly fails after commit"
                     tag="error"
                     delivered_at="2m ago"/>
</deputies>
```

**Rendering rules** to avoid sensorium bloat:

- Omit the entire block when `active == 0 && escalations_last_cycle == 0 && briefings_last_cycle == 0`
- Cap per-deputy rows at 3; overflow collapses to `...and N more`
- `routine` deputies can fold into a count attribute rather than rendering individually when space is tight
- `<recent_escalation>` retained only for the most recent cycle; older escalations are already in narrative and don't need re-surfacing

**Feedback is one-way (deputy → cog).** Cog doesn't drive deputies interactively. If cog wants to course-correct, it abandons the delegation and redoes it — the deputy dies with the hierarchy.

### DAG — deputies are first-class cycles

Deputies are fully wired into the DAG. Every deputy spawn creates a new cycle node; every LLM call, tool read, briefing emission, ask-response, sensory event, and wakeup the deputy produces becomes an event under that cycle ID.

**Integration points:**

- `CycleNodeType` gains a `DeputyCycle` variant alongside existing types (`UserCycle`, `SchedulerCycle`, `AgentCycle`)
- Deputy's cycle has `parent_cycle_id = root_delegation_cycle_id` — parents it to the hierarchy root, not to cog directly
- Sub-delegation cycles in the hierarchy carry a sibling pointer `deputy_cycle_id` to the shared deputy cycle; rendering can show the association without mutating the parent tree
- Cog cycles triggered by a deputy wakeup carry `source = deputy_wakeup` and `triggering_deputy_id` pointing back at the originating deputy cycle — the chain is traversable in both directions
- `inspect_cycle` works natively on deputy cycles — same tool, same semantics; drill-down returns deputy reasoning, tool reads, and emitted events
- `list_recent_cycles` returns deputy cycles with `node_type="deputy"` so operators can filter
- Web GUI DAG renders deputy branches with distinct visual treatment (dimmer tint or dedicated icon) alongside the hierarchy's agent branch
- Control events (recall snapshots, kill terminations) log as events under the deputy cycle with cog's cycle as the source pointer

## Impact on immutability

Immutability is a Springdrift invariant: memory is append-only JSONL, only the cog loop (via Archivist, tools, scheduler writes) adds to it.

**Deputies preserve immutability** by construction, because they cannot write. The restriction mechanism is the guarantee.

Two places where deputies produce state that ends up on disk — both additive, both through existing authorised paths:

1. **Deputy reasoning logged to the cycle log.** Same JSONL as cog reasoning. Additive. The cog loop remains the only process that calls `narrative_log.append`, `facts_log.append`, etc.
2. **Deputy escalations emitted as sensory events or scheduler jobs.** Both flow through existing actor channels to the cog loop, which writes to its own state.

The invariant hardens rather than weakens: multiple reasoners exist, but the writer set does not grow.

## Impact on auditability

Auditability is the hardest invariant to preserve with two reasoning layers. Core requirement: every consequential decision has a traceable origin.

### Decisions remain traceable

- **Agent actions are attributed to the agent.** If the coder commits code, the commit's provenance is the coder's delegation cycle.
- **Deputy reasoning is attributed to the deputy.** If a deputy's briefing influenced the agent, the briefing appears in the agent's cycle log with the deputy's cycle ID as source.
- **Cog-level decisions remain attributed to cog.** Escalations that cause cog to act appear in cog's cycle log with the deputy's escalation event or wakeup as input.

Nothing happens without a named reasoner attached.

### Gates stay on the action path

Normative and D' gates sit on the action path, not the reasoning path. Deputies do read-only reasoning — no gate needed on that. Agent actions (tool calls, delegations, outputs) continue to pass through the existing gates regardless of what deputy context informed them. Deputy-woken cog cycles have their inputs pass through the input gate as any autonomous cycle would.

So auditability survives as long as:

1. Deputy reasoning is logged to the same append-only surface as cog reasoning
2. Actions retain attribution to the agent, with deputy context cited where relevant
3. Gates continue to guard actions, not reasoning

No new invariant required. No relaxation of existing ones.

## How Things Work Around Here Now — cog and subagent awareness

Deputies are a new first-class citizen in the architecture. The rest of the system needs to know about them — otherwise specialist agents don't recognise their briefings as deputy output, and cog has no framework for interpreting the `<deputies>` sensorium block or deputy-tagged sensory events.

Create a shared skill, **`system-map`**, that documents the current architectural surface. Scoped to `all` — every reasoning layer (cog, specialist agents, deputies) reads it.

**Minimum content for Phase 1:**

- Cog loop is the only permanent reasoning process. Everything else is ephemeral.
- Deputies exist. One per delegation hierarchy. Ephemeral. Read-only. Parallel to the agent, not in the agent's path.
- Deputies brief specialist agents before they start. Agents can call `ask_deputy` (Phase 2) if it's in their tool set.
- Deputies escalate novel / WTF / alarm / error situations to cog via sensory events (Tier 1) or wakeups (Tier 2).
- Cog can recall or kill an active deputy via dedicated control tools.
- When in doubt: ask the deputy, or escalate to cog.

**Per-layer extensions** — the system-map skill is structured in sections scoped by reader role, or as separate skills that compose:

- **Cog-specific** — how to read the `<deputies>` sensorium block, when to recall or kill a deputy, how to interpret deputy wakeups that arrived as cycle inputs, what the signal tags mean for decision-making.
- **Specialist agent** — how to use `ask_deputy`, when not to (routine cases the agent itself can handle), how to treat the initial briefing (advisory, not directive), what it means when your cycle starts with a `<briefing>` XML block.
- **Deputy** — reinforced via the deputy's own skills (`deputy-briefing-format`, `deputy-escalation-criteria`, `deputy-ask-response`); the system-map skill provides broader architectural context.

**The system-map skill is a maintenance surface.** Every architectural change that adds, removes, or restructures a subsystem should update the `system-map` skill in the same PR. Otherwise the skill drifts and the agents' self-model desyncs from reality.

This requirement is not unique to deputies — the system-map pattern is worth adopting system-wide. Start with deputies (it's the current change); make it the template for subsequent architectural work.

## Extra design points

### Confidence decay on CBR cases

A case the cog loop reasoned through six weeks ago may no longer apply. The Librarian's CBR confidence decay (already implemented for facts via `dprime/decay.gleam`) should extend to cases used by deputies. Deputies read decayed confidence, not stored confidence — stale patterns get weighted down naturally.

### Per-hierarchy thresholds

Similarity cutoffs for escalation don't need to be uniform. A scheduler-adjacent deputy operates in a more deterministic domain than a writer-rooted one. Configurable per root agent:

```toml
[deputy_thresholds]
coder = 0.80
researcher = 0.70
writer = 0.65
scheduler = 0.90
```

Read on deputy spawn. No deputy-internal state needed.

### Deputy prompt — domain-agnostic default

Because a deputy can watch a hierarchy that spans domains (writer → researcher → fetcher), the deputy prompt should be domain-agnostic by default. A specialised per-root-agent prompt is possible as a later optimisation, but the default is "generic deputy that understands it is serving this particular work tree."

## Configuration

| Field | Default | Purpose |
|---|---|---|
| `deputies_enabled` | True | Master switch — set `false` to disable the briefing / ask-for-help / escalation surface entirely |
| `deputies_mode` | "briefing" | "briefing" \| "briefing+ask" \| "full" |
| `deputies_model` | task_model | LLM used by deputies (default cheapest) |
| `deputies_max_turns` | 3 | Cap on deputy react-loop turns per invocation |
| `deputies_per_agent` | map | Per-root-agent enable/disable, e.g. `{coder = true, writer = false}` |
| `deputy_wakeup_enabled` | False | Allow Tier-2 escalation (wakeup) in addition to sensory events |
| `deputy_wakeup_per_hierarchy_per_hour` | 2 | Per-hierarchy cap on deputy-triggered cog wakeups |

MVP ships with mode = "briefing" and `enabled = False`. Operator opts in to measure the effect. Wakeup is gated separately and off by default even when deputies are enabled.

## Implementation phases

All four phases ship in the full MVP PR.

| # | Name | LOC | Status |
|---|---|---|---|
| **1** | **Briefing MVP** (deputy prompt + skills, kill control, DAG wiring, system-map skill) | ~600 | Shipped |
| **2** | **Ask-for-help + recall control** (long-lived deputies, `ask_deputy` tool, hierarchy inheritance via `AgentTask.deputy_subject`, shutdown on hierarchy completion) | ~500 | Shipped |
| **3** | **Escalation — Tier 1** (sensory event on `unanswered` ask answers via deputy's cog subject) | ~150 | Shipped (Tier 1 only) |
| **4** | **Sensorium + introspection** (extends DAG to full deputy branch rendering) | ~350 | Shipped |

**Total ~1600 LOC.** Each phase adds one vector of communication between deputy and the other actors:

1. Deputy → agent (briefing, one-shot)
2. Agent → deputy (pull, via `ask_deputy`) + cog → deputy (recall)
3. Deputy → cog (push, via sensory events)
4. Deputy → cog ambient (passive surface, via sensorium)

**Deferred to a follow-up** — Tier 2 wakeup (the `DeputyWakeup` scheduler variant plumbing) is specced but not wired in this MVP: it requires pattern-watching the agent's turns, which is a meaningful new channel that deserves its own design iteration. The plumbing becomes useful the moment a detector wants to trigger it.

Two phases were explicitly cut from an earlier draft:

- **Meta-observer integration** — the meta observer can pick up deputy-related patterns via cycle log reads without a dedicated subsystem phase. Formalise only if data shows it's needed.
- **Load-shedding (deputy replaces agent output autonomously)** — two reasoners producing output is where auditability frays in practice. Not worth the blast radius. Keep deputies as briefing + help + escalation, never as output producers.

## Risks and open questions

- **Cost.** A deputy per delegation hierarchy = one Haiku-class call per hierarchy for briefing. Autonomous agents that delegate often see real overhead. Config gate per root agent mitigates.
- **Novelty detection is hard.** Modes 2 and 3 depend on "is this novel?" reasoning. Leaning on CBR retrieval confidence is one answer; embedding distance is another. Both have false-positive and -negative modes. Mode 1 avoids the problem.
- **Divergent reasoning.** In Mode 2, if the deputy tells the agent "do X" but the agent chose "do Y," the agent has conflicting context. Agents must be taught to treat deputy output as advisory, not directive. Reinforce in skill docs.
- **Implementation reuse of cog loop code.** The cog loop has significant branching (escalation config, meta observer integration, retry, D' gates). A deputy loop is a subset. Implementation should factor out the core react substrate so deputies don't drag in the full cog state.
- **Debugging.** Two reasoners per hierarchy double the debugging surface. Cycle log must clearly attribute actions to agent vs deputy. Web GUI DAG tree must render deputy reasoning as a distinct branch.
- **Testing.** How do we test that a deputy's briefing improved outcomes? Need paired eval runs: same delegation with and without deputy, compare success rate, latency, token cost. Eval harness doesn't exist yet for this.
- **Cycles-not-cycles.** Deputy cycles are like cycles (cycle_id, logs, tool calls) but not exactly (no user input, no reply_to, no frontdoor). Typing needs care — probably a `DeputyCycle` variant of `CycleNodeType`.
- **Hierarchy inheritance mechanics.** Sub-delegations must carry the deputy's subject through every `agent_*` tool dispatch. Adding this to the agent framework without breaking existing tests is the largest delivery-risk item.

## What this enables

- **Specialist agents get cog-level context.** Coder (and any sub-agents it spawns) sees relevant CBR cases, recent failures, known pitfalls before it starts reasoning. Closes the "Einsteins → Mr Bean" gap.
- **Natural hierarchy awareness.** One deputy sees the whole work tree — the writer's goal, the researcher's approach, the fetcher's specific step. Escalation context is rich for free.
- **Cheap parallel attention.** Cog stops being the sole context-assembly layer. Multiple hierarchies have context pre-assembled by their deputies in parallel.
- **A substrate for future learning.** Soar's chunking pathway — deputy-led reasoning that resolves a problem becomes a new CBR case. Not in MVP but natural once the deputy pattern is in place.

What's *not* claimed: that deputies will make specialists smarter, that they'll reduce cog loop latency, that they'll improve output quality in a measurable way. Those are hypotheses the MVP should test, not promises.

## Relationship to other planned work

- **GTD pipeline (archived).** Deputies can read pending captures / next actions to inform briefings. No direct dependency.
- **Git tools PR (pending).** Deputies and git are orthogonal. A coder delegation with a deputy has better context for git operations but doesn't require one.
- **Remembrancer.** Weekly memory consolidation. Deputies do per-delegation memory consultation. Complementary, not overlapping — different time horizons.

## Open questions for the user

1. **Which agents get deputies first?** Coder only? All specialists? Default-on or default-off per agent?
2. **What's the eval plan?** How will we measure whether deputy briefings actually improve outcomes?
3. **When do we build Phases 2 and 3?** Immediately after 1 and 4, or wait for evidence from briefings-only?

The archived `commitment-tracker-gtd.md` sets the precedent: big-vision spec, honest critique, cut to MVP. Same discipline applies here.
