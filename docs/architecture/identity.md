# Identity & Context Architecture

The identity system controls who the agent is (persona), what it perceives each cycle
(sensorium), and how memory is woven into every LLM request (Curator). Together these
modules transform a generic LLM into a situated, persistent agent with ambient
perception.

---

## 1. Identity Files

Two files define the agent's character:

| File | Purpose | Template syntax |
|---|---|---|
| `persona.md` | Fixed first-person character text | None (verbatim) |
| `session_preamble.md` | Per-cycle context template | `{{slot}}` substitution + `[OMIT IF]` rules |

### Discovery

File lookup uses a first-found-wins strategy across identity directories:

1. `.springdrift/identity/` (local project override)
2. `~/.config/springdrift/identity/` (global user default)

If neither directory contains the file, the caller falls back to a configured
`system_prompt` verbatim.

### Persona

`load_persona(dirs)` returns the raw text of `persona.md`. This is the agent's
fixed character -- its voice, values, and orientation. Injected verbatim at the
start of the system prompt.

### Preamble Template

`load_preamble_template(dirs)` returns `session_preamble.md`. This template
contains `{{slot}}` placeholders and optional `[OMIT IF]` directives.

#### Slot Substitution

`render_preamble(template, slots)` replaces `{{key}}` placeholders with values
from a `List(SlotValue)`. Lines with unresolved `{{...}}` placeholders are dropped.

#### OMIT IF Rules

Lines can include `[OMIT IF condition]` comments. The line is dropped when the
condition is met:

| Condition | Drops when |
|---|---|
| `EMPTY` | Rendered line is blank or ends with a colon |
| `ZERO` | Line contains a zero count (starts with "0 " or contains " 0 ") |
| `THREADS EXIST` | Never drops (placeholder for future use) |
| `FACTS EXIST` | Never drops (placeholder for future use) |
| `NO PROFILE` | Always drops (no profiles at runtime) |

This allows a single template to adapt to different states -- empty sections are
automatically omitted rather than displaying blanks.

## 2. Curator

The Curator (`src/narrative/curator.gleam`) is a supervised OTP actor that
orchestrates system prompt assembly from identity, memory, and ambient perception.

### Architecture

```
Cognitive Loop ──BuildSystemPrompt(context)──→ Curator
                                                  │
                              ┌────────────┬──────┼──────────┐
                              ▼            ▼      ▼          ▼
                          Identity     Librarian  Scheduler  State
                          (persona +   (counts,   (jobs,     (agent health,
                           preamble)    threads)   budget)    delegations)
                              │            │      │          │
                              └────────────┴──────┴──────────┘
                                           │
                                    Assembled System Prompt
                                    (persona + sensorium + memory)
```

### BuildSystemPrompt Message

The cognitive loop sends `BuildSystemPrompt` with optional `CycleContext`:

```gleam
pub type CycleContext {
  CycleContext(
    input_source: String,        // "user" or "scheduler"
    queue_depth: Int,
    session_since: String,
    agents_active: Int,
    message_count: Int,
    novelty: Float,              // Per-input keyword dissimilarity
    last_user_input: String,
    sensory_events: List(SensoryEvent),
  )
}
```

The Curator cannot derive these values itself -- they come from the cognitive loop's
ephemeral per-cycle state.

### Assembly Pipeline

1. **Load identity** -- `load_persona(dirs)` + `load_preamble_template(dirs)`
2. **Query Librarian** -- thread count, persistent fact count, case count
3. **Build sensorium** -- clock, situation, schedule, vitals, affect, delegations
4. **Render preamble** -- substitute slots, apply OMIT IF rules
5. **Apply budget** -- `apply_preamble_budget` enforces character limit
6. **Assemble** -- persona + `<memory>` wrapper around rendered preamble

Falls back to a provided fallback prompt when no identity files exist.

## 3. Sensorium

The sensorium is a self-describing XML block injected as the `{{sensorium}}` slot
in the preamble template. It gives the agent ambient perception of its own state
without needing tool calls. Based on Sloman's H-CogAff meta-management layer and
the Dupoux/LeCun/Malik System M paper (2603.15381).

### Structure

