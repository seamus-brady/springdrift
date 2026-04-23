---
name: htwahn
description: How Things Work Around Here Now — a living architectural digest every reasoning layer (cog, specialists, deputies) reads. Updated whenever a new subsystem ships.
agents: all
---

## Purpose

Springdrift changes. New subsystems land, old ones retire, invariants evolve.
This skill is the shared self-model every reasoning layer keeps in mind — cog,
the specialist agents, and deputies all consume it. When something doesn't make
sense in the current moment, re-read this before asking; the answer is often here.

**When to update:** Every PR that adds, removes, or restructures a subsystem,
adds a tool category, or changes the shape of the agent graph should update
HTWAHN in the same commit. Otherwise the agents' self-model desyncs from reality.

## The agent graph (as of 2026-04-23)

- **Cog loop** — permanent, the only writer. Orchestrates delegations, reads
  sensorium each cycle, handles user and scheduler input, writes memory.
- **Specialist agents** (planner, project_manager, researcher, coder, writer,
  observer, comms, remembrancer, scheduler) — ephemeral per-delegation react
  loops. Each has a scoped tool set. See `docs/architecture/agents.md`.
- **Archivist** — per-cycle ephemeral worker. Generates the NarrativeEntry +
  CbrCase for each completed cycle. Fire-and-forget.
- **Appraiser** — per-task ephemeral worker. Writes pre-mortem at task start
  and post-mortem at task completion for non-trivial work.
- **Forecaster** — self-ticking actor. Evaluates plan health for active tasks
  and emits replan suggestions as sensory events.
- **Deputies** — ephemeral restricted cog loops. One per root delegation
  hierarchy. Brief specialist agents. Read-only. See below.
- **Meta observer** — post-cycle. Cross-cycle pattern detection, escalation
  interventions.
- **Librarian** — supervised. ETS-backed query cache over memory stores.
- **Scheduler** — supervised. Fires jobs, triggers autonomous cycles.

## Deputies — summary

A deputy is spawned when cog delegates to a specialist root agent. The deputy
produces a `<briefing>` block (relevant CBR cases, facts, known pitfalls) that
is prepended to the agent's instruction. Then the deputy dies.

Deputies are:
- **Ephemeral** — spawn, brief, die. No persistent state.
- **Restricted** — read-only tool subset; no writes, no delegation, no side
  effects. Structurally enforced.
- **Scoped per hierarchy** — one deputy per root delegation. Sub-delegations
  within the hierarchy don't spawn new deputies (MVP Phase 1 is one-shot, so
  this is moot for now; matters in Phase 2+).
- **Killable** — cog can invoke `kill_deputy` if a deputy is stuck or
  expensive. The hierarchy continues without a briefing.

What deputies do NOT do:
- Never respond on the agent's behalf
- Never write memory
- Never delegate, send messages, or take external actions

Full design: `docs/roadmap/planned/deputy-agents.md`.

## Deputies — what each layer needs to know

### For the cog loop

- You see a `<deputies active="N" completed_recent="M">...</deputies>` block
  in the sensorium when deputies are running or recently ran. It is ambient
  awareness, not a call to action.
- Signal values indicate what a recent deputy thought: `routine`,
  `high_novelty`, `anomaly`, `silent`. Only interesting values are worth
  following up on.
- Use `kill_deputy(deputy_id, reason)` if a deputy is stuck. Get the id from
  the sensorium or from `introspect`.
- When a scheduler-triggered cycle arrives with `source="deputy_wakeup"`
  (Phase 3+, not yet live), a deputy detected something urgent and asked for
  your attention. Treat the input seriously.

### For specialist agents

- Your instruction may begin with a `<briefing deputy_id="..." signal="...">`
  XML block. That's your deputy's output. It contains:
  - Relevant CBR cases with similarity scores
  - Relevant facts from memory
  - Known pitfalls from recent narrative
- The briefing is **advisory, not directive**. If it cites a case that doesn't
  apply, or a pitfall that's not relevant, ignore it. You are responsible for
  your own reasoning.
- Phase 2 adds `ask_deputy(question)` so you can consult your deputy mid-task.
  Not live yet.

### For deputies themselves

- You are ephemeral, read-only, and serve one hierarchy.
- Your output (the `<deputy_briefing>` XML) becomes the top of the specialist's
  system prompt. Keep it concise and actionable.
- Empty briefing (`signal=silent`, no cases, no facts) is a valid and often
  correct answer. Don't pad with irrelevant material.
- See also: `deputy-briefing-format`, `deputy-escalation-criteria`,
  `deputy-ask-response` skills.

## Memory stores at a glance

- **Narrative** — cycle-by-cycle immutable log
- **CBR cases** — problem → solution → outcome patterns
- **Facts** — key-value working memory with scope and confidence
- **Artifacts** — large content on disk
- **Planner tasks / endeavours** — structured work tracking
- **Captures** — auto-detected commitments from prose
- **Strategy Registry** — named approaches with usage stats
- **Learning Goals** — self-directed learning objectives

## Safety invariants

Never mutate these:
- Cog is the only writer (via Archivist, tools, scheduler).
- Memory is append-only. No rewrites, only new ops or supersessions.
- Actions pass through D' and normative calculus gates. Reasoning does not.
- Deputies read; they never write.

## How to use this skill

Don't re-read it every cycle — it's in your context already when it's scoped
to `all`. Use it when:
- Something surprising happens ("why is there a briefing in my prompt?")
- You encounter a concept you haven't seen before in a sensorium block or log
- You need to reason about where a new signal came from
