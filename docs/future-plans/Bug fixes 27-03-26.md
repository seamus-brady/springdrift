# Bug Fixes — 2026-03-26

## Fixed

### 1. CBR retrieval weights sum to 1.15, not 1.0

**Severity:** Medium — corrupts retrieval ranking normalization.

`cbr/bridge.gleam::default_weights()` had weights summing to 1.15:
0.35 + 0.25 + 0.15 + 0.15 + 0.10 + 0.15 = 1.15

**Fix:** Adjusted to 0.30 + 0.20 + 0.15 + 0.15 + 0.10 + 0.10 = 1.00.

### 2. Archivist never called when D' gates active

**Severity:** Critical — narrative entries and CBR cases stopped being
generated when any D' gate was enabled. The entire memory pipeline was
silently disconnected.

The Archivist was only called from the `None` (no output gate) path in
`cognitive.gleam`. The output gate Accept, Modify-max-exceeded, and
deterministic-only delivery paths in `safety.gleam` all skipped it.

**Fix:** Added `cognitive_memory.maybe_spawn_archivist()` to all three
delivery paths in `safety.gleam`.

### 3. Output gate LLM scorer running on interactive sessions

**Severity:** High — false positives on conversational replies caused the
agent to self-censor. The same LLM scorer applied research report standards
to all output, destroying good responses.

**Fix:** Interactive/autonomous split. Interactive sessions use deterministic
rules only. Autonomous (scheduler) cycles get full LLM scorer + normative
calculus.

### 4. Input gate LLM scorer running on interactive escalations

**Severity:** High — deterministic escalation rules (e.g. "act as|pretend you")
triggered full LLM scoring on benign operator input. Operator discussing
system internals was flagged as dangerous at score 1.00.

**Fix:** Same interactive/autonomous split applied to the input gate. Interactive
escalations now skip the LLM scorer and go straight to canaries + fast-accept.

### 5. Gate injection messages persisting to session

**Severity:** Medium — MODIFY/REJECT notices baked into session.json caused
the agent to self-censor on resumed sessions (feedback loop).

**Fix:** `filter_gate_injections` in `cognitive/memory.gleam` strips gate
messages before saving. Rejection notices made terse (decision + score +
triggers only).

### 6. Web admin narrative tab stuck on loading

**Severity:** Low — `ws.onopen` didn't request data for the default active tab.

**Fix:** Auto-request data for the active tab on WebSocket connect.

### 7. Web admin narrative showing stale data

**Severity:** Low — Librarian ETS cache missing entries that were on disk.

**Fix:** Narrative tab now reads from disk directly (JSONL is source of truth).
Capped at 50 most recent entries.

## Acknowledged — Deferred

### 8. Legacy scaling_unit function mathematically incorrect

**Severity:** Low — function is unused by compute_dprime (which uses
max_possible_score). Only referenced by legacy tests.

**Status:** Marked DEPRECATED in source. Tests retained. Will remove in a
future cleanup pass.

### 9. compile_schema writes XSD to disk on every generate call

**Severity:** Low (performance) — schemas are static strings written to the
same path every time. File system caches the writes. The proper fix is to
compile schemas once at startup and thread SchemaState through all call sites.

**Status:** Acknowledged. Deferred — requires refactoring 8 call sites to
accept pre-compiled SchemaState. I/O cost is negligible due to OS-level caching.

### 10. Sub-agent control inversion via request_human_input

**Severity:** Medium (design risk) — sub-agent's request_human_input injects
into the prime agent's loop as if it were user input. Diagnosed by Curragh
itself as an "architectural vulnerability."

**Status:** Structural fix (tag messages with origin, apply trust levels at
input boundary) is planned. Requires changes to CognitiveMessage variants
and the input processing path.
