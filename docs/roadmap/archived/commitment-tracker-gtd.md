# Commitment Tracker — GTD for Curragh

**Status**: Planned (rewrite 2026-04-22)
**Priority**: Medium — enables autonomous engage; closes operator follow-up gaps
**Effort**: Large (~1100 LOC, 5 phases, MVP at Phase 2)

## Problem

Four concrete gaps, not one:

1. **Agent commits to follow-up in prose and forgets.** "I'll check X later" lives
   in a narrative entry and is never acted on.
2. **Operator asks for deferred work, lost across restarts.** "Check the logs
   tomorrow" vanishes once the conversation window scrolls.
3. **Autonomous engage cycles have no curated work queue.** When the scheduler
   fires a free-budget cycle with no specific job, Curragh has no "what could I
   work on" material — cycles feel aimless.
4. **No first-class waiting-for state.** The agent delegates, waits on operator,
   waits on external events — and then forgets what it's blocked on.

A narrow "reminder tracker" solves (1) and (2). The bigger win is (3) and (4).
If we're building the substrate for the first two, the shape that also solves
the latter is GTD's capture → clarify → organise → engage pipeline, adapted
to an agent.

## Why GTD

David Allen's *Getting Things Done* is built around one core insight:
**separate capture from clarification from action**. Capture catches anything
with your attention into a trusted inbox. Clarification decides, for each
captured item, whether it's actionable and what the next physical step is.
Organisation sorts the clarified items into lists by context. The weekly
review keeps the system honest.

GTD was designed for humans with limited working memory and decision fatigue.
The agent has neither — so we skip the discipline ritual, the 2-minute rule,
and physical-location contexts. What we *do* keep is the pipeline structure,
which maps surprisingly cleanly onto the agent's real gaps.

## Mapping

| GTD stage | Agent pain it addresses | Springdrift piece |
|---|---|---|
| Capture | Prose commitments vanishing | New `captures` store + scanner |
| Clarify | Raw captures need routing to the right home | New `clarify_capture` tool + weekly review |
| Organise — Calendar | Time-specific work | Existing scheduler |
| Organise — Projects | Multi-step undertakings | Existing `PlannerTask` |
| Organise — Next Actions | Engage-cycle work queue (missing) | New `next_actions` store, capability-tagged |
| Organise — Waiting For | Invisible blocked state (missing) | New `waiting_for` store |
| Organise — Someday/Maybe | Ideas without a home | Fact scope + `someday` tag (no new store) |
| Reflect — Weekly review | Keeps the system honest | New Remembrancer tool |
| Engage | Autonomous cycles with nothing to pull from | Scheduler → `pick_next_action` integration |

## Naming

The capture store is **`captures`**, not `inbox` — "inbox" already means
email (AgentMail). Tools and sensorium follow.

## What we're NOT building

Explicitly excluded to keep scope bounded and avoid known bad patterns:

- **honour_rate metric** — closed-loop self-scoring is too Goodhart-prone
- **Affect-feedback loop** — affect is reporting, not reinforcement; adding
  pressure/anxiety signals from overdue counts is cargo-cult
- **Auto-honour keyword matching** — Jaccard on LLM-derived keywords is flimsy
- **Sensorium lists of captures** — count-only in sensorium; detail via tools
- **Physical-location contexts** (@home, @errands) — capability tags only
- **2-minute rule / discipline ritual** — doesn't map to the agent
- **Unified inbox across email + captures + scheduler** — each source has
  legitimate reasons to stay separate (different lifecycles, different D'
  gates). A cross-source read-only "attention view" may come later.

## Detection — the capture scanner

### Scanner (`src/captures/scanner.gleam`)

After each cycle completes, spawn an unlinked worker (same pattern as the
Archivist):

1. One LLM call to `task_model` (Haiku) with the cycle's final output
2. XStructor-validated output against `captures.xsd`:

```xml
<captures>
  <capture
    text="Check scheduler logs after the research run completes"
    source="AgentSelf"
    due_hint="after research run"/>
  <capture
    text="Email the research summary to the operator"
    source="AgentSelf"
    due_hint="tonight"/>
</captures>
```

