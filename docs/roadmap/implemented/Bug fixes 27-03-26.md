# Bug Fixes — 2026-03-26 / 2026-03-28

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

### 8. Root cycle DAG nodes permanently "pending" with 0/0 tokens

**Severity:** High — root cycles never finalised when D' gates active.
Cycles appeared permanently "pending" with 0/0 tokens in `reflect`,
`list_recent_cycles`, and `inspect_cycle`. The agent couldn't see its
own cycle telemetry. Diagnosed by Curragh itself on March 28.

**Root cause:** Same class of bug as the Archivist (#2) — the output gate
delivery paths in `safety.gleam` (Accept, Modify-max, Reject,
check_deterministic_only) were missing `UpdateNode` calls that the no-gate
path in `cognitive.gleam` had. LLM usage data was also lost because
`CognitiveReply` sent `usage: None` from all gate paths.

**Fix:**
- Added `pending_output_usage: Option(Usage)` to `CognitiveState`
- Added `finalise_dag_node` helper in `safety.gleam`
- Updated all 4 delivery paths to call `finalise_dag_node` and pass usage
- Agent sub-cycles were unaffected (framework handles them separately)

### 8b. Input gate structural injection false positive on operator content

**Severity:** High — operator pasting README text (which discusses injection
detection) triggered deterministic structural injection block at score 1.0.
The README contained boundary markers (---), imperative verbs (ignore,
override), and system targets (safety rules, previous instructions) — all
describing what the system defends against, not actual injection.

**Root cause:** `detect_structural_injection` and `detect_payload_signatures`
are heuristic detectors designed for untrusted external content. They
false-positive heavily on technical documentation about the system itself.

**Fix:** Added `check_input_interactive` to `dprime/deterministic.gleam`.
Interactive input runs only configured regex rules (operator-defined).
Structural injection heuristics and payload signature detection are skipped.
Autonomous (scheduler) input still gets the full check.

### 8c. Comms agent worker crash — undefined FFI function

**Severity:** Medium — `get_timestamp` FFI function didn't exist (correct
name is `get_datetime`). Worker crashed after successful email send.

**Fix:** Changed FFI reference from `get_timestamp` to `get_datetime`.

### 8d. Comms agent inbox decode errors

**Severity:** Medium — AgentMail returns `to` as an array of strings, not a
single string. Strict `decode.field` on `message_id`/`thread_id` failed
when fields were missing or null.

**Fix:** All decoders made lenient with `optional_field`. `to` decoded as
`List(String)` and joined. `cycle_id` uses `decode.optional(decode.string)`
for null handling.

### 8e. Comms poller creating duplicate entries

**Severity:** Medium — poller re-processed same messages every tick because
it only tracked the last seen ID, not all seen IDs. On restart, seen set
was empty so everything re-processed.

**Fix:** Track `seen_ids` as `Set(String)` capped at 200. Seed from JSONL
on startup. Web admin comms tab deduplicates by message_id.

### 8f. Comms inbox_id required manual lookup

**Severity:** Low (UX) — users had to find their AgentMail inbox UUID from
the dashboard. Config `inbox_id` field was confusing.

**Fix:** Added `resolve_inbox_id` to `comms/email.gleam` — lists inboxes
and matches by email address. Resolved automatically at startup from
`from_address`. Manual `inbox_id` still works as override.

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
