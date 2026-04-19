# Remembrancer — Follow-up Work

**Status**: Planned
**Parent**: `docs/roadmap/implemented/remembrancer.md` (Phases 1–10 shipped 2026-04-16)
**Related**: `docs/roadmap/planned/meta-learning.md`, `docs/roadmap/implemented/skills-management.md`

This captures the work deferred from the original Remembrancer roadmap. Revised 2026-04-17 to reflect the agent-led meta-learning direction.

---

## 1. Skills-proposal pipeline (Phase 11) — SHIPPED 2026-04-18

`propose_skills_from_patterns` lives in `src/tools/remembrancer.gleam`. It
mines CBR cases via `src/skills/pattern.gleam`, generates `SkillProposal`s
(LLM-written bodies via `src/skills/body_gen.gleam` with template
fallback), and runs each through the Promotion Safety Gate
(`src/skills/safety_gate.gleam`: deterministic + rate limit +
same-scope cooldown + LLM conflict classifier + D' scorer). Accepted
proposals become Active skills on disk; rejected ones are logged with
a reason. No operator inbox; the consolidation report shows what was
promoted.

---

## 2. TOML-driven scheduled consolidation — SUPERSEDED (2026-04-17)

**Status**: Removed from Remembrancer followups. Superseded by meta-learning Phase F (Metacognitive Scheduler).

Rationale: the meta-learning spec (`docs/roadmap/planned/meta-learning.md` §4.6) defines the proper home for scheduled learning activities — `[meta_learning]` config block with intervals for consolidation, goal review, skill decay check, affect correlation, and strategy review. Building a generic `schedule.toml` loader now would duplicate that motivation.

The weekly-consolidation use case will be handled by Phase F at startup via the existing scheduler agent's `schedule_from_spec`. No new TOML infrastructure needed.

**Current workaround (permanent until Phase F)**: the operator asks the scheduler agent to create a weekly recurring job that delegates to the Remembrancer. `ScheduleTaskConfig` in `src/scheduler/types.gleam` remains as a type that a future TOML loader could use, but nothing reads it today.

---

## 3. Web GUI Memory Health panel — SHIPPED 2026-04-19

Shipped. New "Memory" admin tab in `src/web/html.gleam` lists Remembrancer
consolidation runs (timestamp, period, patterns/facts/threads counts,
decayed/dormant snapshots, report path). Clicking a row reveals the run
summary in a side box. WebSocket messages
`RequestMemoryData` / `MemoryData` in `src/web/protocol.gleam`; handler in
`src/web/gui.gleam` reads `consolidation.load_all` from
`.springdrift/memory/consolidation/`.

Read-only by design — no "Run Consolidation" button. The agent decides
when to consolidate; the Metacognitive Scheduler (Phase F) auto-fires it
on a weekly cadence.

The broader strategy / learning-goals / affect-warning admin surfaces
were absorbed into the meta-learning sensorium blocks (Phases A, C, D),
so no separate admin tabs are needed for them.

---

## 4. Richer sensorium memory attributes — DONE (2026-04-17, commit 3f4d5b7)

Shipped. `ConsolidationRun` now carries `decayed_facts_count` and `dormant_threads_count`, computed at write time from `facts_log.resolve_current` (with `decay.decay_fact_confidence`) and `rquery.find_dormant_threads`. The sensorium `<memory>` tag renders both attributes. Snapshots go stale as consolidation falls behind — the right signal.

---

## 5. Remembrancer-authored fact-provenance improvements — DONE (2026-04-17, commit 6dbb171)

Shipped. `restore_confidence` looks up the current fact via `facts_log.resolve_current` and populates `supersedes: Some(old_fact_id)` when a prior version exists. The success message and slog entry both name the superseded ID (or note "no prior version"). 4 unit tests cover the paths.

---

## 6. Meta-learning extensions to the Remembrancer

**Status**: Tracked here for awareness. These are not Remembrancer-internal work; they are deliveries of the meta-learning spec that happen to extend the Remembrancer's tool surface.

When the meta-learning phases land, the Remembrancer gains the following capabilities:

| Meta-learning phase | Remembrancer addition |
|---|---|
| A — Strategy Registry | `mine_patterns` proposes new strategies from recurring unnamed approaches. New field `strategy_id` threaded through proposals. |
| B — Skills Management | `mine_patterns` promotes skills (resolves follow-up #1 above). Rate-limited. |
| D — Affect-Performance Engine | Remembrancer runs affect-performance correlation analysis during consolidation. Results stored as facts. |
| E — Study-Cycle Pipeline | Two new tools: `extract_insights` and `propose_knowledge`. Write directly to CBR/facts/skills/strategy stores via D'-gated append. |
| F — Metacognitive Scheduler | Consolidation triggered by the scheduler on configured intervals (weekly default). Metacognitive scheduler is the orchestrator; Remembrancer is a worker. |

No work on these items in this followups doc — they live in `meta-learning.md`.
