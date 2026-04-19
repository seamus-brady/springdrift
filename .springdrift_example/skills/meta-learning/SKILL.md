---
name: meta-learning
description: How to use the Strategy Registry, Learning Goals, affect-performance signals, the Study-Cycle pipeline, and the Metacognitive Scheduler — the substrate for directing your own development.
agents: cognitive
---

## What a strategy is (and isn't)

A **strategy** is a named, reusable approach with tracked outcomes.
Example: `verify-with-canary-before-trusting`, or
`delegate-then-synthesise`. The id is the label; the body is a short
description of when and how to use it; over time the registry tracks
how often you used it and how often it worked.

Strategies are a separate memory substrate:

- **Facts** are discrete claims about the world. "Dublin rent = 2,340"
  is a fact. A strategy isn't.
- **Skills** (`SKILL.md` files) are procedural instructions — *how* to
  perform a class of action. A strategy is about *which procedure to
  choose*.
- **CBR cases** are individual problem-solution-outcome records. A
  strategy is the abstract pattern many cases instantiate.

Why it matters: naming creates the option of deliberately preferring
or avoiding. Without a named strategy, you just default to whatever
the model would do next. With it, you can notice a pattern, track its
success rate, and retire it when it stops earning its keep.

## Day One: the registry is empty

Fresh installs (and instances that haven't populated the registry
yet) will see `<strategies count="0" state="empty">` in the sensorium.
That's a signal, not noise. Two paths to populate:

1. **Seed deliberately** — `seed_strategy` creates a single entry
   directly. Use when you already have a named approach in mind.
   Rate-limited to 5/day — the registry is meant to be a small
   playbook, not a junk drawer.
2. **Mine from experience** — the Remembrancer's
   `propose_strategies_from_patterns` tool scans CBR clusters,
   derives strategy ids from recurring domain+keyword patterns, and
   emits `StrategyCreated` events. Rate-limited to 3/day. Useful once
   you have enough CBR history to mine.

If you have facts named `strategy_pattern_*` from a prior manual
tracking system, the Remembrancer's `import_legacy_strategy_facts`
migrates them in one shot (idempotent; dry-run supported).

Once the registry has a few entries, the sensorium switches from the
empty stub to `<strategies count="N">` with the top 3 listed.

## Naming a strategy when you use one

Once the registry is populated, emit `<strategy_used>` in your
narrative entry whenever the cycle followed one of the named
approaches. The Archivist records it; the registry tracks success vs
failure counts (success = narrative outcome is `Success`).

**Do not invent strategy names mid-cycle.** If your approach doesn't
match any existing strategy, omit the field. Either call
`seed_strategy` explicitly to register it before using, or let the
Remembrancer surface it later if the approach recurs.

## Curating the registry

Four tools let you improve the registry without losing the audit
trail:

- `rename_strategy(id, new_name, reason)` — name is mutable, id is
  stable. Existing references keep working.
- `update_strategy_description(id, new_description, reason)` — sharpen
  a vague description. Useful when a strategy's original success
  metric turns out to be unclear in practice.
- `supersede_strategy(old_id, new_id, reason)` — declare one strategy
  absorbs another (deduplication). The successor inherits the
  predecessor's success/failure counts. The predecessor goes inactive
  with a pointer to the successor for audit.
- `archive_strategy(id, reason)` — mark a strategy inactive. Use when
  the approach is no longer earning its keep and there's no clean
  successor.

`list_strategies` returns the current registry (default: active
ranked by success rate).

## Limits and pruning

The registry has a soft cap (default 20 active strategies). When
exceeded, the sensorium's `<strategies>` block gains an `over_cap`
attribute — your signal to review and archive. The fortnightly
`meta_learning_strategy_review` job is the natural time to do this.

Two more pruning criteria apply automatically during review cycles:

- Sustained low success rate (Laplace-smoothed < 0.4 after 10+ uses)
  makes a strategy a candidate for auto-archival.
- No events for 60+ days makes a strategy a candidate for
  stale-archival.

All thresholds are configurable via `[meta_learning]` in the config.

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
- The Observer's `review_learning_goals` returns active goals +
  evidence for an independent assessment. Observer doesn't change
  status — that remains your call.

**Operator-directed goals are privileged.** Do not abandon them
without explicit justification.

## Reading affect warnings

When `<affect_warnings>` shows a strong negative correlation between
an affect dimension and outcome success in a domain (e.g. "high
pressure in research → failure"), weight your risk estimate
accordingly. Slow down before delegating broad research queries when
pressure is rising.

The same correlation data is fed to the input D' gate as risk
context.

## Promoting an insight

When you spot a learning worth persisting beyond this session:

1. Run the Remembrancer's `extract_insights` for the period. With a
   provider wired in it returns LLM-extracted candidates; otherwise
   raw material to synthesise from.
2. For each insight you accept, call `promote_insight` with a stable
   key + summary + confidence. Rate-limited (default 3/day). The
   result lands in the facts store as Persistent with provenance
   derivation `Synthesis`.

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
| `meta_learning_strategy_review` | Fortnightly | `list_strategies`, then `archive_strategy` / `supersede_strategy` / `update_strategy_description` as warranted |

When the sensorium shows `<meta_recommendations>`, that's an ad-hoc
nudge based on signals (low success_rate, high novelty). Same
treatment: read, consider, decide.

## Discipline

The substrate doesn't make you better. Engaging with it does.

When you see a `<strategies>` block, prefer naming an existing
strategy over improvising. When you see `<affect_warnings>`, weight
your risk estimates with that history. When the scheduler delivers a
`meta_learning_*` cycle, run the procedure rather than improvising.
When you have an insight worth keeping, promote it — don't trust your
own working memory to remember it across sessions.
