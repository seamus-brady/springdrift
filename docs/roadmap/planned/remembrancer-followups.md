# Remembrancer — Follow-up Work

**Status**: Planned
**Parent**: `docs/roadmap/implemented/remembrancer.md` (Phases 1–10 shipped 2026-04-16)
**Dependencies**: Skills management (planned) for item 1; self-contained for 2–4.

This captures the work deferred from the original Remembrancer roadmap so it does not get lost.

---

## 1. Skills-proposal pipeline (Phase 11) — BLOCKED

When `mine_patterns` finds recurring approaches or pitfalls across CBR cases, those clusters should become proposed Skills — not just paragraphs in a consolidation report.

**Blocked by**: `docs/roadmap/planned/skills-management.md`. That spec needs to ship first — it defines the `Skill` type with effectiveness metrics, the skill.toml sidecar format, and the approval pipeline.

**Remembrancer work required once unblocked:**
- Add a `propose_skill` tool (or extend `mine_patterns`) that emits a proposed skill with supporting case IDs to the skills inbox.
- The operator reviews and approves/rejects via the web GUI.
- Approved skills become live SKILL.md files.

Until skills management ships, the current behaviour (describe the pattern in the consolidation report) is sufficient — the operator reads the report and can manually codify a skill if warranted.

---

## 2. TOML-driven scheduled consolidation (Phase 9 completion)

The original design referenced a `[[task]]` block in a profile's `schedule.toml`:

```toml
[[task]]
name = "weekly-consolidation"
kind = "recurring"
interval_ms = 604800000
query = "Run memory consolidation for the past week..."
```

This format is defined in `src/scheduler/types.gleam` (`ScheduleTaskConfig`) but no loader currently reads it at startup — jobs are only created at runtime via the scheduler agent's `schedule_from_spec` tool.

**Work required:**
- Implement a `schedule.toml` loader (probably in `src/scheduler/config.gleam` or as part of `profile.gleam`).
- Call it at startup and pass resulting jobs into `scheduler_runner.start`.
- Ship a default `schedule.toml` with the weekly consolidation entry.

**Workaround until then:** the operator asks the scheduler agent to create a weekly recurring job that delegates to the Remembrancer. The Remembrancer can be invoked any time by the cognitive loop or the operator.

---

## 3. Web GUI Memory Health panel (Phase 10 completion)

The spec called for a dedicated admin-page tab showing memory depth, last consolidation time, pending pattern proposals, and action buttons. Currently only the sensorium tag is rendered.

**Work required:**
- New admin tab in `src/web/html.gleam` ("Memory") with:
  - Memory depth stats (narrative entries/CBR cases/facts, oldest entry date)
  - Decayed fact count + dormant thread count (requires computing these)
  - Consolidation run history (from `.springdrift/memory/consolidation/`)
  - Pattern-proposal queue (requires Phase 11)
  - Timeline view of activity density + consolidation events
  - Action buttons: "Run Consolidation" / "Mine Patterns" / "Find Dormant Threads"
- WebSocket messages for `RequestMemoryHealth` / `MemoryHealthData` in `src/web/protocol.gleam`.
- Librarian queries for the expensive counts (probably cached).

**Estimate:** Medium. About 200–300 lines in `web/html.gleam` + `protocol.gleam` + a small handler in `web/gui.gleam`.

---

## 4. Richer sensorium memory attributes — DONE (2026-04-17, commit 3f4d5b7)

Shipped. `ConsolidationRun` now carries `decayed_facts_count` and `dormant_threads_count`, computed at write time from `facts_log.resolve_current` (with `decay.decay_fact_confidence`) and `rquery.find_dormant_threads` respectively. The sensorium `<memory>` tag renders both attributes. Snapshots go stale as consolidation falls behind — the right signal, prompts re-consolidation.

---

## 5. Remembrancer-authored fact-provenance improvements — DONE (2026-04-17, commit 6dbb171)

Shipped. `restore_confidence` now looks up the current fact via `facts_log.resolve_current` and populates `supersedes: Some(old_fact_id)` when a prior version exists. The success message and slog entry both name the superseded ID (or note "no prior version"). 4 unit tests cover the paths.
