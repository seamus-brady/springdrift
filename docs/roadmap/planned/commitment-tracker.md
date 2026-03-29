# Commitment Tracker — Promises, Reminders, and Follow-ups

**Status**: Planned
**Priority**: Medium — quality-of-life for long-running sessions
**Effort**: Medium (~300-400 lines)

## Problem

The agent makes commitments during conversation — "I'll check on that later",
"I'll follow up after the research completes", "remind me to review this
tomorrow". These are lost. There is no mechanism to detect promises in output,
create scheduled follow-ups, or track whether commitments were honoured.

Similarly, the operator may ask the agent to do something later — "look into X
when you get a chance", "check the logs tomorrow morning". These requests are
only in the conversation history and are forgotten on session restart.

## Proposed Solution

### 1. Commitment Detection

After each cycle, scan the agent's output for commitment patterns:

- Explicit promises: "I'll", "I will", "let me check on that", "I'll follow up"
- Reminders: "remind me", "don't forget", "we should check"
- Deferred work: "later", "tomorrow", "next session", "when you're ready"
- User requests for future work: "can you look into", "check on X for me"

This can be a lightweight heuristic pass on the output text (no LLM call
needed). The Archivist already processes the output — commitment detection
can run in parallel.

### 2. Commitment Records

```
Commitment(
  cycle_id: String,          // Source cycle
  text: String,              // The commitment text
  kind: Promise | Reminder | DeferredWork,
  due: Option(String),       // ISO timestamp if time-specific
  status: Pending | Honoured | Expired,
  created_at: String,
)
```

Stored as append-only JSONL in `.springdrift/memory/planner/commitments.jsonl`.
Indexed by the Librarian.

### 3. Follow-up Mechanism

- **Sensory events**: pending commitments appear in the sensorium `<tasks>`
  section so the agent sees them every cycle without tool calls
- **Scheduled check**: if a commitment has a `due` time, create a
  `QueuedSensoryEvent` that fires at that time via `send_after`
- **Session-start replay**: on startup, any `Pending` commitments from
  previous sessions are surfaced as sensory events

### 4. Resolution

When the agent addresses a commitment (detected by the Archivist matching
the commitment's keywords against the new cycle's narrative), the commitment
status is updated to `Honoured`. Expired commitments (older than configurable
threshold, default 7 days) are marked `Expired`.

## Integration Points

- **Archivist** — commitment detection runs post-cycle alongside narrative
  generation
- **Librarian** — indexes commitments in ETS for sensorium queries
- **Curator** — renders pending commitments in the sensorium
- **Planner** — commitments can optionally create PlannerTask entries for
  larger follow-ups

## What This Enables

The agent keeps its word. "I'll check on that" actually results in a check.
The operator can ask for future work and trust it won't be forgotten. Over
time, the commitment honour rate becomes a measurable quality metric visible
in the meta observer.
