# Metacognition Reporting — Design Spec

## Problem

Springdrift has three layers of metacognition that generate valuable signal but
lack persistent, queryable reporting:

1. **D' gate decisions** — input/tool/output gate verdicts with scores, forecasts,
   explanations. Currently logged to cycle-log JSONL but only queryable via
   `reflect`/`inspect_cycle` tools (per-cycle, not aggregated).

2. **Normative calculus** — virtue-based verdicts with axiom trails, conflict
   resolution details. Currently in output gate explanation strings and cycle-log
   entries. Drift state is in-memory only (lost on restart).

3. **Meta observer** — Layer 3b signals (rate limits, cumulative risk, rejections,
   false positives, virtue drift). Interventions logged but signal history is
   in-memory MetaState (partially restored from JSONL on restart via meta/log.gleam).

**What's missing:**
- No aggregated view of gate decisions over time (trends, distributions)
- Normative drift state doesn't persist across sessions
- No way to see "what has the normative calculus been doing?" without digging
  through cycle logs
- No operator dashboard for metacognition health
- Character spec effectiveness is invisible — are the NPs actually useful?
- The agent can't self-report on its own metacognitive patterns

## Reporting Surfaces

### 1. Normative Drift Persistence

**Current state:** `DriftState` lives on `CognitiveState`, lost on restart.

**Proposed:**
- Add `normative/log.gleam` — append-only JSONL for normative verdicts
  (`.springdrift/memory/normative/YYYY-MM-DD-verdicts.jsonl`)
- Each entry: `{cycle_id, timestamp, verdict, floor_rule, axiom_trail, dprime_score,
  conflict_count, non_trivial_conflicts}`
- Librarian replays on startup to rebuild `DriftState` (same pattern as facts, CBR)
- Drift signals also logged: `{cycle_id, timestamp, signal_type, description,
  drifting_axiom}`

**Benefit:** Drift detection works across sessions. Operator can `grep` the file.

### 2. Gate Decision Aggregation

**Current state:** Gate decisions logged per-cycle in cycle-log. `reflect` tool
gives day-level stats but only for cycles, tokens, models — not gate decision
distributions.

**Proposed:**
- Extend `reflect` tool (or add `reflect_safety`) to report:
  - Gate decision distribution: accept/modify/reject counts per gate type
  - Average D' score per gate type
  - Top firing features (which features most often score ≥2)
  - Normative verdict distribution (when enabled): flourishing/constrained/prohibited
  - Axiom frequency: which axioms fire most often
  - Drift signal count and types
- Data source: Librarian queries over cycle-log + normative verdict log

**Benefit:** Agent can self-report. Operator can ask "how has safety been today?"

### 3. Character Spec Effectiveness

**Current state:** No feedback loop from verdicts back to character spec evaluation.

**Proposed:**
- Track per-NP engagement: how often does each highest_endeavour NP participate
  in a non-trivial conflict?
- NPs that never fire are dead weight in the system prompt
- NPs that fire on every cycle may be miscalibrated
- Report: `{np_description, conflict_count, coordinate_count, superordinate_count,
  last_fired_at}`
- Accessible via a memory tool (`recall_character_health` or similar)

**Benefit:** Operator knows which NPs to tune, add, or remove.

### 4. Web Admin Dashboard

**Current state:** Web admin has 4 tabs (Narrative, Log, Scheduler, Cycles).
No metacognition tab.

**Proposed:**
- Add "Safety" tab to web admin with:
  - Gate decision timeline (sparkline or bar chart per hour/day)
  - Current normative calculus status (enabled, character spec loaded, virtue count)
  - Drift state summary (current window, last signal, constraint/prohibition rates)
  - Active meta observer signals and pending interventions
  - Character spec NP engagement table
- Data via new WebSocket messages (`RequestSafetyData`/`SafetyData`)

**Benefit:** Operator can monitor metacognition health at a glance.

### 5. Sensorium Integration (Already Partially Done)

**Current state:** Drift signals emit sensory events. Meta-states (uncertainty,
prediction_error, novelty) are in vitals.

**Remaining:**
- Add `virtue_drift` attribute to `<vitals>` when drift is detected (persistent
  until cleared, not just per-event)
- Add `normative_verdicts` attribute showing recent verdict distribution
  (e.g. `"F:18 C:2 P:0"`) so the agent has ambient awareness
- Consider: should the agent see the character spec NP engagement data in the
  sensorium? (Probably too verbose — better as a tool)

### 6. Narrative Integration

**Current state:** Archivist generates narrative entries per cycle but doesn't
capture normative reasoning.

**Proposed:**
- When normative calculus fires, include in the Archivist's context:
  - Verdict and floor rule
  - Non-trivial conflicts and their axiom trails
  - Whether drift was detected
- This means the agent's narrative memory will contain normative reasoning
  records — "I constrained my output because axiom 6.3 (moral priority) fired
  on an intellectual honesty concern"
- CBR cases from normative-gated cycles could capture the NP configuration
  that led to the outcome

**Benefit:** The agent can learn from its own normative history via recall/CBR.

## Missing Layers

### Layer 3a Meta (Intra-Gate) — Already Exists
Stall detection + threshold adaptation within a single gate evaluation.
Reporting gap: tightening events are not surfaced outside the gate.

### Layer 3b Meta (Cross-Cycle) — Already Exists
Post-cycle observation with 5 detectors + virtue drift.
Reporting gap: signal history is partially persistent (meta/log.gleam) but
not queryable by the agent.

### Layer 4: Cross-Session Meta — Missing
No mechanism to detect patterns across sessions. Examples:
- "The last 3 sessions all had high constraint rates on the same feature"
- "Character spec was changed 2 sessions ago and prohibition rate dropped"
- "This query type consistently triggers the same axiom"

**Proposed:** Normative verdict persistence (§1 above) enables this. A periodic
summary (like narrative summaries) could aggregate cross-session normative
patterns. The Forecaster pattern (self-ticking actor) could be reused.

### Layer 5: Operator Feedback Loop — Missing
No structured way for the operator to say "this normative decision was wrong"
beyond `report_false_positive` (which is D'-specific, not normative-specific).

**Proposed:**
- Add `report_normative_override` tool — operator flags a verdict as incorrect
  with reason
- Overrides persist to JSONL, excluded from drift statistics (same pattern as
  false positive annotations)
- High override rate → escalate (same as high FP rate detector)
- Overrides feed into character spec effectiveness tracking

## Implementation Priority

| Item | Effort | Impact | Priority |
|---|---|---|---|
| Normative drift persistence (§1) | Small | High — enables everything else | 1 |
| Gate decision aggregation tool (§2) | Medium | High — agent self-awareness | 2 |
| Sensorium verdict summary (§5) | Small | Medium — ambient awareness | 3 |
| Character spec effectiveness (§3) | Medium | Medium — tuning feedback | 4 |
| Narrative integration (§6) | Medium | Medium — long-term memory | 5 |
| Web admin Safety tab (§4) | Large | Medium — operator UX | 6 |
| Operator feedback tool (Layer 5) | Small | Medium — closes human loop | 7 |
| Cross-session meta (Layer 4) | Large | Low (until enough data) | 8 |

## Dependencies

```
§1 Normative drift persistence
 ├──► §2 Gate decision aggregation (needs verdict data)
 ├──► §3 Character spec effectiveness (needs per-NP stats)
 ├──► §4 Web admin (needs queryable data)
 └──► Layer 4 Cross-session (needs historical verdicts)

§5 Sensorium integration — independent, small
§6 Narrative integration — independent, medium
Layer 5 Operator feedback — needs §1 for override tracking
```
