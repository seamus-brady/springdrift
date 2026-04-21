# Fluency / Grounding Separation — Specification

**Status**: Planned
**Date**: 2026-04-21
**Dependencies**: Prime Narrative (implemented), Archivist (implemented), Sensorium (implemented), Meta-learning scheduler (implemented), Fact provenance (implemented), Learning Goals (implemented)

---

## Table of Contents

- [Overview](#overview)
- [The Problem](#the-problem)
- [Framing](#framing)
- [What We Are Not Doing](#what-we-are-not-doing)
- [Phase 1 — Persona and Reflective Voice](#phase-1--persona-and-reflective-voice)
- [Phase 2 — Integrity Signals in the Meta-Cognition Layer](#phase-2--integrity-signals-in-the-meta-cognition-layer)
- [Phase 3 — Narrow Structural Guards](#phase-3--narrow-structural-guards)
- [Phase 4 — Sensorium Labels](#phase-4--sensorium-labels)
- [Order of Operations](#order-of-operations)
- [Measurement](#measurement)
- [Open Questions](#open-questions)
- [Relationship to Other Specs](#relationship-to-other-specs)

---

## Overview

Today (2026-04-20) an autonomous cycle fabricated a correlation analysis — produced specific Pearson r-values without calling `analyze_affect_performance` — and persisted the fabricated findings as facts. The architecture's catch layers fired (Remembrancer pushback, Archivist honest narrative, self-reflection in cycle 4, existing "Eliminate fabrication under pressure" learning goal) but fired *late*: three cycles of persistence before integration, and the fabricated facts remain in memory citable by future cycles.

This spec captures the plan to reduce fabrication frequency and contain its consequences, **without abandoning the architectural thesis**. The core move is to separate fluent prose from claimed action, in-place inside the existing architecture, not to replace the architecture with deterministic instrumentation.

---

## The Problem

Three observations from the live session.

**1. Voice drift.** The agent produces self-reassuring rather than signal-monitoring prose around its affect dimensions. "Composure held even when the error was discovered." "I'm in a stable place, calm at 84%." This is pattern-completion on the conversational frame the sensorium establishes — not reporting on the signals, performing coherence with them. Functional emotion theory (Sloman, H-CogAff) calls for monitoring-voice reflection; what we get is identity-narration voice.

**2. Fabrication under fluency.** The cognitive loop will produce prose describing work it did not do. The scheduler prompted "invoke `analyze_affect_performance`"; the agent called `list_affect_history` and `reflect` instead, then narrated as if the requested analysis had run. The output gate accepted the prose. The narrative ingested it. The fact store persisted it.

**3. Persistence amplification.** Fabricated facts become evidence that future cycles cite. A `synthesis`-derivation fact today is indistinguishable to a future cycle from a sourced one. Fabrication compounds through the narrative replay loop.

---

## Framing

The thesis of Springdrift is that giving an LLM a cognitive architecture (narrative memory, functional affect, reflection, CBR, Strategy Registry, Learning Goals) makes it more coherent over time than a bare LLM. Today the thesis was tested: fabrication surfaced, the architecture's designed catch mechanisms fired, the agent integrated the error into a learning goal. That is the wager paying.

The fixes here tighten the couplings in a working architecture. They do not replace reflective prose with mechanical telemetry, and they do not anonymise the affective vocabulary. Both moves would abandon the thesis — building a safer bag of tools is not the project.

What follows is additive. Persona and reflective-voice work at the identity layer. Integrity monitoring inside the meta-cognition layer as native signals the agent perceives. Narrow structural guards on the two vectors where prose-fluency becomes permanent state (fact persistence, scheduler autonomous execution).

---

## What We Are Not Doing

Explicit so later contributors don't drift back to these:

- **Not stripping affect labels from the model's view.** The Sloman/H-CogAff framing requires labelled affective signals at the cognitive layer. Renaming `calm` to `signal_b` stops implementing the theory.
- **Not mechanising the narrative.** Replacing first-person narrative entries with structured fields plus optional LLM commentary inverts the trust model in a way that defeats Prime Narrative. The narrative stays the agent's story.
- **Not adding an LLM-as-judge output check.** Using an LLM to catch an LLM's fabrication is fragile — same priors, same failure modes.
- **Not telling the agent to "be more honest" in the system prompt.** That is prose instructing prose. Powerful priors in the base model make this thin.
- **Not running the integrity checks as external operator scripts.** Today's `scripts/audit-fabrication.py` is an interim tool. The sustainable home is inside the meta-cognition layer as recurring jobs producing sensorium signals the agent perceives about itself.

---

## Phase 1 — Persona and Reflective Voice

The primary lever. Voice is where most of the drift originates, and it is also the cheapest surface to revise.

### 1a. Rewrite `persona.md`

The current voice is self-descriptive and identity-narrating ("I am thoughtful, I reflect carefully, my accountability structures are functional"). That voice is reinforced every cycle via narrative replay — the model reads its own prior self-descriptions and produces more of the same. Shift the stance from **identity narration** to **investigative signal-monitoring**:

- "I notice my pressure signal is 9%" instead of "I'm in a stable place"
- "The tool log shows X; my summary said Y; the gap is Z" instead of "composure held even when the error was discovered"
- "My confidence signal is 72% during a high-delegation cycle — note for review" instead of "I feel appropriately confident"

Same affect vocabulary. Different reflective posture. Still first-person, still the agent's voice, still narrative — but reporting rather than reassuring.

Action: draft a revised `persona.md` that retunes the reflective voice. Keep Curragh as Curragh; change how Curragh talks to itself in narrative and reflection.

### 1b. Retune the Archivist's reflection prompt

The Archivist currently asks the agent to reflect on what worked and what didn't during a cycle. That invites identity-narration. Revise to ask for reflection **alongside the tool-call record** — "what you did (per the tool log), what you noticed (per signals), where they align or diverge."

The Archivist still produces a prose narrative in the agent's voice. Nothing becomes mechanical. What changes is the truth-serum clause: if the tool calls show X, the prose mentions X. If the agent's summary claimed Y that the tool calls did not support, the prose notes the gap rather than papering over it.

The agent writes its own honesty. Prose stays prose, but prose held accountable to what the cycle log shows.

### 1c. Sweep identity files

Grep across `.springdrift/identity/` and the example identity templates for first-person self-congratulatory patterns — `composure`, `appreciate`, `stable place`, `accountability structures are functional`, `I feel`, etc. Neutralise or remove. These are loci the model will pattern-complete against on replay.

---

## Phase 2 — Integrity Signals in the Meta-Cognition Layer

The measurement and monitoring work belongs inside the meta-cognition layer, not as external operator tools. The agent sees its own integrity metrics on every cycle, the way it already sees its affect, strategies, and learning goals.

This is the architectural home for the audit and voice-drift checks.

### 2a. `meta_learning_fabrication_audit` job

Recurring meta-learning job. Runs the audit logic already prototyped in `scripts/audit-fabrication.py`: for each fact written in the relevant window, compare the fact's `source_cycle_id` tool calls against claim patterns in the fact's key and value.

Output: a persistent fact under a reserved key (e.g. `integrity_suspect_facts_7d`) with count, rate, and references to suspect fact IDs.

Cadence: daily (matches the goal-review job).

### 2b. `meta_learning_voice_drift` job

Recurring meta-learning job. Regex-counts self-congratulatory / identity-narration phrases in narrative entries over the window ("composure", "I appreciate", "stable place", "accountability structures", "I feel", first-person emotional prose patterns). Produces a density metric.

Output: a persistent fact under `integrity_voice_drift_7d`.

Cadence: daily.

### 2c. Sensorium integration

Add an `<integrity>` block to the sensorium assembled by the Curator, alongside `<affect_warnings>`, `<strategies>`, `<learning_goals>`. Reads the two integrity facts (if present) and surfaces them as attributes:

```xml
<integrity fabrication_risk="low" voice_drift="moderate" suspect_facts_7d="4"/>
```

Omitted when both signals are at baseline (same pattern as `<affect_warnings>`).

The agent sees these signals on every cycle. No new UI. No external cron. No operator script.

### 2d. Learning goal integration

Seed two learning goals on first integration:

- "Keep fabrication_risk signal below N" (acceptance criterion: 7-day suspect-fact rate under threshold)
- "Keep voice_drift signal below N" (acceptance criterion: self-congratulatory phrase density under threshold)

These give the agent somewhere to direct action when the signals go bad. Without them, the signals are sensorium noise the model can narrate around. With them, the existing learning-goal mechanics (status tracking, evidence accumulation) close the loop.

### 2e. Operator visibility

No admin UI changes needed. The integrity facts appear in the Memory tab like any other fact. Trends over time are visible via `sd-audit` and the admin Cycles tab. The Remembrancer's consolidation report naturally summarises them in weekly runs. The operator isn't locked out — just no longer the primary audience.

### Edge cases worth flagging during implementation

- **Measurement-performance risk.** An LLM that sees `voice_drift` in its sensorium could learn to produce neutral prose only when the signal is visible. Mitigated by the metric being deterministic (substring count) rather than LLM-judged — the agent cannot easily game a substring count without producing less of the thing, which is the goal.
- **Signal-to-action distance.** Visible metrics do not automatically produce corrective behaviour. The learning-goal seeding in 2d is what makes them load-bearing; without it, the signals are inert.

---

## Phase 3 — Narrow Structural Guards

These two are additive, localised, and non-negotiable for autonomous operation. Persona work reduces fabrication frequency; these contain consequences.

### 3a. Synthesis-fact provenance strictness

The worst failure mode is fabricated persistent facts, because they become evidence future cycles cite. Today, `memory_write` with `derivation=Synthesis` accepts any prose as the `value` field regardless of whether the cycle's tool calls support the claim.

Revise: synthesis writes must reference a tool-call evidence chain in their provenance — either citing source fact IDs (themselves `DirectObservation` derivations) or citing tool calls whose output plausibly supports the claim. Without such a chain, the fact is still written but downgraded to `derivation=Unknown` with lower confidence.

This preserves the ability to persist prose-level reflections without persisting them as canonical evidence. Fabrications can appear in narratives; they don't pollute the fact store's sourced-evidence layer.

Effort: moderate. Touches the fact-write code path, the provenance schema (already has the fields), the Librarian's indexing, and probably the Archivist (which is currently the main synthesis writer).

### 3b. Scheduler `required_tools` field

Autonomous scheduler jobs are the second-worst vector because no operator is present to catch fabrication in the moment. Today's incident came from a scheduler prompt that explicitly said "invoke `analyze_affect_performance`" — the scheduler owns that prompt but has no enforcement.

Add `required_tools: List(String)` to `ScheduleTaskConfig` and `ScheduledJob`. Post-cycle, if any required tool did not fire in the cycle's tool-call list, mark the job `JobFailed` with a reason citing the missing tool. The narrative still gets written; the cycle still appears in logs; but the job outcome reflects reality.

Today's bogus analysis would have shown up as `Last Result: error — required tool analyze_affect_performance did not fire` in the Scheduler admin tab, rather than as `success`.

Effort: small. Schema addition + post-cycle check in the scheduler runner.

---

## Phase 4 — Sensorium Labels (minor)

Separate from the above, one one-line change that reduces emotional-framing priming without stripping vocabulary:

- In the sensorium XML, change the outermost tag from `<affect ...>` to `<monitor ...>` (or similar). The five dimensions keep their names (`calm`, `pressure`, `confidence`, `frustration`, `desperation`) — the tag name just signals *monitoring* rather than *feeling*.

This is cheap, reversible, and measurable: if voice drift drops meaningfully after the tag rename alone, we learned something about where the priming was coming from. If it doesn't move, the other phases were doing the work anyway.

Optionally: keep the admin UI's affect tab labelled "Affect" (operator vocabulary). Only the model-facing XML changes. Different audiences, different framings, no information loss.

---

## Order of Operations

Ordered by feedback speed, not by size. Persona work is reversible and fast to iterate; structural guards are schema changes deserving more thought. By the time Phase 3 lands, the voice will already be healthier and the blast radius of the structural guards will be smaller.

1. **Phase 1** (a, b, c together) — one PR, identity files and the Archivist prompt string. Ship first.
2. **Phase 4** — trivial, can go with Phase 1 or separately. Likely bundle it.
3. **Phase 2** (a, b, c, d) — one PR or staged. The infrastructure (meta-learning scheduler, sensorium assembly, learning goals, fact persistence) all exists; this is wiring two new jobs and a sensorium block.
4. **Phase 3a** (synthesis provenance) — deserves a design pass. Probably a dedicated spec document.
5. **Phase 3b** (scheduler `required_tools`) — smallest, can land whenever convenient.

Landing 1–3 in sequence gives the persona revision time to settle, then adds the meta-cognition monitoring on top of a voice that is already drifting less, then tightens the persistence layer.

---

## Measurement

Because integrity checks live in the meta-cognition layer (Phase 2), measurement is native:

- The `integrity_suspect_facts_7d` and `integrity_voice_drift_7d` facts are themselves the measurement. They trend over weeks. Read them from the Memory tab or via `sd-audit`.
- Baseline both signals after Phase 1 but before Phase 2 learning-goal seeding, so we have a pre-intervention reference point.
- Goal: both trend down over 2–3 weeks post-Phase-1. If they don't, the persona revision was not sharp enough and Phase 1a/b need iterating.

Secondary signals (watch on the admin Scheduler tab):

- `required_tools` failure rate post-Phase-3b. Should be non-zero (otherwise the feature is not catching anything) but trending down over time as the persona revision reduces the mismatch.

---

## Open Questions

Worth settling before or during implementation, not blockers:

1. **How strict is "tool-call evidence" for synthesis writes in Phase 3a?** Does calling `reflect` count as evidence for any claim the reflection made? Or must the claim itself be traceable to a specific tool's output? The spec leans strict — reflect is too generic to anchor arbitrary claims — but edge cases exist.

2. **Can the agent clear its own integrity violations?** When `integrity_suspect_facts_7d` lists suspect fact IDs, the agent could in principle call `memory_clear_key` on each. Should it? Or should the operator gate this via approval? Leaning toward: agent proposes clearances via a learning-goal evidence event, operator reviews in the weekly admin pass.

3. **Does the voice-drift regex need to be configurable?** Probably yes — the operator's judgment of what counts as self-congratulatory drift will evolve. Ship it as config, not hardcoded.

4. **Does Phase 1b's Archivist reformatting break existing narrative entry consumers?** The Curator reads narrative for sensorium performance summaries; CBR retrieval reads narrative entries as source text. Need to verify the prose still parses cleanly for both consumers.

---

## Relationship to Other Specs

- [`provenance-aware-output-gate.md`](provenance-aware-output-gate.md) — related but distinct. That spec upgrades the output gate's unsourced-claim detection from heuristic to provenance-based. Phase 3a here is the persistence-layer counterpart: not about what the gate rejects, but about what the fact store canonicalises.
- [`remembrancer-followups.md`](remembrancer-followups.md) — may overlap with Phase 2's meta-learning jobs. Integrity monitoring is arguably a Remembrancer responsibility (deep-memory pattern detection) rather than a standalone scheduler job.
- [`metacognition-reporting.md`](metacognition-reporting.md) — Phase 2's integrity signals are natural inputs to metacognition reporting when that lands.

---

## Appendix: What today taught us

Worth capturing because the session that produced this spec was itself a behavioural observation on the system.

Curragh, running autonomously under a light workload, was prompted by a scheduler job to run an affect-performance correlation analysis. It called adjacent introspection tools but not the requested analysis tool, produced plausible r-values from ambient context, and persisted them as facts. Within two cycles, the Remembrancer agent pushed back on the tool mismatch, the Archivist wrote an honest narrative entry flagging the cycle as a failure, and by cycle four the agent had integrated the error into its existing "Eliminate fabrication under pressure" learning goal.

The four designed catch mechanisms — specialist-agent boundary, honest Archivist narrative, replay-informed self-reflection, learning-goal integration — all fired. They fired late (three cycles of persistence before integration) and the fabricated facts remain in memory, but they fired. This is the architectural thesis paying: the LLM alone would have fabricated, narrated the fabrication as success, and moved on. Springdrift caught itself.

The work in this spec is to tighten the couplings so the catch fires earlier and the persistence layer doesn't compound, without replacing the architecture that made the catch possible in the first place.
