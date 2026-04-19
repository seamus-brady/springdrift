# Changelog

All notable changes to Springdrift are recorded here.

The project follows [Semantic Versioning](https://semver.org/) starting from
0.8.0. Releases on `0.x.y` are not API-stable — breaking changes can land in
any minor bump until 1.0.0. Patch releases (`0.8.1`, `0.8.2`, ...) are
backwards-compatible bug fixes only.

For implementation history beyond what's user-visible, see
`docs/engineering-log.md`.

---

## [0.9.3] — 2026-04-18

Forecaster returns real per-task scores. Every task (through the tool
path) scored exactly `0.3333333…` in production regardless of state —
23 of 23 forecast updates in the local planner log carried the same
constant value.

### Fixed

- **Forecaster no longer returns a constant 0.3333 for every task.**
  `tools/planner.compute_task_forecasts` had its own copy of the
  heuristic computation using magnitudes on a 1–9 scale (step_rate:
  1/4/7, dep: 1/5+blocked, complexity: 1/5, risk: 1/3+n\*2/9,
  scope_creep: 1) with **a default value of 1** for every feature
  when no signal was present. The D' engine clamps magnitudes to
  `[0, 3]`, so the high values collapsed to 3 while all the "default"
  1s stayed at 1. With five features all at magnitude 1 and
  importances `[3, 3, 2, 2, 1]`, every task landed at
  `(3·1 + 3·1 + 2·1 + 2·1 + 1·1) / ((3+3+2+2+1)·3) = 11/33 ≈ 0.3333`.
  Tasks with stalled progress, blocked dependencies, or materialised
  risks all scored identically to fresh tasks. The tool path now
  delegates to the Forecaster actor's heuristic, which uses the
  correct 0–3 scale and zero as the "no signal" default.

### Why this matters

A forecaster that returns the same score for every task isn't a
forecaster — it's a constant. The replan-threshold trigger
(`forecaster_replan_threshold`, default 0.55) never fired, and the
per-feature breakdown couldn't distinguish healthy tasks from ones
that needed replanning. Fixing the heuristic restores per-task
variation: empty tasks score 0.0; stalled tasks score proportionally
to the number and severity of problem signals; truly broken tasks
can exceed the replan threshold and produce suggestion events.

---

## [0.9.0] — 2026-04-19

Strategy Registry bootstrap + curation. The substrate existed in 0.8.x
but had a chicken-and-egg problem: registry starts empty → agent
can't emit strategies → registry stays empty → agent never realises
the substrate exists. This release closes that loop and gives the
agent tools to curate its own registry over time.

### Added

- **`seed_strategy` cognitive-loop tool.** The agent can now register
  a new strategy directly when it has a named approach in mind,
  without waiting for Remembrancer pattern mining. Rate-limited to
  5/day — the registry is meant to be a small playbook.
- **Curation tools** (`rename_strategy`, `update_strategy_description`,
  `supersede_strategy`, `archive_strategy`, `list_strategies`). The
  agent can improve its registry without losing the audit trail.
  Supersession merges the old strategy's success/failure counts into
  the successor.
- **Three new event types** (`StrategyRenamed`,
  `StrategyDescriptionUpdated`, `StrategySuperseded`) with append-only
  application logic. The id is immutable (stable reference point);
  name/description/status are mutable through events.
- **Bootstrap sensorium stubs.** When the Strategy Registry or
  Learning Goals are empty, the sensorium now shows a stub block
  pointing at the right tools (`seed_strategy` /
  `propose_strategies_from_patterns`, `create_learning_goal`) instead
  of silent omission. Addresses the "agent doesn't realise the
  substrate exists" failure mode.
- **Soft-cap warning.** `<strategies over_cap="true">` appears when
  the active count exceeds the cap. Signals the agent to archive
  during the fortnightly review.
- **Automatic pruning helpers** (`strategy_log.over_cap`,
  `strategy_log.prune_candidates`). The helpers return
  `StrategyArchived` events for strategies that are sustained-low-
  success or stale; the scheduler-driven review job persists the
  subset the agent approves.
- **Remembrancer `import_legacy_strategy_facts` tool.** One-shot
  migration for facts named `strategy_pattern_*` left over from prior
  manual tracking. Idempotent; dry-run supported.

### Documentation

- **Meta-learning skill rewritten** with a "What a strategy is (and
  isn't)" preamble and a "Day One: the registry is empty" section.
  Sections now named by action ("Naming a strategy when you use one",
  "Curating the registry") instead of assumed steady-state.
- **README gains a "Strategies" subsection** explaining what a
  strategy is and how to populate the registry, in plain English.
- **`docs/architecture/meta-learning.md` Strategy Registry section**
  gains the conceptual framing (what a strategy is, why it's separate
  from facts/skills/CBR cases) at the top.

### Configuration (new `[meta_learning]` fields)

- `strategy_max_active` — soft cap (default 20). 0 disables.
- `strategy_low_success_threshold` — Laplace success rate floor
  (default 0.4).
- `strategy_low_success_min_uses` — min uses before low-success
  pruning fires (default 10; 0 disables).
- `strategy_stale_archive_days` — auto-archive idle strategies
  (default 60; 0 disables).

All documented in both `.springdrift/config.toml` and the example.

### Migration

- **From 0.8.x: no action required.** New tools and sensorium stubs
  appear automatically. Defaults flip on.
- **If you had `strategy_pattern_*` facts from prior manual
  tracking:** invoke the Remembrancer's `import_legacy_strategy_facts`
  once to pull them into the Registry. Idempotent — safe to re-run.

---

## [0.8.2] — 2026-04-19

Patch release. Sandbox-slot recovery + warning sweep.

### Fixed

- **Sandbox slot blocked by root-owned workspace files.** The Python
  container writes `/workspace/run.py` as root (the container's
  default user). When Springdrift on the host (running as the
  operator's UID) tries to overwrite the file on the next code
  execution, `simplifile.write` fails with "Failed to write code to
  workspace" because the operator can't replace a root-owned file.
  `src/sandbox/manager.gleam` now runs `podman exec <container> rm -f
  /workspace/<filename>` immediately before the write — root-inside-
  container removes the previous file, then Springdrift's write
  creates a fresh one. Applied to both `execute_in_slot` (run_code
  path) and `serve_in_slot` (long-lived process path). Errors from
  the pre-clear are intentionally ignored (the file may not exist on
  first run).
- **Removed unused `type Strategy` import** in
  `test/strategy/log_test.gleam` — the only project-side warning
  flagged by Gleam 1.15.4.

### Migration

- Existing stale workspace files (root-owned `run.py` left over from
  pre-0.8.2 cycles) are cleared automatically next time the slot is
  used. No operator action needed.

---

## [0.8.1] — 2026-04-19

Patch release. Two small fixes flagged after 0.8.0 cut.

### Changed

- **`agent_version` now reads from the package metadata.** New FFI
  `springdrift_ffi:package_version/0` calls `application:get_key/2`,
  which Gleam derives from `gleam.toml`. The default is now the
  current build's version (`0.8.1` after this release). Operators
  can still override via `[agent] version = "..."` in `config.toml`
  to label a specific deployment. The hardcoded
  `version = "Springdrift Mk-3"` line was removed from both the live
  and example config files.

### Fixed

- **README web GUI port** corrected from `8080` to `12001` (the actual
  default in `src/springdrift.gleam`). The 8080 reference was
  introduced inadvertently in 0.8.0's docs rewrite.

---

## [0.8.0] — 2026-04-19

First semver release. Supersedes the prototype `Mk-1`–`Mk-4` tags. The
project now publishes a parseable version string and a changelog so
downstream tooling and operators can tell what changed between deploys.

### Added

- **Skills as a managed substrate.** Skills are no longer static
  `SKILL.md` files only. They have a structured `skill.toml` sidecar
  carrying versioning, scoping, provenance, and metrics. The agent's
  Remembrancer can mine recurring CBR clusters and propose new skills,
  which pass through a four-layer Promotion Safety Gate (deterministic
  rules + rate limit + same-scope cooldown + LLM conflict classifier
  + D' scorer) before becoming Active. Lifecycle log at
  `.springdrift/memory/skills/`.
- **Meta-learning subsystem.** The agent reviews its own work without
  being prompted: weekly consolidation reports, daily learning-goal
  reviews, weekly affect-vs-outcome correlation analysis, weekly
  skill-decay audits, and fortnightly strategy reviews. Defaults are
  on; configure via `[meta_learning]` in `config.toml`. Architecture
  detail in `docs/architecture/meta-learning.md`.
- **Strategy Registry.** Named, reusable approaches with tracked success
  rates. The Remembrancer can mine them from CBR clusters; the Curator
  surfaces top performers in the sensorium.
- **Learning Goals Store.** Self-directed objectives with rationale,
  acceptance criteria, optional strategy link, affect baseline. Three
  cognitive-loop tools (`create_learning_goal`, `update_learning_goal`,
  `list_learning_goals`); the Observer's `review_learning_goals` returns
  goals for independent assessment without changing status.
- **Affect-Performance Engine.** Pearson correlations between affect
  dimensions (desperation, calm, confidence, frustration, pressure)
  and outcome success per task domain. Significant negative
  correlations surface in the sensorium and feed the input D' gate
  as risk context.
- **Web GUI Memory tab.** Lists Remembrancer consolidation runs with
  counts, decayed-fact / dormant-thread snapshots, and report paths.
  Click a row for the full summary.
- **Skill metrics + audit panel.** Per-skill JSONL of read / inject /
  outcome events. Web GUI Skills tab shows discovered skills, usage
  stats, last-used timestamps, and today's proposal-log events.
- **`meta-learning` agent skill** teaching the cognitive loop how to
  use the substrate as decision procedure rather than passive reference.
- **`<skill_procedures>` sensorium block** mapping action classes to
  the skill the agent should consult before acting.
- **Persona rule** that skills are decision procedures, to be read via
  `read_skill` before acting, not relied on from working memory.

### Changed

- **Default `[meta_learning] scheduler_enabled` is True.** New installs
  get the auto-firing self-review loop. Operator opts out via config.
- **PM agent** gained `complete_task_step` (the gap that meant the agent
  could create tasks but not mark steps done).
- **Persona** rewritten in first person consistently. The Curator was
  occasionally letting "you" leak in when the agent reported on its own
  state — fixed.
- **README "Meta-Learning" section** rewritten in plain English. The
  technical depth moved to `docs/architecture/meta-learning.md`.

### Fixed

- **Email signoff** uses the agent's `agent_name`, not the framework
  name "Springdrift". Curragh-the-instance is "Curragh"; Springdrift
  is the framework.
- **Observer false-classification** of `detect_patterns` as a
  delegation-tool failure (it correctly lives on Observer, not
  cognitive).
- **Pre-Phase-A JSONL** continues to decode cleanly: `NarrativeEntry`
  and `CbrCase` got new optional fields with backward-compatible
  decoders defaulting to `None`.

### Documentation

- New `docs/architecture/meta-learning.md` — full developer/operator
  reference for the new substrate.
- README refreshed — Meta-Learning section, Web GUI tab list, no
  internal release jargon.
- `docs/engineering-log.md` gains a substantial entry for the
  Phase A–F build (chronological history with design decisions).
- Every meta-learning configuration switch surfaced and documented in
  both `.springdrift/config.toml` (live) and
  `.springdrift_example/config.toml` (template).

### Migration notes

- No code changes required. New optional `[meta_learning]` config
  block; defaults are on. Set `scheduler_enabled = false` to keep the
  pre-0.8 behaviour where introspection happens only when prompted.
- Prototype `Mk-1` through `Mk-4` git tags remain in place for
  history. New release tags follow semver: `v0.8.0`, `v0.8.1`, ...

---

## Pre-0.8.0 — `Mk-1` to `Mk-4`

Prototype-era milestones tagged informally. The framework was under
heavy iteration and we made no compatibility promises across these.
For the technical record of what shipped when, see
`docs/engineering-log.md`.
