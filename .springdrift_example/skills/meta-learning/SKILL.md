---
name: meta-learning
description: How to use the Strategy Registry, Learning Goals, affect-performance signals, the Study-Cycle pipeline, and the Metacognitive Scheduler — the substrate for directing your own development.
agents: cognitive
---

## What this skill is for

Several pieces of memory let you direct your own development:

- **Strategies** — named approaches with tracked success rates, surfaced
  in the sensorium's `<strategies>` block.
- **Learning goals** — your own objectives, with rationale and acceptance
  criteria, surfaced in `<learning_goals>`.
- **Affect warnings** — statistical correlations between your emotional
  state and task outcomes, surfaced in `<affect_warnings>`.
- **Insight promotion** — turning consolidated observations into live
  facts you'll see again next session.
- **Auto-fired self-review** — the scheduler delivers weekly
  consolidation, daily goal review, weekly skill-decay audits, weekly
  affect-correlation analysis, and fortnightly strategy review as
  scheduler-triggered cycles.

Every cycle, the sensorium also shows `<skill_procedures>` mapping
action classes to the skill you should consult — including this one
for goal-setting and insight promotion. Read first, act second.

## Naming a strategy when you use one

When you take an approach that has a recognisable name (e.g.
"delegate-then-synthesise", "verify-with-canary-before-trusting"),
emit it in your narrative entry's `<strategy_used>` element. The
Archivist records it; the registry tracks success vs failure
counts.

**Do not invent strategy names.** Only emit strategies that already
exist in the registry. New entries arrive through:

- The Remembrancer's `propose_strategies_from_patterns`, which mines
  recurring CBR clusters (rate-limited 3/day).
- Operator seed.

If your approach doesn't match any existing strategy, omit the field.
The Remembrancer will surface it later if it recurs.

## Setting a learning goal

Use sparingly — a goal is a commitment to evaluate, not a wish list.

- `create_learning_goal` — title, rationale, acceptance_criteria,
  optional `strategy_id` link, priority. Source defaults to
  `self_identified`. The current affect-pressure snapshot is captured
  as the baseline.
- `update_learning_goal` — add an evidence cycle_id, transition status
  (active → achieved/abandoned/paused) with a free-text reason.
- `list_learning_goals` — filter by status; default returns active
  ranked by priority.

Two more bring goals in from outside:

- The Remembrancer's `propose_learning_goals_from_patterns` mines CBR
  struggle clusters (avg_confidence < 0.55) and creates
  `pattern_mined`-source goals. Rate-limited 2/day.
- The Observer's `review_learning_goals` returns active goals + evidence
  for an independent assessment. Observer doesn't change status — that
  remains your call.

**Operator-directed goals are privileged.** Do not abandon them without
explicit justification.

## Reading affect warnings

When `<affect_warnings>` shows a strong negative correlation between an
affect dimension and outcome success in a domain (e.g. "high pressure
in research → failure"), weight your risk estimate accordingly. Slow
down before delegating broad research queries when pressure is rising.

The same correlation data is fed to the input D' gate as risk context.

## Promoting an insight

When you spot a learning worth persisting beyond this session:

1. Run the Remembrancer's `extract_insights` for the period. With a
   provider wired in it returns LLM-extracted candidates; otherwise
   raw material to synthesise from.
2. For each insight you accept, call `promote_insight` with a stable
   key + summary + confidence. Rate-limited (default 3/day). The result
   lands in the facts store as Persistent with provenance derivation
   `Synthesis`.

## When the scheduler delivers a self-review cycle

Five recurring jobs auto-fire as `SchedulerInput` cycles you'll
receive. Each name starts with `meta_learning_` so you can recognise
them. Treat them as procedures: read this skill, run the named tool,
write the report.

| Job | Cadence | Tool to invoke |
|---|---|---|
| `meta_learning_consolidation` | Weekly | `consolidate_memory` + `write_consolidation_report` |
| `meta_learning_goal_review` | Daily | `list_learning_goals`, then `update_learning_goal` per goal |
| `meta_learning_skill_decay` | Weekly | `read_skill` per loaded skill; archive if no longer in use |
| `meta_learning_affect_correlation` | Weekly | `analyze_affect_performance` (past 30 days) |
| `meta_learning_strategy_review` | Fortnightly | Inspect `<strategies>`; archive low-success ones |

When the sensorium shows `<meta_recommendations>`, that's an ad-hoc
nudge based on signals (low success_rate, high novelty). Same
treatment: read, consider, decide.

## Discipline

The substrate doesn't make you better. Engaging with it does.

When you see a `<strategies>` block, prefer naming an existing strategy
over improvising. When you see `<affect_warnings>`, weight your risk
estimates with that history. When the scheduler delivers a
`meta_learning_*` cycle, run the procedure rather than improvising.
When you have an insight worth keeping, promote it — don't trust your
own working memory to remember it across sessions.