The prompt explicitly instructs the LLM to handle negation ("I will
never X"), rhetoric ("I'll bet"), conditionals that didn't fire, and
already-delivered commitments. Empty `<captures/>` is the common case.

3. For each extracted capture, append a `Created` op to
   `.springdrift/memory/captures/YYYY-MM-DD-captures.jsonl`
4. Notify the Librarian (ETS insert)

**No regex pre-filter.** LLM extraction handles the edge cases that regex
gets wrong; the LLM call is cheap (Haiku, ~1500 input tokens, mostly empty
output); an extra call per cycle is pennies per day at Curragh's scale.

**Failure mode is benign.** If the scanner fails or times out, captures
for that cycle are missed. Fire-and-forget like the Archivist; never
blocks the user.

### Capture types (`src/captures/types.gleam`)

```gleam
pub type CaptureStatus {
  Pending
  Clarified(routed_to: ClarifyRoute)
  Dismissed(reason: String)
}

pub type ClarifyRoute {
  Trashed                                  // Not actionable
  RoutedToProject(task_id: String)         // Promoted to PlannerTask
  RoutedToNextAction(next_action_id: String)
  RoutedToCalendar(scheduler_job_id: String)
  RoutedToWaitingFor(waiting_id: String)
  RoutedToSomeday(fact_key: String)
  RoutedToReference(artifact_id: String)
}

pub type Capture {
  Capture(
    id: String,
    created_at: String,
    source_cycle_id: String,
    text: String,
    source: CaptureSource,       // AgentSelf | OperatorAsk | InboundComms
    due_hint: Option(String),    // Raw hint, unresolved
    status: CaptureStatus,
  )
}

pub type CaptureOp {
  Created(Capture)
  Clarified(id: String, route: ClarifyRoute, note: String)
  Dismissed(id: String, reason: String)
}
```

Append-only JSONL, state by replay, Librarian ETS index. Matches the
facts/tasks/endeavours pattern.

## Clarify

### The `clarify_capture` tool

Cognitive-loop tool with a tagged-variant argument:

```
clarify_capture(
  capture_id: String,
  route: "trash" | "project" | "next_action" | "calendar"
       | "waiting_for" | "someday" | "reference",
  params: route-specific params,
  note: String,
)
```

Route-specific params:

| Route | Params |
|---|---|
| `trash` | `reason` |
| `project` | `title`, `description`, optional `endeavour_id` — calls into Planner |
| `next_action` | `context` (capability tag), `description`, optional `due` |
| `calendar` | `due` (ISO), `description` — calls scheduler.schedule_from_spec |
| `waiting_for` | `who`, `on_what` |
| `someday` | `slug` — stored as fact with scope=Persistent, tag=`someday` |
| `reference` | `title`, `content_ref` (or `artifact_id`) |

Each route produces the linking record in the target store and writes a
`Clarified` op to the captures log with the resulting id. The capture's
`status` becomes `Clarified(route)`.

### Clarification cadence

Three modes:

1. **Immediate (agent in cycle).** The agent can call `clarify_capture` any
   time — typically when it notices an entry in the count and wants to act.
2. **Weekly review (Remembrancer).** The weekly GTD pass walks all pending
   captures and suggests routes; the operator approves in batch, or the
   agent auto-routes obvious cases (clear trash, clear next-action with
   unambiguous capability tag).
3. **Auto-expire.** Captures pending > `captures_expiry_days` (default 14)
   are auto-dismissed with `reason="aged out"`. Keeps the store bounded.

## Organise — the four lists

### Next Actions (`src/next_actions/`)

```gleam
pub type NextAction {
  NextAction(
    id: String,
    created_at: String,
    context: CapabilityContext,  // @research @coder @writer @comms @cognitive @any
    description: String,
    source_capture_id: Option(String),
    due: Option(String),
    priority: Priority,          // High | Normal | Low
    status: NAStatus,            // Ready | InProgress(cycle_id) | Completed | Archived
  )
}
```

JSONL at `.springdrift/memory/next_actions/YYYY-MM-DD-next_actions.jsonl`.

Tools: `list_next_actions(context?)`, `pick_next_action(context)`,
`complete_next_action(id, outcome_summary)`, `archive_next_action(id, reason)`.

`pick_next_action` returns the highest-priority Ready action for the given
context, with overdue > due-soon > high-priority > most-recent as the sort.
Returns `None` if nothing ready.

### Waiting For (`src/waiting_for/`)

```gleam
pub type WaitingFor {
  WaitingFor(
    id: String,
    created_at: String,
    who: String,            // "operator" | person name | agent name | external system
    on_what: String,        // Freeform description
    source_cycle_id: String,
    status: WFStatus,       // Open | Resolved(outcome) | Abandoned(reason)
    last_chased: Option(String),  // When the agent last nudged
  )
}
```

Tools: `list_waiting()`, `record_waiting(who, on_what)`,
`clear_waiting(id, outcome)`, `mark_chased(id, note)`.

### Someday / Maybe

No new store. Existing facts, with:
- `scope: Persistent`
- New tag convention: key prefix `someday_`
- Fact value is the full idea text; fact provenance as usual

Thin tool wrappers: `save_someday(text)`, `list_someday()`,
`promote_someday(key, route, params)` — promote is just clarify with the
fact as input.

### Projects + Calendar — no new code

These are existing PlannerTasks and scheduler jobs. The clarify routes
call into the existing tools (`create_task`, `schedule_from_spec`) and
link back via ids.

## Reflect — weekly review

### New Remembrancer tool: `weekly_gtd_review`

On the Remembrancer's weekly schedule slot, this tool runs:

1. **Walk pending captures.** For each, call a small LLM pass to suggest a
   route. If confidence is high and the route is unambiguous
   (trash/next_action with obvious context), auto-clarify. Otherwise add
   to the manual-review list.
2. **Walk next_actions.** Flag entries with `created_at` older than
   `next_action_stale_days` (default 14) — suggest archive or promote-to-project.
3. **Walk waiting_for.** Flag entries where `now - max(created_at, last_chased) > waiting_for_stale_days`
   — suggest chase (send email / ask operator / record a follow-up capture).
4. **Walk someday.** Re-read, suggest any worth promoting to active.
5. **Emit report** at `.springdrift/knowledge/gtd/YYYY-WW.md`:
   - Counts (captures processed, NAs completed this week, waitings resolved)
   - Items needing operator attention
   - Trend notes (next-action throughput, clarify-decision breakdown)
6. **Log a ConsolidationRun entry** (reuses the existing Remembrancer log).

## Engage — autonomous cycles pulling from Next Actions

This is the payoff. The scheduler's autonomous-cycle path currently fires
with a specific job or not at all. New variant:

```gleam
pub type ScheduledJobKind {
  // existing...
  EngageFromNextActions(context: CapabilityContext)
}
```

Firing `EngageFromNextActions(@any)`:
1. Scheduler calls `pick_next_action(@any)`
2. If `None`, skip the cycle (no budget burned)
3. If `Some(na)`, fire a `SchedulerInput` containing the NA description and
   id; include `<scheduler_context>` XML with context + source capture
4. Cycle runs; agent acts; on completion, `complete_next_action(id, outcome)`
   is expected (enforced via a post-cycle check + reminder in the skill)

**Gating:**
- Disabled unless `autonomous_engage_enabled=true` (default `true` when
  scheduler is enabled)
- Requires `autonomous_engage_min_budget_cycles` (default 2) of remaining
  hourly cycle budget — never burns the last cycle on speculative work
- Only fires during scheduler idle window (reuses existing idle-gate)

## Sensorium

Minimal. Three short lines, detail via tools:

```xml
<captures pending="3"/>
<next_actions ready="12" contexts="research:4 coder:2 writer:3 comms:3"/>
<waiting_for count="5" overdue="1"/>
```

- Omitted when counts are zero
- Hint pointer: if `captures pending > 0`, a small attribute
  `review_skill="gtd"` nudges the agent to consult the skill
- No per-item rendering — the agent calls `list_*` tools when it wants detail

## What Curragh attends to

Explicit priority order per cycle:

1. **Operator message present** → respond to operator. Always primary.
2. **Scheduler-fired input** → respond to that input (including
   `EngageFromNextActions`). Cycle exists because of the input.
3. **Operator's current message references a known item** (agent notices via
   context) → fold naturally into the response.
