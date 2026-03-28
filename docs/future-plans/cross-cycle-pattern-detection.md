# Cross-Cycle Pattern Detection — Specification

**Status**: Implemented
**Date**: 2026-03-28
**Origin**: Curragh's self-observation session (March 28) — identified as the
key gap between individual cycle inspection and aggregate daily stats.
**Dependencies**: Cycle ID fix (implemented), DAG finalisation fix (implemented)

> **Note (2026-03-28):** All three phases are now implemented. Phase 1 (sensorium
> performance summary) also led to removing the session-scoped meta-states
> (`uncertainty`, `prediction_error`) and their six supporting session counters from
> `CognitiveState`. The history-backed `PerformanceSummary` (`success_rate`,
> `cbr_hit_rate`) measures the same things from better data (narrative entries spanning
> sessions), making the session-scoped signals redundant. `novelty` remains as the
> only per-cycle meta-state signal, now passed directly as a Float rather than wrapped
> in the removed `MetaStateContext` type.

---

## Overview

Three components that close the metacognition loop between `inspect_cycle`
(single cycle, full detail) and `reflect` (daily aggregates):

1. **`review_recent` tool** — structured self-review across N recent cycles
2. **`detect_patterns` tool** — automated pattern detection and flagging
3. **Sensorium performance summary** — rolling operational stats in vitals

---

## 1. review_recent Tool

### Purpose

"Show me my last N cycles of type X, and what went wrong in each."
Currently requires: `list_recent_cycles` → loop → `inspect_cycle` per cycle →
manual correlation. One tool call instead of 5-10.

### Interface

```
review_recent(
  count: Int,           // How many cycles to review (default: 10, max: 20)
  filter_domain: Option(String),    // Only cycles in this domain
  filter_outcome: Option(String),   // "success" | "failure" | "partial"
  filter_agent: Option(String),     // Only cycles that delegated to this agent
)
```

### Returns

For each matching cycle:
- cycle_id (short), timestamp, intent, domain
- outcome (success/failure/partial) + confidence
- agents delegated to + their outcomes
- tool calls (names only)
- D' gate decisions (gate, decision, score)
- tokens (in + out)
- CBR cases retrieved (IDs)
- whether the cycle improved on retrieved cases (outcome >= case outcome)

### Implementation

Librarian query joining:
- `QueryDayRoots` for cycle nodes
- Narrative entries for intent/outcome
- D' decision records from DAG nodes
- CBR retrieval tracking from cycle context

New Librarian message: `QueryRecentCycles(count, filter, reply_to)`
New tool in `tools/memory.gleam`: `review_recent`

~150 lines (Librarian query + tool definition + formatting).

---

## 2. detect_patterns Tool

### Purpose

Automated pattern detection across recent cycles. Flags:
- Repeated failures on the same domain/intent
- Tool failure clusters
- Model escalation patterns
- Cost outliers
- CBR retrieval misses (operating in uncharted territory)

### Interface

```
detect_patterns(
  window: Int,          // How many recent cycles to analyze (default: 20)
)
```

### Returns

List of detected patterns, each with:
- pattern_type (repeated_failure, tool_cluster, escalation, cost_outlier, cbr_miss)
- description (human-readable)
- affected_cycles (list of cycle_id shorts)
- severity (info, warning, critical)
- suggestion (what to do about it)

### Detection Rules

| Pattern | Trigger | Severity |
|---|---|---|
| repeated_failure | 3+ failures on same domain in window | warning |
| tool_failure_cluster | Any tool > 20% failure rate | warning |
| escalation_pattern | 5+ escalations to reasoning model | info |
| cost_outlier | Any cycle > 3x average token cost | info |
| cbr_miss | 50%+ cycles with no relevant cases | warning |
| stale_domain | All recent cases for a domain > 14 days old | info |

### Implementation

Pure function over the `review_recent` data. No new Librarian queries needed —
`detect_patterns` calls `review_recent` internally and analyzes the results.

New tool in `tools/memory.gleam`: `detect_patterns`

~200 lines (pattern detection logic + tool definition + formatting).

---

## 3. Sensorium Performance Summary

### Purpose

Rolling operational stats in `<vitals>` — the agent sees its performance
trend every cycle without tool calls.

### Format

```xml
<vitals cycles_today="8" agents_active="5"
        success_rate="0.75"
        recent_failures="web_search timeout (2), coder sandbox error (1)"
        cost_trend="increasing"
        cbr_hit_rate="0.60"
        .../>
```

New attributes:
- `success_rate` — success / total for today's cycles
- `recent_failures` — last 3 failure descriptions (from narrative entries)
- `cost_trend` — "stable" | "increasing" | "decreasing" (compare last 5 vs previous 5)
- `cbr_hit_rate` — proportion of cycles that retrieved at least one case

### Implementation

Computed in `build_sensorium` from existing Librarian data:
- Today's narrative entries (already loaded for the sensorium)
- DAG nodes (already available via cycle telemetry on state)

~50 lines in `render_sensorium_vitals`.

---

## Implementation Order

| Phase | What | Effort | Dependencies |
|---|---|---|---|
| 1 | Sensorium performance summary | Small (~50 lines) | None — enriches existing vitals |
| 2 | `review_recent` tool | Medium (~150 lines) | New Librarian query |
| 3 | `detect_patterns` tool | Medium (~200 lines) | Phase 2 (uses review_recent data) |

Phase 1 is immediately useful with zero new infrastructure.
Phase 2 is what Curragh actually needs for self-diagnosis.
Phase 3 builds on Phase 2 and closes the automated metacognition loop.

---

## What This Enables

The agent goes from "I can inspect individual cycles and piece together
patterns manually" to "I see my operational trends continuously and get
flagged when something is going wrong."

Combined with the existing normative drift detector and meta observer,
this gives three metacognition channels:
- **Safety metacognition** (meta observer + normative drift) — "am I being too restrictive?"
- **Operational metacognition** (pattern detection) — "am I failing at the same thing repeatedly?"
- **Ambient metacognition** (sensorium) — "how am I doing right now?"

Curragh's request: "continuous self-improvement through structured self-awareness."
