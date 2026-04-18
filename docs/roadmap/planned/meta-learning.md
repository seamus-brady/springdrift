# Meta-Learning System — Design Specification

**Status**: Partially shipped (Phases A + B 2026-04-18); Phases C, D, E, F planned
**Date**: 2026-04-17 (last revised 2026-04-18)
**Author**: Drafted by Curragh (Springdrift instance a62fa947), revised for agent-led operation
**Related**: `docs/roadmap/implemented/skills-management.md` (Phase B, the skills layer)

---

## 1. Overview

The Springdrift framework ([Brady, 2026](https://arxiv.org/abs/2604.04660))
provides persistent memory, CBR with outcome-tracked utility, post-cycle
reflection, affect telemetry, and normative safety. It has the infrastructure
for learning. What it lacks is a systematic mechanism for the agent to
direct its own skill development.

This specification adds **intrinsic metacognition**: the ability for the
agent to assess its own capabilities, set learning goals, select strategies,
execute them, and evaluate whether the strategy worked.

**Design principle: agent-led, operator-audited.** The operator sets standing
policy upfront (character spec, D' config, rate limits) and audits outcomes
retrospectively. Per-item approval is out of scope — the design target is a
professional AI retainer that manages its own craft within a clear remit.

---

## 2. Theoretical grounding

- **Self-Regulated Learning (SRL)** — Zimmerman & Martinez-Pons (1986–1988):
  three-phase loop (forethought → performance → reflection).
- **Intrinsic metacognition** — Liu & van der Schaar (2025),
  arXiv:2506.05109: distinguishes extrinsic (human-designed) from intrinsic
  (agent-directed) metacognition; identifies three required components —
  metacognitive knowledge, planning, evaluation.
- **Case-based expertise** — Kolodner (1992): expertise is inductive;
  accumulates through cases plus pattern recognition.
- **Continual learning** — van de Ven et al. (2024), arXiv:2403.05175:
  stability-plasticity dilemma; replay-based retention.
- **Error monitoring as metacognition** — Zhang & Fiorella (2023):
  growth-mindset learners extract lessons from failure.
- **MAML** — Finn, Abbeel & Levine (2017), arXiv:1703.03400: optimising for
  learnability itself.
- **Skill acquisition stages** — Dreyfus (1980): novice → expert progression
  grounded in observable behaviour.

The gap Liu & van der Schaar identify: most production agents use
extrinsic metacognition — fixed, human-designed loops. Almost none
implement intrinsic metacognition where the agent decides what to learn.
Springdrift's persistent memory, principal-agent autonomy, and affect
telemetry position it to fill this gap.

---

## 3. Existing infrastructure this builds on

| Subsystem | What it already does | What it lacks |
|---|---|---|
| Narrative + Archivist | Per-cycle reflection (what worked, what failed) | Cross-cycle synthesis into patterns |
| CBR utility scoring | Cases earn retrieval priority via Laplace-smoothed outcome score | Strategy tagging — "which approach worked" is not separable from "which case worked" |
| Affect telemetry | 5-dimensional emotional signal per cycle | No link to task outcomes |
| Remembrancer | Mines patterns across months/years | Does not yet feed results back into live knowledge |
| Document Library (Phases 1–10) | Structured sources, notes, drafts, journal | No study-cycle pipeline promoting consolidated knowledge back to CBR/facts |
| D' + normative calculus | Safety gate on outputs | Not yet applied to learning-promotion decisions |
| Scheduler | Runtime job creation via `schedule_from_spec` | Not wired to learning activities |

The missing pieces are **connective tissue**, not new substrates.

---

## 4. Six new components

Each component is small, ships independently or in a clear order, and flows
through existing infrastructure.

### 4.1 Phase A — Strategy Registry — SHIPPED 2026-04-18

**Status**: Substrate + integration shipped. Remembrancer auto-proposal
(creating `StrategyCreated` events from mined CBR clusters) lands later as a
small follow-up to this phase.

**Purpose**: Named, reusable approaches with tracked outcomes. Separates
"which approach works" from "which case worked."

**Storage**: `.springdrift/memory/strategies/YYYY-MM-DD-strategies.jsonl`

**Data model** (in `src/strategy/types.gleam`):
- `Strategy` — derived state: `id`, `name`, `description`, `domain_tags`,
  `success_count`, `failure_count`, `total_uses`, `avg_pressure`,
  `source` (Observed / Proposed / OperatorDefined), `active`,
  `last_event_at`.
- `StrategyEvent` — append-only log entries: `StrategyCreated`,
  `StrategyUsed`, `StrategyOutcome`, `StrategyArchived`. Replay derives
  the `Strategy` list (`strategy/log.resolve_from_events`).

**Integration shipped**:
- `NarrativeEntry` gains `strategy_used: Option(String)`. Backward-compatible
  decoder defaults to `None` for pre-Phase-A entries.
- `CbrCase` gains `strategy_id: Option(String)`, populated by the Archivist
  from the narrative entry.
- Archivist's curation prompt teaches the LLM to emit `<strategy_used>`
  only for recognisable Registry approaches (no inventing names).
- Archivist appends `StrategyUsed` + `StrategyOutcome` events after writing
  the narrative entry. Events for unknown strategy ids are silently
  dropped by the resolver — orphan ids become future proposal candidates.
- Curator's `<strategies>` sensorium block surfaces the top 3 active
  strategies ranked by Laplace-smoothed success rate; omitted when the
  registry is empty.
- `[meta_learning] strategy_registry_enabled` config field parses today;
  enforcement (no-op when False) is a follow-up.

**Not yet shipped (Phase A follow-ups)**:
- Remembrancer `propose_strategies_from_patterns` tool (analogous to
  `propose_skills_from_patterns`).
- Per-domain strategy filtering in the sensorium (current top 3 is global).
- Affect-pressure capture: the `affect_pressure` slot in `StrategyUsed`
  is plumbed but currently always `None` — Phase D will populate it.
- Strict honoring of `strategy_registry_enabled = false` in the Archivist
  emit path.

**Reference**: Liu & van der Schaar (2025) "metacognitive knowledge" —
strategy evaluation. Andrychowicz et al. (2016) — learning how to optimise
outperforms fixed optimisation.

**Dependency**: None. Ships first.

### 4.2 Phase B — Skills Management System — SHIPPED 2026-04-18

**Status**: Shipped end-to-end via `docs/roadmap/implemented/skills-management.md`
(all 12 phases) on 2026-04-18.

**Purpose**: Replace flat `SKILL.md` with structured, versioned,
evidence-based skill documents.

**What landed**:
- Two-state lifecycle (`Active`, `Archived`) — `src/skills.gleam` `SkillStatus`.
- `skill.toml` sidecar with versioning, scoping, provenance — `src/skills.gleam`.
- Per-skill metrics (read / inject / outcome) — `src/skills/metrics.gleam`.
- Snapshots, archive compaction, rollback — `src/skills/versioning.gleam`.
- Pattern detector (Jaccard over CBR clusters) — `src/skills/pattern.gleam`.
- LLM-written skill bodies with template fallback — `src/skills/body_gen.gleam`.
- LLM conflict classifier — `src/skills/conflict.gleam`.
- Promotion Safety Gate — `src/skills/safety_gate.gleam` (deterministic +
  rate limit + same-scope cooldown + LLM conflict + D').
- Remembrancer `propose_skills_from_patterns` tool — mines, generates, gates,
  promotes accepted proposals to Active skills on disk.
- Per-day skills lifecycle JSONL log — `.springdrift/memory/skills/`.
- Web GUI audit panel reading the lifecycle log.

**Operator's standing mandate** is expressed via `identity/character.json` +
`dprime.json` + rate-limit config — no per-item approval inbox.

### 4.3 Phase C — Learning Goals Store

**Purpose**: Self-directed learning objectives.

**Storage**: `.springdrift/memory/learning_goals/YYYY-MM-DD-goals.jsonl`

**Data model**:
- `id`, `title`, `rationale`, `acceptance_criteria`
- `strategy_id` (links to Strategy Registry)
- `priority` (0.0–1.0), `status`: `active` | `achieved` | `abandoned` | `paused`
- `evidence` (cycle IDs), `affect_baseline`
- `source`: `self_identified` | `remembrancer_suggested` | `operator_directed` | `pattern_mined`

**Integration**:
- Remembrancer proposes goals from pattern mining.
- Sensorium gains `<learning_goals active="N" recently_achieved="N"/>`.
- Metacognitive scheduler (Phase F) creates recurring check-ins.
- Observer evaluates progress against acceptance criteria.

**Reference**: Zimmerman's forethought phase. Source field distinguishes
intrinsic from extrinsic motivation.

**Dependency**: Phase A.

### 4.4 Phase D — Affect-Performance Correlation Engine

**Purpose**: Correlate affect dimensions with task outcomes. Lets the agent
detect its own maladaptive emotional patterns.

**Storage**: Analytical pipeline over existing stores; results cached in
facts (`affect_correlation_<dimension>_<domain>`).

**Output model**:
- `affect_dimension`, `task_domain`, `correlation` (-1.0 to 1.0)
- `sample_size`, `time_period`, `notable_patterns`

**Integration**:
- Reads existing affect + narrative stores; no new memory required.
- Remembrancer runs analysis during consolidation.
- Sensorium flags known failure patterns:
  `<affect_warning pattern="..." historical_failure_rate="..."/>`.
- D' input gate can reference affect warnings as context.

**Reference**: Liu & van der Schaar (2025) metacognitive monitoring.
Distinguishes productive pressure from counterproductive stress.

**Dependency**: ~50 cycles of affect+outcome data. Can run in parallel
with Phase A (needs existing infrastructure only).

### 4.5 Phase E — Study-Cycle Pipeline

**Purpose**: Promote consolidated observations into live knowledge. Closes
the loop from "noticed" to "learned."

**Pipeline (4 steps — simplified from original 6)**:

```
1. OBSERVE     (Archivist per-cycle reflections — EXISTS)
2. CONSOLIDATE (Remembrancer mines patterns — EXISTS)
3. D' REVIEW   (validates safety on each proposed promotion)
4. PROMOTE     (accepted proposals → live knowledge, rate-limited)
```

No distinct "propose → review → approve" staging. Step 3 is the review;
step 4 happens automatically if step 3 passes.

**What gets promoted**:
- New CBR cases (from validated pattern clusters).
- Fact updates (from restored-confidence events).
- Skill proposals (Phase B — shipped 2026-04-18; the pipeline already
  promotes via Remembrancer's `propose_skills_from_patterns`).
- Strategy proposals (Phase A).

**Integration**:
- Extends Remembrancer with `extract_insights` and `propose_knowledge`
  tools. These write directly to CBR/facts/skills/strategy stores via
  append, subject to D' review and rate limit.
- Aligns with Document Library Phase 14.
- Triggered by the Metacognitive Scheduler (Phase F) or on demand.

**Reference**: Zimmerman's reflection phase, operationalised. Replay
mechanism (van de Ven et al., 2024). D' addresses hallucination risk.

**Dependency**: Phase A (strategies) + Phase B (skills) for full
coverage. A narrow version (CBR + facts only) could ship earlier.

### 4.6 Phase F — Metacognitive Scheduler

**Purpose**: Trigger learning activities based on intervals and performance
signals. The capstone.

**Configuration** (`[meta_learning]` in `config.toml`):

```toml
[meta_learning]
# Cadence of standard learning activities
consolidation_interval = "weekly"
goal_review_interval = "daily"
skill_decay_check = "weekly"
affect_correlation_interval = "weekly"
strategy_review_interval = "fortnightly"

# Safety / quality thresholds
min_cycles_before_proposal = 50
max_reflection_budget_pct = 5
max_promotions_per_consolidation = 5
```

**Integration**:
- Uses the existing scheduler agent via `schedule_from_spec` at startup,
  not a new TOML loader. (Supersedes Remembrancer follow-up #2 — TOML
  schedule-loader.)
- Reads the sensorium: low `success_rate` triggers ad-hoc failure
  analysis; high `novelty` triggers strategy review.
- `max_reflection_budget_pct` caps the cognitive budget spent on
  meta-learning, preventing rumination.
- `max_promotions_per_consolidation` is the rate limit; exceeded proposals
  are dropped with a log entry and surfaced in the consolidation report.

**Reference**: Liu & van der Schaar (2025) metacognitive evaluation.
Budget cap prevents rumination (Zhang & Fiorella).

**Dependency**: All other phases (this is the orchestrator).

---

## 5. The learning loop

How phases connect, mapped to Zimmerman's SRL cycle:

**FORETHOUGHT** (per cycle):
- Sensorium injects vitals, active learning goals, relevant affect warnings.
- Curator injects matching strategies and skills.
- Agent selects a strategy or improvises.
- Agent sets outcome expectations.

**PERFORMANCE** (per cycle):
- Execution using selected strategy.
- Affect recorded throughout.
- DAG captures tool / delegation outcomes.
- Sensorium updates in real-time.

**REFLECTION** (per cycle, existing):
- Archivist: reflection + new tags (`strategy_used`, `skills_exercised`).
- CBR: new case with `strategy_id` link.
- Affect: snapshot with cycle reference.

**CONSOLIDATION** (periodic):
- Remembrancer mines patterns.
- Affect-Performance Engine correlates.
- Study-Cycle Pipeline: extract → D' review → promote.
- Strategy Registry, Skills, Learning Goals updated.

Data flow is append-only throughout. Every promotion passes through D'.
Full chain auditable via DAG replay.

---

## 6. Design constraints

1. **Append-only persistence** — all new stores follow JSONL model.
2. **Curator budget** — 8,000 chars, priority-based selection. New
   sensorium elements (strategies, goals, affect warnings) compete within
   this budget. May need to raise the default.
3. **Auditability** — traceable chain from cycles → patterns → proposals →
   D' review → promotion, all visible in consolidation reports.
4. **Principal-agent autonomy** — agent sets own goals; operator sets
   standing policy and can override any time via supersession.
5. **Safety via D'** — normative review on all knowledge promotions. No
   new safety machinery, just a new domain for the existing one.
6. **Efficiency** — max 5% of cycle budget for meta-learning activities.
7. **No identity change** — skills evolve; the persona and character do
   not. `character.json` is the anchor.

---

## 7. Implementation sequencing

| Phase | Prereqs | Effort | Status |
|---|---|---|---|
| A — Strategy Registry | None | Small-Medium | ✅ SHIPPED 2026-04-18 |
| B — Skills Management | `skills-management.md` shipped | Medium-Large | ✅ SHIPPED 2026-04-18 |
| C — Learning Goals Store | Phase A | Small-Medium | Unblocked |
| D — Affect-Performance Engine | ~50 cycles of data (exists) | Small | ✅ Ready |
| E — Study-Cycle Pipeline | A + B (narrow version only needs A) | Medium | Unblocked (A + B done) |
| F — Metacognitive Scheduler | A–E | Medium | Capstone |

**Recommended order (revised 2026-04-18, A + B shipped)**: D → C → E → F.

**Phases ready to start immediately**: D (and the small A follow-ups —
strategy proposer, per-domain sensorium filtering, config-gate enforcement).

---

## 8. What this doesn't change

- **Cognitive loop** — same LLM-driven design, same personality.
- **D' normative calculus** — unchanged; extended to a new domain.
- **Memory architecture** — append-only preserved.
- **Agent delegation** — same OTP processes.
- **Principal authority** — operator can override at any time via
  supersession records, character spec edits, or D' config tightening.
- **Identity** — same Curragh, more skillful.

---

## 9. Risks and mitigations

| Risk | Mitigation |
|---|---|
| D' misses a bad promotion | Rate limit caps per-window damage. Append-only supersession lets operator revert. Consolidation report surfaces everything promoted. |
| Drift — agent's skill set diverges from operator intent | Character spec governs promotion via D'. If the operator tightens character spec, next consolidation re-scans Active skills and archives incompatible ones. |
| Rumination — meta-learning eats cycle budget | `max_reflection_budget_pct` cap. Metacognitive scheduler backs off when the cap is hit. |
| Effectiveness is not really measured (correlation vs. causation) | Spec explicitly does not claim to measure it. Usage + correlation are reported honestly as signals, not scores. |
| Curator budget squeeze | `preamble_budget_chars` can be raised. Priority-based selection already in place. Worst case: some sensorium elements omitted in long sessions. |
| Complexity ceiling | Phased rollout; each phase small and independently shippable. Phase F only lands after A–E are stable. |

---

## 10. What this does NOT include

- **Weight-level learning** — the model doesn't get smarter. The agent
  gets better-informed about its own history. Explicitly not a training
  pipeline.
- **Approval workflow** — intentionally out of scope (see design principle).
- **Operator micro-management tools** — the web GUI is audit-only.
- **External benchmarking** — proficiency is inferred from internal signals.
  External evaluation against a golden standard is a separate concern.

---

## 11. References

1. Brady, S. (2026). *Springdrift: An Auditable Persistent Runtime for
   LLM Agents*. arXiv:2604.04660.
2. Zimmerman, B.J. & Martinez-Pons, M. (1986). *American Educational
   Research Journal*, 23(4).
3. Liu, Z. & van der Schaar, M. (2025). arXiv:2506.05109.
4. van de Ven, G.M. et al. (2024). arXiv:2403.05175.
5. Finn, C. et al. (2017). arXiv:1703.03400.
6. Andrychowicz, M. et al. (2016). arXiv:1606.04474.
7. Kolodner, J.L. (1992). *Artificial Intelligence Review*, 6(4).
8. Zhang, L. & Fiorella, L. (2023). *Educational Psychology Review*.
9. Dreyfus, S.E. (1980). UC Berkeley Operations Research Center.