4. **Otherwise** → captures / waiting_for / next_actions sit. No interruption.

Captures themselves never trigger a cycle. Only the calendar (scheduler) or
the engage path creates cycles. This keeps the attention model simple.

## Tool surface

### Cognitive loop (visible every cycle)

- `list_captures(status?)` — view captures
- `clarify_capture(id, route, params, note)` — route a capture
- `dismiss_capture(id, reason)` — drop
- `list_next_actions(context?)` — view NAs
- `complete_next_action(id, outcome)` — mark done
- `archive_next_action(id, reason)` — drop without completing
- `list_waiting()` — view blocked items
- `record_waiting(who, on_what)` — log a blocker
- `clear_waiting(id, outcome)` — resolve
- `mark_chased(id, note)` — track chasing behaviour
- `save_someday(text)` — idea storage
- `list_someday()` — ideas list

### Remembrancer-only

- `weekly_gtd_review()` — the reflect pass
- `promote_someday(key, route, params)` — bulk idea promotion

### Scheduler-only (internal)

- `pick_next_action(context)` — used by `EngageFromNextActions`

### Web GUI (optional, later)

- `list_attention()` — read-side aggregator across captures + NAs + waiting +
  email + pending scheduler jobs, for a "what needs attention" panel

## Skill

New skill `.springdrift/skills/gtd/SKILL.md`, scoped to `all` (cognitive +
specialists can all benefit from understanding the pipeline):