```xml
<sensorium>
  <clock now="2026-04-06T14:30:00Z" session_uptime="2h 15m" last_cycle="45s"/>
  <situation input="user" queue_depth="0" conversation_depth="12"
             thread="API integration"/>
  <schedule pending="3" overdue="1">
    <job name="daily-report" next="2026-04-06T18:00:00Z" status="pending"/>
  </schedule>
  <vitals cycles_today="42" agents_active="0"
          success_rate="0.88" recent_failures=""
          cost_trend="stable" cbr_hit_rate="0.35"
          novelty="0.62"/>
  <affect reading="desperation 12% · calm 78% · confidence 65% · frustration 8%
                   · pressure 15% ↔"/>
  <delegations/>
  <events>
    <event name="forecaster_replan" detail="Task X health declining"/>
  </events>
</sensorium>
```

### Sections

| Section | Contents | Source |
|---|---|---|
| `<clock>` | Current time, session uptime, time since last cycle | System clock |
| `<situation>` | Input source, queue depth, conversation depth, active thread | CycleContext |
| `<schedule>` | Pending/overdue job counts, individual job elements | Scheduler |
| `<vitals>` | Cycles today, active agents, success rate, cost trend, CBR hit rate, novelty | Narrative entries (via `compute_performance_summary`) |
| `<affect>` | Affect reading (5 dimensions + trend) | Affect store |
| `<delegations>` | Active agent delegations with turn/token/elapsed info | Cognitive state |
| `<events>` | Accumulated sensory events | CycleContext |

### Performance Summary

`compute_performance_summary(entries)` derives vitals signals from recent narrative
entries (50-entry window for statistical stability):

- `success_rate` -- proportion of entries with `Success` outcome
- `recent_failures` -- up to 3 most recent failure descriptions
- `cost_trend` -- stable/increasing/decreasing (first-half vs second-half token usage)
- `cbr_hit_rate` -- proportion of entries with non-empty sources

These are history-backed signals that span sessions (not reset on restart).

### Novelty

Per-input keyword dissimilarity, computed from Jaccard similarity between the
current input's keywords and recent narrative entry keywords. High novelty (>0.7)
signals the agent is exploring new territory; low novelty (<0.3) signals routine
work.

## 4. Preamble Budget

`apply_preamble_budget(slots, budget_chars)` enforces a configurable character
limit (`preamble_budget_chars`, default 8000, ~2000 tokens). Slots are prioritised:

| Priority | Slot | Purpose |
|---|---|---|
| 1 | Identity (persona) | Who the agent is |
| 2 | Sensorium | Ambient perception |
| 3 | Affect | Emotional state |
| 4-6 | Memory (threads, facts, cases) | Working memory |
| 7-10 | Background context | Lower-priority context |

When total characters exceed the budget, lower-priority slots are truncated or
cleared. Existing `[OMIT IF EMPTY]` rules handle omission naturally after clearing.

## 5. Inter-Agent Context

The Curator manages inter-agent context enrichment:

- **Write-back** -- when an agent completes, its results are written back to the
  Curator's state so subsequent agents can see prior results
- **Agent health** -- `UpdateAgentHealth` messages from the supervisor push health
  updates visible in the sensorium's `<vitals agent_health="...">`
- **Constitution** -- the Archivist pushes `UpdateConstitution` after each cycle

## 6. Character Spec

`identity/character.json` defines the agent's normative character for the
normative calculus (see `safety.md`). Loaded via `normative/character.gleam`
using the same directory discovery pattern as `persona.md`.

Contains:
- **Virtues** -- named virtues with behavioural expressions (e.g. equanimity,
  thoroughness, epistemic honesty)
- **Highest endeavour** -- list of normative propositions defining the agent's
  core commitments (used as system-side NPs in conflict resolution)

`default_character()` provides a fallback with 5 virtues and 4 core commitments
when no character.json exists.

## 7. Key Source Files

| File | Purpose |
|---|---|
| `identity.gleam` | Persona/preamble loading, template rendering, slot substitution |
| `narrative/curator.gleam` | Curator actor: system prompt assembly, sensorium, performance summary |
| `narrative/meta_states.gleam` | Novelty computation |
| `normative/character.gleam` | Character spec loading from character.json |
| `paths.gleam` | Centralised path definitions including identity directories |
