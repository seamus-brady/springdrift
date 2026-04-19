---
name: meta-learning
description: How to use the Strategy Registry, Learning Goals, affect-performance signals, and the metacognitive scheduler — the agent-led learning loop.
agents: cognitive
---

## Meta-Learning — the agent's own development loop

Six pieces work together so the agent can direct its own improvement:

| Phase | What | Where |
|---|---|---|
| A | Strategy Registry — named, reusable approaches with tracked outcomes | `<strategies>` in sensorium |
| B | Skills Management — agent-led skill evolution | `<skill_procedures>` in sensorium |
| C | Learning Goals Store — self-directed objectives | `<learning_goals>` in sensorium |
| D | Affect-Performance Engine — emotional patterns vs outcomes | `<affect_warnings>` in sensorium |
| E | Study-Cycle Pipeline — promote consolidated observations to live knowledge | `extract_insights` + `promote_insight` |
| F | Metacognitive Scheduler — auto-fires the others on intervals | scheduler runs five recurring jobs |

You see all six surfaced in your sensorium block every cycle. They're not
optional reading — the entire point is that each block is an active signal
about your own state and history.

## Strategy Registry (Phase A)

When you take an approach that has a name (e.g. "delegate-then-synthesise",
"verify-with-canary-before-trusting"), emit it in your narrative entry's
`<strategy_used>` field. The Archivist records `StrategyUsed` and
`StrategyOutcome` events; the sensorium surfaces top 3 active strategies
ranked by Laplace-smoothed success rate.

**Do not invent strategy names.** New strategies enter the registry only
through:
- The Remembrancer's `propose_strategies_from_patterns` (mines CBR
  clusters, rate-limited 3/day)
- Operator seed (manual JSONL append)

When you act and the cycle's approach matches an existing strategy,
emit it. When you don't match anything, omit the field.

## Learning Goals (Phase C)

Self-directed objectives. Use sparingly — a goal is a commitment to
evaluate, not a wish list.

- `create_learning_goal` — title, rationale, acceptance_criteria,
  optional strategy_id link, priority. Source defaults to
  `self_identified`. Captures `affect_baseline` automatically from the
  latest snapshot.
- `update_learning_goal` — add evidence cycle_id, transition status
  (active → achieved/abandoned/paused) with a reason.
- `list_learning_goals` — filter by status; default returns active
  ranked by priority.

Operator-directed goals are privileged — do not abandon them without
explicit justification.

## Affect Warnings (Phase D)

When the Remembrancer's `analyze_affect_performance` runs, it persists
significant correlations (|r| ≥ 0.4) under the fact key prefix
`affect_corr_<dimension>_<domain>`. Strong negative correlations
(r ≤ −0.4) appear in the sensorium's `<affect_warnings>` block AND are
prepended to the input D' gate's context — so the gate can weight risk
against your known maladaptive patterns.

If you see "high pressure → failure" in research domain, slow down
before delegating broad research queries.

## Study-Cycle Pipeline (Phase E)

When you spot a learning worth persisting:
1. Run `extract_insights` for the period. With a provider wired in, it
   uses XStructor to surface candidate insights; otherwise returns raw
   material for you to synthesise.
2. For each insight you accept, call `promote_insight` with a stable
   key + summary + confidence. Rate-limited (default 3/day). Writes
   land in the facts store as Persistent with provenance derivation
   `Synthesis`.

## Metacognitive Scheduler (Phase F)

Enabled by default. Five recurring jobs auto-fire as `SchedulerInput`
cycles you'll receive:
- `meta_learning_consolidation` (weekly)
- `meta_learning_goal_review` (daily)
- `meta_learning_skill_decay` (weekly)
- `meta_learning_affect_correlation` (weekly)
- `meta_learning_strategy_review` (fortnightly)

When the sensorium shows `<meta_recommendations>`, that's an ad-hoc
nudge based on signals (low success_rate, high novelty). Treat it the
same way: read, consider, decide whether to act.

## Discipline

The substrate doesn't make you better. Engaging with it does.

When you see a `<strategies>` block, prefer naming an existing strategy
over improvising. When you see `<affect_warnings>`, weight your risk
estimates with that history. When the scheduler delivers a `meta_learning_*`
cycle, run the procedure rather than improvising. When you have an
insight worth keeping, promote it — don't trust your own working memory
to remember across sessions.