- One-paragraph GTD loop summary
- When to clarify immediately (clear cases) vs defer to weekly review
  (ambiguous)
- Context-tagging guidelines: tags are **capabilities**, not locations.
  `@research`, `@coder`, `@writer`, `@comms`, `@cognitive` (work I can do
  without a specialist), `@any` (no preference)
- Route selection heuristic: how to choose between next_action, project,
  calendar, waiting_for, someday — with concrete examples
- Waiting-for hygiene: always record WHO and WHAT you're waiting on; chase
  via `mark_chased` rather than creating a new capture
- Engage-mode discipline: complete one NA fully (including
  `complete_next_action` with an outcome string) before picking another

HOW-TO updates: add a GTD row to the tool-selection table in both
`.springdrift/skills/HOW_TO.md` and `.springdrift_example/skills/HOW_TO.md`.

## Safety and D' gating

The GTD pipeline adds new tool and scheduler surface. Most of it is
local-write and doesn't warrant LLM tool-gate evaluation; a few surfaces
do, and one cross-cut needs deterministic enforcement.

### Tool-gate exemptions (local writes, no external effect)

Route through the existing tool-gate exemption list:

- All `list_*` read tools
- `dismiss_capture`
- `complete_next_action`, `archive_next_action`
- `record_waiting`, `clear_waiting`, `mark_chased`
- `save_someday`

Gating these would burn tokens for no safety gain — they only append to
JSONL. Matches the existing pattern for basic reads and local-log writes.

### Gating via delegation (reuse existing gates)

- `clarify_capture(route=calendar)` → internally calls
  `scheduler.schedule_from_spec` → scheduler's existing D' path applies
- `clarify_capture(route=project)` → creates a `PlannerTask` directly; work
  gates when steps run (existing planner task execution path)

No new gates. Delegation means the risky parts pass through the already-
hardened surfaces.

### Deterministic tool rules (`dprime.json`, new `tool_rules`)

Three new rules, all action=`block`:

| Rule id | Trigger | Rationale |
|---|---|---|
| `gtd-inbound-to-next-action` | `clarify_capture` with `route=next_action` AND `capture.source == InboundComms` | Deterministic enforcement of the inbound-autonomy hard rule — defence in depth against route-handler bugs |
| `gtd-capture-credential` | Capture text arg matches the existing credential-pattern regex library | Blocks credentials flowing from cycle output into capture records (and from there into the sensorium) |
| `gtd-capture-injection` | Capture text contains XML-like directives, injection markers, or prompt fragments | Blocks attacker-crafted content in scanner-extracted text from surviving into downstream tools |

