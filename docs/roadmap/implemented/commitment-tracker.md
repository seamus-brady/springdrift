# Commitment Tracker — MVP

**Status**: Shipped 2026-04-22 (PR #102) — MVP scope
**Priority**: Medium
**Effort**: ~740 LOC including tests

## Problem

Two concrete gaps:

1. **Agent commits to follow-up in prose and forgets.** "I'll check X later"
   lives in a narrative entry and is never acted on.
2. **Operator asks for deferred work, lost across restarts.** "Check the
   logs tomorrow" vanishes once the conversation window scrolls.

Both fall into the same shape: something was said that implies a future
action, and the system has no record of it.

## Solution

A small post-cycle scanner catches commitment-shaped statements, stores
them as **captures**, and lets the agent either schedule a cycle for them
(via the existing scheduler) or dismiss them. That's it.

One capability, three tools, one sensorium line.

## Explicitly out of scope

This MVP is deliberately narrow. The broader GTD-pipeline design —
Next Actions queue, Waiting For list, Someday/Maybe, autonomous engage,
weekly review — is archived at
[`docs/roadmap/archived/commitment-tracker-gtd.md`](../archived/commitment-tracker-gtd.md)
and may be picked up later if the MVP proves useful.

Out of MVP:

- Next Actions / Waiting For / Someday stores
- Capability-context tags (`@research`, `@coder`, etc.)
- Multiple clarify routes — MVP has one (calendar)
- Autonomous engage (scheduler pulling from a NA queue)
- Weekly GTD review in the Remembrancer
- Auto-clarify / confidence thresholds
- New deterministic `tool_rules` in `dprime.json` (existing coverage suffices for MVP's attack surface)
- Regex pregate on the scanner (default always-LLM until hit-rate data warrants)
- Backlog-nudge escalation
- Priority / confidence fields on captures

## Naming

The store is **`captures`**, not `inbox` — "inbox" already means email
(AgentMail). Sensorium block, tools, module, and JSONL path follow.

## Design

### Scanner (`src/captures/scanner.gleam`, ~120 LOC)

After each cycle completes, spawn an unlinked worker (same pattern as
Archivist):

1. One LLM call to `task_model` (Haiku) with the cycle's final output
2. XStructor-validated output against `captures.xsd`:

```xml
<captures>
  <capture
    text="Check scheduler logs after the research run completes"
    source="AgentSelf"
    due_hint="after research run"/>
</captures>
```

Prompt explicitly instructs the LLM to handle negation ("I will never X"),
rhetoric ("I'll bet"), conditionals that didn't fire, and already-delivered
commitments. Empty `<captures/>` is the common case and an acceptable result.

3. Post-scanner sanity filter drops malformed captures:
   - Max `captures_max_per_cycle` captures (default 10)
   - Per-capture text length ≤ 500 chars
   - Reject captures whose text is suspiciously similar to the scanner's
     own prompt (prompt-echo defence)
   - XML/brace characters escaped for sensorium safety
   - Rejected captures logged via `slog` with `captures_rejected` reason

4. For each surviving capture, append a `Created` op to
   `.springdrift/memory/captures/YYYY-MM-DD-captures.jsonl`
5. Notify the Librarian (ETS insert)

**No regex pre-filter in MVP.** LLM-first detection. A regex pregate as a
cost optimisation is possible later once we have hit-rate data.

**Failure mode is benign.** Scanner failure just means captures for that
cycle are missed. Fire-and-forget; never blocks the user.

### Types (`src/captures/types.gleam`, ~50 LOC)

```gleam
pub type CaptureSource {
  AgentSelf       // Agent made the promise in its own output
  OperatorAsk     // Operator asked for deferred work in an input message
  InboundComms    // Derived from an email or webhook (via existing comms agent)
}

pub type CaptureStatus {
  Pending
  ClarifiedToCalendar(scheduler_job_id: String)
  Dismissed(reason: String)
  Expired
}

pub type Capture {
  Capture(
    id: String,                        // cap-<8 hex>
    created_at: String,
    source_cycle_id: String,
    text: String,
    source: CaptureSource,
    due_hint: Option(String),          // Raw hint, unresolved
    status: CaptureStatus,
  )
}

pub type CaptureOp {
  Created(Capture)
  ClarifiedToCalendar(id: String, scheduler_job_id: String, note: String)
  Dismissed(id: String, reason: String)
  Expired(id: String)
}
```

### Storage (`src/captures/log.gleam`, ~80 LOC)

Append-only JSONL matching the tasks/endeavours/facts pattern:

  `.springdrift/memory/captures/YYYY-MM-DD-captures.jsonl`

State is derived by replaying the op log (`resolve_captures`). The
Librarian replays recent files at startup (bounded by `librarian_max_days`)
and indexes pending captures in ETS.

### Tools (`src/tools/captures.gleam`, ~80 LOC)

Three tools, all on the cognitive loop. Two are tool-gate exempt (local
log writes only); `clarify_capture` delegates to the existing scheduler
tool, which carries its own D' gate.

| Tool | Purpose | D' |
|---|---|---|
| `list_captures(status?)` | Returns pending (or filtered) captures | Exempt (read) |
| `clarify_capture(id, due, description)` | Schedules a cycle at `due` with `description` as input, marks capture `ClarifiedToCalendar` | Delegates to `scheduler.schedule_from_spec` |
| `dismiss_capture(id, reason)` | Marks capture `Dismissed`; reason recorded | Exempt (log write) |

The clarify tool has exactly one route in MVP. Its implementation:

1. Resolve `due` (ISO timestamp or simple hint like "tomorrow", "in 2h");
   reject if unresolvable (operator/agent must specify)
2. Call `scheduler.schedule_from_spec` with the `description` as the
   cycle input — this pushes through the scheduler's existing validation
3. On success, append `ClarifiedToCalendar(id, job_id, note)` op
4. On failure, return the scheduler error without mutating the capture

### Sensorium (~30 LOC in `narrative/curator.gleam`)

One new line, count only:

```xml
<captures pending="3"/>
```

- Rendered only when `pending > 0`
- No per-item detail — the agent calls `list_captures` when it wants to look
- No stale/overdue hints in MVP (those emerge from the GTD-pipeline follow-ups)

### Expiry (`src/captures/expiry.gleam`, ~40 LOC)

Daily scheduler job: scan pending captures, append `Expired` op for any
with `now - created_at > captures_expiry_days` (default 14). Appears in
the log; Librarian ETS entry removed.

### Skill

New skill at `.springdrift/skills/captures/SKILL.md`, scoped to
`cognitive`:

- What a capture is (auto-detected commitment or operator ask)
- Three actions the agent can take: clarify (schedule), dismiss, leave
- When to clarify vs leave: clarify if there's a clear due time or the
  capture is clearly actionable; otherwise leave and it'll either be
  handled in a later cycle or expire
- Dismiss reasons: "done already", "no longer relevant", "detected in
  error" — always include a short reason

HOW-TO updates in `.springdrift/skills/HOW_TO.md` and
`.springdrift_example/skills/HOW_TO.md`: add a `captures` row to the tool
selection table.

## Safety surface

Reduces to three things because the MVP has no autonomous action path:

- **Scheduled cycle input** (from `clarify_capture`) passes through the
  existing input gate — canary probes, deterministic rules, LLM scorer
  for autonomous inputs. Existing coverage.
- **Sanity filter** strips oversized captures, prompt-echo defence, and
  XML-unsafe characters before captures land in JSONL. App-level.
- **No direct autonomous action.** Captures don't do anything on their
  own; only `clarify_capture(due)` schedules work, and scheduled cycles
  are already gated.

No new deterministic `tool_rules`, no new agent overrides, no new input
gate config. Everything risky delegates to surfaces that are already
hardened.

### Source-field reliability (deferred concern)

The LLM's classification of `AgentSelf` / `OperatorAsk` / `InboundComms`
isn't perfect. At MVP this matters mainly for diagnostics — the
source-based route restrictions from the full GTD spec don't apply
because there's only one route. The field is recorded for future use
and to help operators audit what the scanner is catching.

## Configuration (`AppConfig`)

Three fields:

| Field | Default | Purpose |
|---|---|---|
| `captures_scanner_enabled` | True | Master switch for the post-cycle scanner |
| `captures_expiry_days` | 14 | Auto-expire pending captures after N days |
| `captures_max_per_cycle` | 10 | Sanity-filter cap on captures per scan |

## Implementation checklist

Single phase, single PR:

- [ ] `src/captures/types.gleam` — types, JSON codecs
- [ ] `src/captures/log.gleam` — append-only JSONL, op replay, Librarian notify
- [ ] `src/captures/scanner.gleam` — LLM call, XStructor parse, sanity filter, spawn_unlinked worker
- [ ] `src/captures/expiry.gleam` — daily scheduler job
- [ ] `src/xstructor/schemas.gleam` — add `captures.xsd` + example
- [ ] `src/tools/captures.gleam` — three tools
- [ ] `src/narrative/librarian.gleam` — add `QueryPendingCaptures`, `IndexCapture`, `RemoveCapture` messages
- [ ] `src/narrative/curator.gleam` — render `<captures>` sensorium block
- [ ] `src/narrative/archivist.gleam` — spawn scanner alongside narrative worker
- [ ] `src/springdrift.gleam` — wire captures directory, register tools
- [ ] `src/config.gleam` — three new fields with defaults
- [ ] `.springdrift_example/config.toml` + `.springdrift/config.toml` — documented entries
- [ ] `.springdrift/skills/captures/SKILL.md` — skill file
- [ ] `.springdrift/skills/HOW_TO.md` + `.springdrift_example/skills/HOW_TO.md` — tool table row
- [ ] Tests:
  - [ ] Log op replay correctness
  - [ ] Sanity filter rejections
  - [ ] Tool behaviour (list, clarify success + failure, dismiss)
  - [ ] Scanner extraction via mock provider (empty, one, many, malformed)
  - [ ] Expiry sweep
  - [ ] Sensorium rendering (present when > 0, omitted when 0)

## Risks

- **Scanner per-cycle cost.** ~50 cycles/day × Haiku pricing = pennies.
  Acceptable. Observe hit rate after a week; if <10% reconsider a regex
  pregate (full spec has the details).
- **LLM over-extraction.** The LLM might flag rhetorical uses as
  commitments. Sanity filter catches extreme cases; the rest is
  dismissible by the agent or operator. Not worth gating harder in MVP.
- **Source misclassification.** Deferred concern — no route restrictions
  depend on source in MVP.
- **Operator-visible surface is thin.** Sensorium count and tool output
  only; no web GUI tab. Intentional — build the substrate first.

## What this enables

- Operator asks "what did I ask you to do this week?" → agent calls
  `list_captures`, returns the list
- Agent notices `<captures pending="2"/>` in sensorium, clarifies one
  with a due time → scheduler fires a cycle then → agent acts
- Captures accumulate on disk as an audit trail of commitment-shaped
  utterances, available for future GTD-pipeline work
- If the MVP proves useful, the archived full spec is the roadmap for
  Phases 3-5 (Next Actions, Waiting For, Someday, autonomous engage,
  weekly review)

What's *not* claimed: honour-rate metrics, affect feedback, auto-honour
matching, behaviour shifts. Those were in the previous spec and didn't
survive critique.
