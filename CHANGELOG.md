# Changelog

All notable changes to Springdrift are recorded here.

The project follows [Semantic Versioning](https://semver.org/) starting from
0.8.0. Releases on `0.x.y` are not API-stable — breaking changes can land in
any minor bump until 1.0.0. Patch releases (`0.8.1`, `0.8.2`, ...) are
backwards-compatible bug fixes only.

For implementation history beyond what's user-visible, see
`docs/engineering-log.md`.

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