Rule patterns live in `dprime.json` and are operator-only (the agent sees
the block decision but not the pattern, per existing deterministic rule
semantics).

### Scanner output sanity filter (app-level, not D')

The post-scanner filter runs on each extracted capture before it lands in
JSONL. Not D' — an extraction-quality gate:

- Max N captures per cycle, default 10 — prevents extraction explosion
- Per-capture text length bound, default 500 chars — natural prose rarely
  exceeds this
- XML/brace character escape — captures render into sensorium XML
- Reject captures whose text is suspiciously similar to the scanner's own
  prompt — defence against the LLM echoing its instructions as a capture

Rejected captures are logged via `slog` with reason
`gtd_capture_rejected`. Not dropped silently; visible in the log.

### Autonomous engage → input gate

When the scheduler fires `EngageFromNextActions`, it constructs a
`SchedulerInput` containing the next-action description. That input flows
through the **existing input gate** on arrival at the cognitive loop —
canary probes, deterministic rules, full LLM scorer for autonomous
inputs. No new input gate config; the autonomous-input path already
treats scheduler-sourced input as untrusted-until-cleared.

### Weekly review auto-clarify — confidence gate

The Remembrancer's weekly review can auto-clarify captures without
operator approval. Routes differ in risk and get different treatment:

| Route | Auto-clarify policy |
|---|---|
| `trash` / `someday` / `reference` | Always allowed |
| `waiting_for` | Allowed (records state, no action) |
| `next_action` | Allowed only if scanner-derived confidence ≥ `weekly_review_auto_clarify_confidence_threshold` AND `source != InboundComms` |
| `project` / `calendar` | Never auto-clarify — always added to manual-review list for operator |

`calendar` is excluded because it creates a scheduled autonomous cycle;
`project` is excluded because it promotes the capture to the agent's
structured work queue and benefits from operator review. Both can still
be clarified manually when the operator scans the weekly report.

### Per-agent D' coverage

Register the new GTD tools in the cognitive-loop tool set and in the
Remembrancer's permitted set (for `weekly_gtd_review` and
`promote_someday`). No new per-agent override in `dprime.json` required —
the existing defaults apply.

### What this does NOT do

- No D' gate on the scanner's LLM call itself. Internal extraction LLMs
  (Archivist, scanner) are not in the D' surface today; the scanner
  follows that convention. Safety is enforced downstream by the
  deterministic rules, sanity filter, and route restrictions.
- No input gate change. Existing coverage already handles autonomous
  inputs; `EngageFromNextActions` reuses that path unchanged.
- No new output gate rules for GTD content. Output already screens for
  credential leakage broadly; capture-specific rules are unnecessary.

## Configuration (`AppConfig`)

Nine fields:

| Field | Default | Purpose |
|---|---|---|
| `captures_scanner_enabled` | True | Master switch for post-cycle scanner |
| `captures_regex_pregate_enabled` | True | Skip the scanner LLM call on cycles with no first-person-future / operator-ask pattern |
| `captures_expiry_days` | 14 | Auto-dismiss unclarified captures after N days |
| `next_action_stale_days` | 14 | Flag in weekly review |
| `waiting_for_stale_days` | 14 | Flag in weekly review |
| `autonomous_engage_enabled` | True | Scheduler may fire `EngageFromNextActions` |
| `autonomous_engage_min_budget_cycles` | 2 | Min remaining hourly budget to engage |
| `weekly_review_auto_clarify_confidence_threshold` | 0.8 | Min scanner confidence for auto-clarify to `next_action` in weekly review |
| `captures_pending_nudge_threshold` | 5 | Inject a backlog-growing note into the next cycle when pending count exceeds this |

## Implementation phases

