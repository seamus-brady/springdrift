---
name: system-map
description: Index to the territory. Subsystem inventory, the agent graph, cross-subsystem interactions, and invariants. Read this when something unfamiliar shows up.
agents: all
---

## Purpose

When something appears in your context that you don't recognise — a new
sensorium block, an unfamiliar signal tag, a cycle node type you haven't
seen — this is the first place to check. It won't give you deep detail
(the subsystem-specific skills and `docs/architecture/*` do that). It
tells you *what* something is, *where* it came from, and *where to go next*
for more.

It is a map, not a manual.

## Subsystem inventory

**Permanent processes** (alive for the session):

- **Cog loop** — orchestrator. Reads input, delegates, writes memory. The
  only writer. Everything else hands work to cog or is spawned by cog.
- **Librarian** — supervised actor. ETS-backed query cache over the memory
  stores.
- **Scheduler** — supervised actor. Fires scheduled jobs, triggers
  autonomous cycles.
- **Curator** — assembles the system prompt + sensorium from identity and
  memory.

**Ephemeral processes** (spawn, do work, die):

- **Specialist agents** — planner, project_manager, researcher, coder,
  writer, observer, comms, remembrancer, scheduler_agent. Each runs a
  react loop per delegation, has its own tool set, returns when done.
- **Deputies** — ephemeral restricted cog-loop variants. One per root
  delegation hierarchy. Brief the specialist before its react loop starts,
  answer `ask_deputy` calls during, escalate anomalies to cog, die with
  the hierarchy.
- **Archivist** — per-cycle worker. Generates the NarrativeEntry + CbrCase
  after a cycle completes.
- **Appraiser** — per-task worker. Writes pre-mortem at task start and
  post-mortem at task completion for non-trivial work.
- **Meta observer** — post-cycle worker. Cross-cycle pattern detection;
  emits interventions.

**Self-ticking actors**:

- **Forecaster** — evaluates plan health on interval; emits replan
  suggestions as sensory events.

## Memory stores

Append-only JSONL, indexed by the Librarian:

- **Narrative** — cycle-by-cycle immutable log (what happened each cycle)
- **CBR cases** — problem/solution/outcome patterns
- **Facts** — key-value working memory with scope and confidence
- **Artifacts** — large content on disk
- **Planner tasks / endeavours** — structured work tracking
- **Captures** — auto-detected commitments from prose
- **Strategy Registry** — named approaches with usage stats
- **Learning Goals** — self-directed learning objectives

## The agent graph

```
User / Scheduler input
        ↓
      Cog loop
        ├─ delegates to → Specialist agent ──── spawns alongside ──→ Deputy
        │                    ├─ can delegate to Specialist B (inherits Deputy)
        │                    └─ returns result
        ├─ after cycle → Archivist
        ├─ after task  → Appraiser
        ├─ on interval → Forecaster (sensory events)
        └─ post-cycle  → Meta observer
```

- Cog is permanent. Everything else is ephemeral or periodic.
- Specialist agents can delegate to other specialists (`agent_*` tools)
  up to `max_delegation_depth`. Sub-delegations inherit the parent's
  deputy — one deputy per hierarchy.
- Team orchestrators coordinate multiple specialists as a unit and share
  the team's deputy.

## Interaction patterns

Two-line rules that explain when things happen:

- **Cog delegates to a specialist root agent** → a deputy spawns
  alongside and produces a briefing; the briefing is prepended to the
  specialist's instruction.
- **A specialist agent delegates to another specialist** → the sub-agent
  inherits the existing deputy; no new deputy spawns.
- **A specialist calls `ask_deputy(question)`** → the deputy answers from
  memory or escalates to cog with an `unanswered` sensory event.
- **The deputy watches an anomaly during the hierarchy's work** → it emits
  a sensory event (Tier 1) or enqueues a `DeputyWakeup` scheduler job
  (Tier 2) based on urgency.
- **A cycle completes** → the Archivist writes the NarrativeEntry +
  CbrCase; the deputy dies if this was the root delegation.
- **A task completes or begins** → the Appraiser writes a pre-mortem or
  post-mortem for non-trivial work.
- **A plan's health score crosses threshold** → the Forecaster emits a
  sensory event recommending replan.
- **A scheduled job fires** → it produces a `SchedulerInput` that flows
  through the input gate and triggers an autonomous cog cycle.

## Invariants

- **Cog is the only writer.** All persistent state (narrative, CBR,
  facts, artifacts, planner, captures, strategies, goals) is written by
  cog via the Archivist, tools, or scheduler. Specialists and deputies
  never write memory directly.
- **Append-only memory.** JSONL stores are only appended. Supersessions
  are new ops; old records stay in the log for audit.
- **Gates on the action path, not the reasoning path.** D' and normative
  calculus evaluate actions (tool calls, outputs, delegations), not
  internal reasoning. Read-only reasoning (deputies, Archivist, Appraiser)
  is not gated — their *actions* (via cog) still are.
- **Attribution for every decision.** Every consequential decision has a
  named reasoner and cycle_id in the log. Deputy reasoning is attributed
  to the deputy; agent actions to the agent; cog decisions to cog.

## Where to go next

For depth on a specific subsystem:

- Deputies → `docs/architecture/deputies.md` + the `deputy-briefing-format`,
  `deputy-escalation-criteria`, `deputy-ask-response` skills
- Memory → `docs/architecture/memory.md` + the `memory-management` skill
- Agents and delegation → `docs/architecture/agents.md` + `delegation-strategy`
- Safety gates → `docs/architecture/safety.md`
- Full architecture index → the table at the top of `CLAUDE.md`

## Self-maintenance

Every PR that adds, removes, or restructures a subsystem must update
this skill in the same commit. Otherwise the map desyncs from the
territory and agents will look for things that no longer exist (or miss
things that do).

Minimum update set for an architectural change:
1. Subsystem inventory — add/remove the subsystem
2. Agent graph — update the drawing if the relationships change
3. Interaction patterns — add the new two-line rule
4. Where-to-go-next — point at the new subsystem-specific skill or doc
