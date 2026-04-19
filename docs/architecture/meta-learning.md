# Meta-Learning Subsystem Architecture

Developer-facing reference for the components that let the agent direct
its own development: track which approaches work, set its own goals,
notice when its emotional state is predicting failure, and run periodic
self-review on a schedule.

## What problem this solves

A persistent agent accumulates experience across sessions. Without a
mechanism for using that experience, it rediscovers the same lessons
each time. The Curator already injects narrative entries, CBR cases,
and facts into context, but those are passive: they tell the agent
*what happened*, not *what should change*.

The meta-learning subsystem adds five things the agent can do *with*
its accumulated experience:

1. Name an approach as a strategy and track its outcomes.
2. Set itself a learning goal and judge progress against acceptance criteria.
3. Notice statistical correlations between affect dimensions and task outcomes.
4. Extract candidate insights from a date range and promote validated ones to live facts.
5. Auto-fire all of the above on a schedule rather than waiting to be prompted.

The first four are read+write surfaces (types, persistence, tools).
The fifth is the orchestrator that turns the rest from "the agent
could do this if it remembered" into "the agent does this on a
cadence."

## Theoretical grounding

| Source | Contribution |
|---|---|
| Zimmerman & Martinez-Pons (1986) — Self-Regulated Learning | Three-phase loop: forethought → performance → reflection. The substrate maps onto this loop. |
| Liu & van der Schaar (2025) — [arXiv:2506.05109](https://arxiv.org/abs/2506.05109) | Distinguishes *extrinsic* (human-designed) from *intrinsic* (agent-directed) metacognition. Most production agents have only the former. |
| Kolodner (1992) | Expertise is inductive — accumulates through cases plus pattern recognition. Justifies CBR as the substrate the meta-learning layer mines. |
| van de Ven et al. (2024) — [arXiv:2403.05175](https://arxiv.org/abs/2403.05175) | Stability-plasticity dilemma; replay-based retention. Why we promote insights to long-lived facts rather than relying on context. |

We make no claim that the substrate produces measurable behaviour
change yet. It provides the surfaces and the schedule; whether the
agent engages with them as decision procedures rather than passive
reference is the open empirical question.

## Components

```
src/strategy/         Strategy Registry — named approaches with tracked outcomes
src/learning_goal/    Self-directed goals with acceptance criteria
src/affect/correlation.gleam   Pearson r between affect dimensions and outcomes
src/meta_learning/scheduler.gleam   Builds the recurring task list
src/tools/remembrancer.gleam   Mining + promotion tools (extract_insights,
                               promote_insight, propose_strategies_from_patterns,
                               propose_learning_goals_from_patterns,
                               analyze_affect_performance)
src/tools/learning_goals.gleam   Cognitive-loop goal CRUD
```

### Strategy Registry (`src/strategy/`)

**Conceptually.** A *strategy* is a named, reusable approach with
tracked outcomes. Example: `verify-with-canary-before-trusting`. The
id is the stable label; the description is a short account of when
and how to use it; the registry tracks how often the agent used it
and how often it worked. Strategies are separate from:

- *Facts* (discrete claims — "Dublin rent = 2,340"),
- *Skills* (`SKILL.md` files — procedural instructions for *how* to
  perform a class of action, not *which* procedure to pick), and
- *CBR cases* (individual problem-solution-outcome records —
  strategies are the abstract pattern many cases instantiate).

The point of the abstraction: naming creates the option of
deliberately preferring or avoiding. Without named strategies, the
agent just defaults to whatever the model would do next.

**Mechanically.** Append-only event log of `StrategyEvent` records:

| Event | Effect on derived state |
|---|---|
| `StrategyCreated` | New entry with counts at 0. |
| `StrategyUsed` | Increments `total_uses`; updates `avg_pressure`. |
| `StrategyOutcome` | Increments `success_count` or `failure_count`. |
| `StrategyArchived` | Sets `active = False`. Counts preserved. |
| `StrategyRenamed` | Updates `name`. Id stable. |
| `StrategyDescriptionUpdated` | Updates `description`. |
| `StrategySuperseded` | Successor inherits predecessor's counts. Predecessor goes inactive with `superseded_by` pointer. |

Current state is derived by replay through
`strategy/log.resolve_from_events`. No in-place mutation — every
change is auditable.

**How strategies enter the registry** (three paths):

1. Agent-led deliberate seed via the `seed_strategy` cognitive-loop
   tool. Rate-limited to 5/day.
2. Remembrancer mining via `propose_strategies_from_patterns` — scans
   CBR clusters by domain + shared keywords. Rate-limited to 3/day.
3. Operator seed (manual JSONL append, or
   `import_legacy_strategy_facts` for migrating existing
   `strategy_pattern_*` facts).

**How strategies get used.** The Archivist's curation prompt teaches
the LLM to emit a `<strategy_used>` element on the narrative entry
when the cycle followed a recognisable named approach already in the
registry. The Archivist appends `StrategyUsed` + `StrategyOutcome`
events based on the narrative outcome. Agents are instructed not to
invent strategy names mid-cycle — unknown ids are silently dropped
by the resolver.

**How strategies get curated.** Four lifecycle tools on the cognitive
loop (`rename_strategy`, `update_strategy_description`,
`supersede_strategy`, `archive_strategy`) let the agent improve the
registry without losing the audit trail. The fortnightly
`meta_learning_strategy_review` scheduler job brings these to the
agent's attention periodically.

**Pruning.** The registry has three bounds to prevent unbounded
growth:

- Soft cap on active strategies (default 20). When exceeded, the
  sensorium's `<strategies>` block gains `over_cap="true"` — a signal
  for the agent to archive or supersede during review.
- Low-success auto-archive: strategies with Laplace-smoothed success
  rate < 0.4 after 10+ uses are candidates for automatic archival.
- Stale auto-archive: strategies with no events for 60+ days are
  candidates for automatic archival.

`strategy_log.prune_candidates/4` returns the events to append but
does not persist them — the scheduler-driven review job calls it and
persists the subset the agent approves. All thresholds configurable
via `[meta_learning]`.

The Curator surfaces top 3 active strategies, ranked by
Laplace-smoothed `(success+1)/(total+2)` rate, in the sensorium's
`<strategies>` block. When the registry is empty, a stub block
appears with a one-line bootstrap pointer (`seed_strategy` or
`propose_strategies_from_patterns`) so the agent doesn't face
silence.

### Learning Goals Store (`src/learning_goal/`)

Same event-replay shape as the Strategy Registry. `LearningGoal` carries
title, rationale, acceptance criteria, optional Strategy Registry link,
priority, status, evidence cycle ids, source (self_identified /
remembrancer_suggested / operator_directed / pattern_mined), and the
affect-pressure baseline at creation time.

Three cognitive-loop tools (`create_learning_goal`,
`update_learning_goal`, `list_learning_goals`) plus two from outside
the agent's own perspective:

- The Remembrancer's `propose_learning_goals_from_patterns` mines CBR
  struggle clusters (avg_confidence < 0.55 by default) and emits
  `GoalCreated` events with source `pattern_mined`. Rate-limited 2/day.
- The Observer's `review_learning_goals` returns active goals + evidence
  for an independent assessment without changing status — the cognitive
  agent retains write authority.

### Affect-Performance Correlation (`src/affect/correlation.gleam`)

Pure module. Joins affect snapshots and narrative entries by `cycle_id`,
groups by task domain, computes Pearson r between each affect dimension
(desperation, calm, confidence, frustration, pressure) and outcome
success treated as binary {0, 1}.

The function returns `(r, inconclusive)` rather than just `r` so callers
can distinguish "no signal" from "definitely no relationship." Constant
inputs (zero variance) and singletons return inconclusive.

The Remembrancer's `analyze_affect_performance` runs the join, persists
significant results (|r| ≥ 0.4 by default) as facts under the key
prefix `affect_corr_<dimension>_<domain>`, and the Curator surfaces
strong negative correlations (r ≤ -0.4) in the sensorium's
`<affect_warnings>` block. The same fact data is prepended to the input
D' gate's context so the safety scorer can weight risk against the
agent's known maladaptive patterns.

### Study-Cycle Pipeline (Remembrancer tools)

Two-step promotion path from observation to live knowledge:

1. `extract_insights` returns scoped narrative + CBR material for a
   date range. With a provider wired in, it runs an XStructor pass over
   `schemas.insights_xsd` to surface candidate insights directly;
   without one it returns raw material for the agent to synthesise.
2. `promote_insight` writes one insight to the facts store as
   Persistent with provenance derivation `Synthesis`. Rate-limited
   (default 3/day, configurable via `meta_max_promotions_per_day`).

Skill, strategy, and CBR-case promotion paths already exist via
earlier work — `propose_skills_from_patterns` (skills),
`propose_strategies_from_patterns` (strategies), and the Archivist's
own narrative-to-CBR generation.

### Metacognitive Scheduler (`src/meta_learning/scheduler.gleam`)

Pure module that turns the `[meta_learning]` config block into a list
of `ScheduleTaskConfig` records. The existing scheduler runner accepts
them at startup and arranges recurring delivery; nothing new in the
runner is needed beyond the budget cap (see below).

Each task's `query` is a natural-language instruction the cognitive
loop receives as a `SchedulerInput` cycle. The loop delegates to the
appropriate Remembrancer tool. Plain-text orchestration — the LLM is
the orchestrator, the scheduler just brings the prompts to the door
on time.

Five recurring jobs at default cadence:

| Job | Interval | What it asks the agent to do |
|---|---|---|
| `meta_learning_consolidation` | Weekly | Run `consolidate_memory` for the past week, then `write_consolidation_report` |
| `meta_learning_goal_review` | Daily | List active goals, judge progress against acceptance criteria, transition status |
| `meta_learning_skill_decay` | Weekly | Audit skills against current practice, archive obsolete ones |
| `meta_learning_affect_correlation` | Weekly | Run `analyze_affect_performance` over 30 days |
| `meta_learning_strategy_review` | Fortnightly | Review active strategies; archive low-success ones |

In addition, when post-cycle signals cross thresholds (success_rate <
0.5 OR novelty > 0.7), the Curator surfaces a `<meta_recommendations>`
block in the sensorium suggesting `analyze_affect_performance` or
`consolidate_memory`. The agent decides whether to act.

## Budget enforcement

The scheduler runner already caps total autonomous cycles per hour
(`max_autonomous_cycles_per_hour`, default 20) and tokens per hour
(`autonomous_token_budget_per_hour`, default 500_000). On top of those
absolute ceilings the meta-learning subsystem adds a proportional cap:

- `meta_max_reflection_budget_pct` (default 25). Caps the share of
  recent (rolling-hour) cycles that may be meta-learning fires. When
  a `meta_learning_*` job ticks and the projected percentage would
  exceed the cap, the fire is skipped and rescheduled. The
  `max_autonomous_cycles_per_hour` ceiling is still enforced
  independently.
- `meta_max_promotions_per_day` (default 3). Caps `promote_insight`
  writes per rolling 24-hour window. The Strategy and Goal proposers
  carry their own per-day caps (3 and 2 respectively) defined at the
  tool level.

## Configuration

All settings live under `[meta_learning]` in `.springdrift/config.toml`:

```toml
[meta_learning]
strategy_registry_enabled = true             # Phase A on/off
scheduler_enabled = true                     # Phase F on/off (auto-firing)
consolidation_interval_hours = 168           # Weekly
goal_review_interval_hours = 24              # Daily
skill_decay_interval_hours = 168             # Weekly
affect_correlation_interval_hours = 168      # Weekly
strategy_review_interval_hours = 336         # Fortnightly
max_reflection_budget_pct = 25               # Soft proportional cap
max_promotions_per_day = 3                   # Promotion rate limit
```

Defaults are on. Operator opts out by setting `scheduler_enabled =
false` (turns off auto-firing without disabling the underlying
substrate — agent + Remembrancer can still invoke the tools on demand).

## How it surfaces in the running agent

Every cycle, the Curator builds the `<sensorium>` block injected into
the system prompt. The meta-learning subsystem contributes up to four
of its child elements:

- `<strategies>` — top 3 active strategies + success rates (omitted
  when registry is empty)
- `<learning_goals>` — top 3 active goals by priority (omitted when
  no active goals)
- `<affect_warnings>` — strong negative affect-vs-outcome correlations
  (omitted when nothing meets threshold)
- `<meta_recommendations>` — ad-hoc nudges based on recent
  success_rate and novelty signals

A separate sibling, `<skill_procedures>`, maps action classes
(delegate, create_task, send_email, deep memory work, web research,
self-diagnostic, appraisal, affect check, set_or_review_learning_goal,
strategy_or_insight_promotion) to the skill the agent should consult
before acting. This is the agent-side "use the substrate as a
procedure" nudge.

## Storage layout

```
.springdrift/memory/
├── strategies/YYYY-MM-DD-strategies.jsonl    # StrategyEvent log
├── learning_goals/YYYY-MM-DD-goals.jsonl     # GoalEvent log
├── consolidation/YYYY-MM-DD-consolidation.jsonl  # ConsolidationRun log (Web GUI Memory tab reads here)
└── facts/YYYY-MM-DD-facts.jsonl              # affect_corr_* + promote_insight writes
```

All append-only. Status changes are new events, not edits. Resolvers
in each module derive the current state by replay.

## Web GUI

The admin dashboard's **Memory** tab lists consolidation runs with
counts (entries / cases / facts reviewed, patterns found, facts
restored, threads resurrected) plus the decayed-fact and dormant-thread
snapshots from each run. Clicking a row reveals the run summary in a
side box. Read-only by design — the agent decides when to consolidate;
the Metacognitive Scheduler fires it weekly.

The Skills tab shows skill metrics (read counts) — the primary
behavioural signal for whether the agent treats skills as active
procedures or passive reference.

## What this does NOT do

- **Weight-level learning.** The model isn't being trained. The agent
  accumulates better-informed context over time, but the underlying
  capability is unchanged.
- **Approval workflow.** Promotions are agent-led with rate limits and
  D' gating; there is no operator inbox.
- **External benchmarking.** Strategy success rates are observational
  (Laplace-smoothed counts of self-reported outcomes), not held against
  any external standard.

## Open empirical question

The substrate exists. Whether the agent treats it as decision
procedure or passive reference is the open question. Skills metrics
(read counts on the procedure-mapped skills) are the primary signal
for whether the soft interventions (persona rules, sensorium nudges)
are moving behaviour. Flat counts after a sustained run would suggest
escalating to pre-tool injection hooks.

## Implementation history

For the chronological account of how each piece was built, plus
follow-up commits, see `docs/engineering-log.md` (the "Meta-Learning
System" entry of April 18–19, 2026) and the original specification
in `docs/roadmap/planned/meta-learning.md`.