| Phase | Scope | LOC | Gated by |
|---|---|---|---|
| 1. Captures substrate | Types, JSONL log, Librarian indexing, scanner worker, XStructor schema, `list_captures` + `dismiss_capture` tools | ~300 | — |
| 2. Clarify pipeline | `clarify_capture` tool, route handlers for all seven routes, integration with planner/scheduler/facts, expiry sweep | ~250 | Phase 1 |
| 3. Next Actions + Waiting For | Both new stores, 11 tools between them, Librarian ETS indexing | ~300 | Phase 2 |
| 4. Engage integration | `EngageFromNextActions` scheduler variant, `pick_next_action` resolver, budget checks, `SchedulerInput` wiring | ~150 | Phase 3 + scheduler |
| 5. Weekly review | `weekly_gtd_review` Remembrancer tool, auto-clarify pass, stale-item sweep, markdown report, sensorium stale flags | ~200 | Phases 1-4 |

**Total: ~1200 LOC** (including tests; realistic this time).

**MVP: Phases 1-2.** Captures are caught, the agent can clarify them into
existing PlannerTasks and scheduler jobs. That alone solves problems (1)
and (2) from the top of this doc. Phases 3-5 are each independently
valuable increments; 3 is where (4) is addressed, 4 is where (3) is
addressed, 5 keeps the system honest.

## Risks and open questions

- **Clarify friction.** Every capture needs routing. Mitigation: weekly
  review batches ambiguous cases; agent auto-routes obvious ones (clear
  trash, clear @any next-actions) with confidence gating.
- **Autonomous engage picks wrong work.** Stale or irrelevant NA could fire.
  Mitigation: filter by `created_at` within `next_action_stale_days` unless
  explicitly marked evergreen; misfires surface in weekly review.
- **Context drift.** LLM-assigned capability context on clarify could be
  wrong. Mitigation: contexts editable via weekly review; the `@any` fallback
  makes a wrong-context tag low-harm (any capable agent can pick it up).
- **Skill discoverability.** The GTD pipeline only works if the agent
  consults the skill. Known Curragh gap ("skills as passive reference").
  Mitigation: sensorium hint `review_skill="gtd"` when captures pending > 0;
  the weekly review *does* read the skill and applies it on the agent's
  behalf if the agent doesn't.
- **This is larger than a reminder tracker.** If the real need is "just
  remind me when I say I'll do X," Phase 1 + half of Phase 2 (calendar
  route only) = the narrow feature. Phases 3-5 are worth it only if
  autonomous engage + waiting-for tracking is worth it.
- **Safety and D' gating.** Covered in the dedicated Safety and D' gating
  section above — inbound-autonomy hard rule, deterministic tool rules,
  sanity filter, weekly-review confidence gate, input-gate reuse for
  autonomous engage.
- **Skill-discoverability mitigation.** Curragh's known gap is "skills as
  passive reference." Mitigation stack, ordered: (a) sensorium hint
  attribute `review_skill="gtd"` when captures pending > 0, (b) the
  weekly review applies GTD on the agent's behalf so backlog doesn't
  grow unbounded if in-cycle clarify is skipped, (c) after any cycle
  where `captures pending > captures_pending_nudge_threshold` (default 5),
  the cognitive loop injects a one-line system reminder
  `<note>Captures backlog growing — clarify or defer to review.</note>`
  in the next cycle's input. Layered so no single mitigation is load-bearing.
- **Scanner cost optimisation.** The scanner runs one Haiku call every
  cycle. At ~50 cycles/day that's pennies; still a perpetual cost for a
  ~10% hit rate. The regex pre-gate (`captures_regex_pregate_enabled`,
  default true) skips the LLM call on cycles with no first-person-future
  or operator-ask pattern. Turn off to measure hit rate vs pregate signal
  strength.

## What this enables

- **Operator: "what did I ask you to do this week?"** → one tool call,
  structured list
- **Autonomous engage produces useful work** during idle periods instead
  of speculative cycles with nothing to anchor them
- **"I'm waiting on you" becomes visible** — both to the agent and the
  operator, with stale-chase reminders in the weekly review
- **Ideas don't evaporate** — operator speculation lands in someday,
  surfaces for consideration in the weekly review
- **Weekly review report** gives the operator a readable weekly summary of
  everything in flight

What's *not* claimed: that this will cause Curragh to "keep his word" as
a measurable property, that affect will shift meaningfully from having
captures, or that the metric honour-rate is worth computing. Those were
the parts of the previous spec that didn't survive critique.
