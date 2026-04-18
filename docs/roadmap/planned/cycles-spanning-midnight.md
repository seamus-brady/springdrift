# Cycles Spanning Midnight — Bind Cycle Events to Cycle Start Date

**Status**: Planned
**Priority**: Low — rare in practice, cosmetic data loss
**Effort**: Small-to-medium (~80-150 lines + careful tests)

## Problem

Both `cycle_log.gleam` and `narrative/log.gleam` write to date-rotated JSONL
files (`YYYY-MM-DD.jsonl`). Each append re-reads the system clock at write
time and routes the line to whatever the current day is.

A cycle that starts at 23:55 and finishes at 00:05 splits across two files:

- The `human_input` event lands in day N
- Some `tool_call` / `llm_response` events land in day N
- Later events land in day N+1
- The narrative entry written by the Archivist after the cycle reply lands
  in day N+1

Consequences:

- The history-day view (`load_cycles_for_date`) shows a partial cycle for
  either day. Yesterday's view is missing the conclusion; today's view
  starts mid-cycle with no human input.
- The narrative for that cycle appears under the wrong day in the history
  sidebar headline / count.
- Downstream tools (CBR archivist, pattern detection, audits) that group
  by date will see a fractured cycle.

In practice cycles are usually sub-minute, so this is rare. Worth fixing
once long-running endeavour cycles or paused-then-resumed cycles become
common.

## Proposed Solution

### 1. Capture `cycle_started_date` once per cycle

When a cycle begins (in `cognitive/cycle.gleam` and the agent framework's
react loop), capture `get_date()` once and pin it to the cycle context.
For nested agent cycles, inherit the parent's start date so a delegation
that crosses midnight still groups under one day.

### 2. Thread it through the logging API

Update the `cycle_log.log_*` family to accept an explicit `date: String`
argument instead of computing it internally. The cognitive loop and agent
framework pass the cycle's pinned start date to every log call.

```gleam
pub fn log_human_input(
  cycle_id: String,
  cycle_date: String,   // <-- new
  parent_id: Option(String),
  text: String,
  redact: Bool,
) -> Nil {
  ...
  simplifile.append(log_path_for(cycle_date), ...)
}
```

Same shape for `log_llm_request`, `log_llm_response`, `log_tool_call`,
`log_tool_result`, etc. The internal `log_path()` becomes
`log_path_for(date: String)`.

### 3. Same treatment for narrative log

`narrative/log.gleam` currently calls `get_date()` inside `append`. Take
a `cycle_date` from the caller (Archivist) so the narrative entry lands
in the cycle's start-day file even if the Archivist runs after midnight.

### 4. Migration

No on-disk format change — files are still `YYYY-MM-DD.jsonl`, lines are
still the same shape. Old logs already on disk stay where they are; only
new writes route differently.

## Trade-offs

- **Pro**: a cycle is always whole within one file. History view is
  trustworthy. Date-based aggregations are correct.
- **Con**: a cycle that starts at 23:59 and runs for 8 hours writes 8
  hours of events to "yesterday's" file. Slight surprise for the operator
  if they look at file mtimes vs filename dates. Mitigation: file mtime
  shows real wallclock, filename shows logical-cycle date.
- **Con**: minor API churn — all `log_*` functions gain a parameter.
  Compiler-enforced so easy to migrate, but touches every call site.

## Out of Scope

- Backfilling existing split cycles. Not worth the effort; old logs are
  what they are.
- Timezone handling. The agent runs in the system timezone and uses
  whatever `get_date()` returns. UTC vs local stays unchanged.

## Related

- `src/cycle_log.gleam:40-41` — `log_path()` recomputes date per write
- `src/narrative/log.gleam:35-44` — same pattern in `append`
- `src/web/gui.gleam:617-647` — `RequestChatHistoryDay` reads
  `load_cycles_for_date(date)` which surfaces the split
