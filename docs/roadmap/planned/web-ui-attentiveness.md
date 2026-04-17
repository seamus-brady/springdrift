# Web UI Attentiveness

**Status**: Planned
**Date**: 2026-04-17
**Scope**: `src/web/html.gleam`, `src/web/protocol.gleam`, `src/web/gui.gleam`, small additions to `src/narrative/curator.gleam` for affect relay.
**Size**: ~400–500 lines across four slices. Shippable as one PR or four, operator's choice.

---

## 1. Thesis

The current web UI presents Springdrift as a request-response chatbot: send, wait, receive. That framing undersells the architecture. Behind every reply there are multiple agents dispatching, tools running, safety gates firing, and a rich affect state shifting continuously. None of that reaches the operator.

Three consequences:

1. **During a reply, the operator sees a dead grey overlay.** No progress, no agent names, no tools, no turn counts. 30–120 seconds of opacity wash over "Thinking…" with three dots.
2. **Between sessions, the chat is ephemeral.** Everything Curragh said last week lives in narrative memory, but there's no conversation-shaped view.
3. **The agent has no presence when idle.** It's either actively replying or apparently dormant. No sense of a continuous interior.

This spec addresses all three as one project, because they share the same underlying fix: *surface real state the system already computes.*

The design principle mirrors the meta-learning spec — honesty over decoration. Every visual change carries a real signal. Nothing is there just to look active.

---

## 2. Current state

### What exists

- **Three-tab web UI** (Chat, Log, Narrative) served by `web/gui.gleam` via Mist HTTP + WebSocket.
- **Notification channel** (`web/protocol.gleam`) carrying typed events: `ToolNotification`, `SafetyNotification`, `QueueNotification`, `SaveNotification`, etc.
- **Thinking overlay** — full-tab `<div id="thinking-overlay">` at z-index 10, 40% opacity wash (`html.gleam:1667`). Plus a `.thinking` text element with three animated dots and "Thinking".
- **Cognitive loop** emits rich status events during a cycle: classification result, agent delegations, tool calls, D' gate decisions, agent completions, token counts. Most reach the notification channel but none render during the "thinking" state.
- **Affect telemetry** — 5-dimensional snapshot (`desperation, calm, confidence, frustration, pressure`) computed after every cycle. Snapshot is sent to the Curator via `UpdateAffectSnapshot`. Never leaves the Curator today.
- **Sensorium** — assembled every cycle. Rich internal state. Not surfaced to the web UI outside of what ends up in the system prompt.

### What's missing

- A live view of what's happening during a reply.
- A view of past conversations.
- Any surface for the affect signal.
- A sense that the agent is continuous and present between interactions.

---

## 3. The four slices

Numbered by implementation order. Each ships independently.

### Slice A — Live status strip (and drop the overlay)

**What it does**: replaces the full-tab grey overlay with a compact strip at the top of the chat tab that surfaces what Curragh is actually doing during a reply.

**Visual**:

```
┌────────────────────────────────────────────────────────────────────────┐
│ Researcher · brave_answer · turn 2/8 · 4.2k tokens · 12s  ●  cancel    │
└────────────────────────────────────────────────────────────────────────┘
```

When Idle: strip is hidden.
When Thinking (cognitive loop LLM call): `Curragh · thinking · 2.1k tokens · 3s`
When WaitingForAgents: `Researcher · web_search · turn 2/8 · 4.2k tokens · 12s` (updates as the agent progresses)
When EvaluatingSafety: `Curragh · safety gate · 1s`
Multiple parallel agents: strip rotates through them, or compacts to `3 agents running · 11s`.

**Input is not blocked**. The operator can type the next message and hit send; it queues (existing `QueueNotification`). The strip shows current state regardless.

**Cancel button** (right side) sends a `cancel_agent` instruction. Already supported by the cognitive loop; just needs a UI affordance.

**Data**: reuses existing notifications (`tool_calling`, agent lifecycle events, `SafetyNotification`). One small addition: `AgentProgress` notification carrying `agent_name, turn, max_turns, tokens, tool_name, elapsed_ms`. The agent framework already emits progress internally for the sensorium; relaying to the web UI is a few lines in `curator.gleam`.

**Protocol additions** (`web/protocol.gleam`):

```gleam
pub type ServerMessage {
  // existing variants...
  AgentProgressNotification(
    agent_name: String,
    turn: Int,
    max_turns: Int,
    tokens: Int,
    current_tool: Option(String),
    elapsed_ms: Int,
  )
  StatusTransition(
    status: String,  // "idle" | "thinking" | "waiting_for_agents" | "evaluating_safety" | "waiting_for_user"
    detail: Option(String),
  )
}
```

**Cost**: ~80 lines in `html.gleam` + ~30 in `protocol.gleam` + ~20 in `gui.gleam` relay.

### Slice B — Inline status bubble + typewriter reveal

**What it does**: replaces the "Thinking…" three-dot element with a live status bubble that shows each react-loop step, then morphs into the final answer with a typewriter reveal.

**Visual — mid-cycle**:

```
┌── Curragh ───────────────────────────┐
│  classifying query…                  │
│  → researcher (turn 1/8)             │
│  → brave_answer                      │
│  → synthesizing…                     │
└──────────────────────────────────────┘
```

Each react-loop turn appends a new line. Tool calls show inline. The bubble is visually an assistant message; when the final reply arrives, its content replaces the bubble and renders with a typewriter animation (~200–400ms total, not per character — just enough to feel alive).

This addresses the between-call gaps that streaming can't touch. When the first LLM call finishes and tools dispatch, the bubble says `running brave_answer…` instead of going quiet.

**Typewriter**: character-by-character reveal with a CSS animation, total duration 300ms regardless of length. Pure visual; response is already fully received. No backend changes.

**Cost**: ~50 lines JS in `html.gleam` + ~30 CSS.

### Slice C — Chat history sidebar

**What it does**: a collapsible left sidebar showing past conversations grouped by day. Click to open a read-only view. Immutable.

**Visual**:

```
┌─── History ────────┐─────────────────────────────────────────
│ Today              │  [live chat area]
│   meta-learning... │
│                    │
│ Yesterday          │
│   paper review     │
│   writer agent fix │
│                    │
│ Apr 15             │
│   daily briefing   │
│                    │
│ Apr 14             │
│   legal research   │
│                    │
│ [🔍 search…]       │
│ [thread filter ▾]  │
└────────────────────┘─────────────────────────────────────────
```

**Grouping**: by day (default). Toggle at the top switches to thread view — groups by narrative thread (`thread.thread_name`), most-recently-active first.

**Day summaries**: one-line per day, auto-generated from that day's narrative entries. Cheap: pick the most significant entry (by `outcome.confidence` × `metrics.tool_calls` or similar) and show its `intent.description`. Or fall back to a concatenation of entry summaries truncated to one line. Generated at open-time, not cached — same day's summary may change as the day progresses.

**Clicking a day** opens a read-only view in the main chat area:
- Messages rendered in order as they were (cycle logs have input/output text).
- Tool calls shown inline in a collapsed form (`Researcher used brave_answer · 12 results`).
- Agent delegations collapsed by default, expandable.
- D' gate decisions shown as small inline badges.
- No input box — it's read-only.
- Header: `Wednesday 16 April — 23 cycles · 4 threads · [Continue this conversation]`.

**Continue this conversation**: button switches back to live chat and prepends a brief context message (summary of the day + "continuing from this session") to the agent's next prompt. Curragh already has `recall_recent` — no new tooling needed; just seed the prompt.

**Search**: keyword filter across all days. Matches the same search surface as `recall_search` but runs client-side over the loaded history (limited to last 30 days by default; explicit "load more" button).

**Thread filter**: dropdown of active + recent thread names. Selecting one filters the sidebar to days where that thread appeared.

**Immutability**: read-only view is not editable. Messages can't be deleted or altered — consistent with append-only narrative. If the operator wants to retract something, they use the existing memory supersession tools.

**Protocol additions**:

```gleam
pub type ClientMessage {
  // existing variants...
  RequestHistoryIndex(from_date: String, to_date: String)
  RequestHistoryDay(date: String)
  RequestHistorySearch(query: String, from_date: String, to_date: String)
}

pub type ServerMessage {
  // existing variants...
  HistoryIndex(days: List(DaySummary))
  HistoryDay(date: String, cycles: List(CycleView))
  HistorySearchResults(matches: List(SearchMatch))
}
```

**Cost**: ~200 lines across `html.gleam` (sidebar + read-only renderer) + `protocol.gleam` (4 new message types) + `gui.gleam` (handlers that query the narrative log and cycle log).

### Slice D — Affect-driven ambient background

**What it does**: a slow gradient wash behind the chat and nav, driven by the agent's affect and cognitive status. Turns the UI into a window onto the agent's interior.

**Visual**: a fixed-position layer behind the normal UI, CSS custom properties driving hue, saturation, and animation rhythm. Baseline is a soft grey-blue. Under load, the wash warms toward magenta; when calm, it cools; when confident, it brightens slightly. When Idle, a barely-perceptible breathing animation (~7s cycle, 5% opacity swing). When Thinking, the rhythm shifts to ~2s with slightly higher contrast.

**Mapping**:

| Source signal | Visual effect | Default value |
|---|---|---|
| `calm` dimension | Saturation of gradient (0.0–1.0 → 20%–80% saturation) | 50% |
| `pressure` dimension | Hue shift (cool blue → warm magenta) | cool |
| `confidence` dimension | Brightness / opacity (0.0–1.0 → 0.6–0.9) | 0.75 |
| `frustration` dimension | Added red tinge above threshold 0.6 | none |
| `novelty` (from sensorium) | Subtle grain / shimmer when > 0.5 | none |
| `CognitiveStatus` | Breathing rhythm: Idle ~7s / Thinking ~2s / WaitingForAgents ~3s / WaitingForUser ~7s | Idle rhythm at startup |

**CSS custom properties**:

```css
:root {
  --affect-hue: 220deg;           /* cool blue default */
  --affect-saturation: 40%;
  --affect-lightness: 55%;
  --affect-opacity: 0.08;
  --breathing-duration: 7s;
}

#ambient-layer {
  position: fixed;
  inset: 0;
  z-index: -1;
  background: radial-gradient(
    circle at center,
    hsl(var(--affect-hue), var(--affect-saturation), var(--affect-lightness))
      var(--affect-opacity),
    transparent 70%
  );
  animation: breathe var(--breathing-duration) ease-in-out infinite;
  transition: background 3s ease, --breathing-duration 1.5s ease;
  pointer-events: none;
}

@keyframes breathe {
  0%, 100% { opacity: 0.8; }
  50%      { opacity: 1.0; }
}

@media (prefers-reduced-motion: reduce) {
  #ambient-layer { animation: none; }
}
```

**Protocol additions**:

```gleam
pub type ServerMessage {
  // existing variants...
  AffectTick(
    desperation: Float,
    calm: Float,
    confidence: Float,
    frustration: Float,
    pressure: Float,
    novelty: Float,
    status: String,
  )
}
```

**JS update** (in `html.gleam`): listener that takes an `AffectTick` and sets the six CSS custom properties. Transitions handle the smooth interpolation between readings.

**Source**: the Curator already receives `UpdateAffectSnapshot` from the affect monitor. Forward it to the notification channel once per cycle. Single-line change in the affect hook path.

**Cost**: ~40 lines CSS + ~30 JS + ~15 protocol + ~30 Curator relay. ~120 total.

---

## 4. Cross-cutting concerns

### Accessibility

- `prefers-reduced-motion: reduce` → freeze all animations (breathing, typewriter, gradient transitions become instant).
- Status strip is keyboard-accessible. Cancel button has a focus ring and an `aria-label`.
- History sidebar is keyboard-navigable; day items are `<button>` not `<div onclick>`.
- Read-only history view preserves the same markup as the live chat for screen readers — no role changes, just an absence of the input element.
- The ambient background is `aria-hidden="true"` and `pointer-events: none`. Screen readers ignore it entirely.

### Motion budget

- Ambient breathing: ≥6s cycle, ≤8% opacity swing. Anything faster is a screensaver.
- Typewriter reveal: total duration ≤400ms, single animation, no repeat.
- Status-strip updates: transition 150ms for text changes, instant for structural (status transitions).
- No element animates both position and colour simultaneously.

### Theming

- Light and dark theme both supported. The affect mapping uses HSL values so the mapping is theme-agnostic (hue rotation behaves consistently; saturation/lightness bounds adjust per theme).
- CSS custom properties for all colours. No hex literals in new code.

### Performance

- `AffectTick` fires once per cycle (not per-turn). Modest bandwidth.
- Status-strip updates: one per notification, max ~20 per cycle. Well under 1 KB/s in practice.
- History loading: day-at-a-time, capped at 30 days initial load, explicit "load more" for older. No unbounded preload.
- Typewriter uses CSS `animation` not JS — GPU-composited, cheap.

### Theming the "feel"

This is the point of the whole spec. The agent should feel:

- **Present** — ambient background never fully still while the agent is running.
- **Working** — status strip shows what's happening; no dead time.
- **Continuous** — history is always a click away; conversations don't vanish.
- **Honest** — every visual element reflects real internal state.

---

## 5. Data model / protocol summary

New `ServerMessage` variants (emitted by the server):

- `AgentProgressNotification(agent_name, turn, max_turns, tokens, current_tool, elapsed_ms)`
- `StatusTransition(status, detail)`
- `HistoryIndex(days: List(DaySummary))`
- `HistoryDay(date, cycles: List(CycleView))`
- `HistorySearchResults(matches)`
- `AffectTick(desperation, calm, confidence, frustration, pressure, novelty, status)`

New `ClientMessage` variants (emitted by the browser):

- `RequestHistoryIndex(from_date, to_date)`
- `RequestHistoryDay(date)`
- `RequestHistorySearch(query, from_date, to_date)`

New types:

```gleam
pub type DaySummary {
  DaySummary(
    date: String,
    cycle_count: Int,
    thread_count: Int,
    summary: String,   // one-line auto-generated
    last_activity: String,  // ISO timestamp
  )
}

pub type CycleView {
  CycleView(
    cycle_id: String,
    timestamp: String,
    user_text: String,
    assistant_text: String,
    tool_calls: List(ToolCallView),   // collapsed summaries
    delegations: List(DelegationView), // collapsed
    dprime_gates: List(GateDecisionView), // badge-sized
  )
}
```

---

## 6. Implementation order

Four slices, ~400–500 lines total. Ship in any order; each is independent.

| Slice | What | Lines | Ships first when |
|---|---|---|---|
| A | Status strip + drop overlay | ~130 | Pain is most acute — "dead interface during reply" is the loudest bug |
| B | Inline status bubble + typewriter | ~80 | After A; the bubble uses the same notification stream |
| C | Chat history sidebar | ~200 | Independent; ship whenever |
| D | Affect-driven ambient background | ~120 | Independent; "ship with whichever feels right" |

**Recommended**: A + B in one PR (they share notification plumbing), C as its own PR, D standalone.

**Alternative**: all four as one attentiveness PR (~500 lines) with a clean commit per slice. More testing surface at once but one coherent landing.

---

## 7. Testing

### Unit

- Protocol encode/decode tests for each new message type (add to `test/web/protocol_test.gleam`).
- Day-summary generation tests (pure function over `List(NarrativeEntry)`).
- Status-transition mapping tests (pure function from CognitiveStatus to string label).

### Integration

- Boot the web GUI in test mode, send a series of notifications, assert the rendered DOM matches expectations using a headless browser (new test harness). Optional but valuable.
- History endpoint tests: seed the narrative log with known entries, query day index, assert the summary and counts.

### Manual / observational

- Run the UI for a day with real work, watch the status strip and affect background. Sanity-check that the signals track actual state.
- Accessibility audit: keyboard navigation through every new control; `prefers-reduced-motion` freezes all animation.
- Test on slow network (2G throttle) — status strip should still update smoothly via WebSocket.

---

## 8. Risks

| Risk | Mitigation |
|---|---|
| Status strip distracts from reading the chat | Single line, top of tab, muted colour. Fades to 50% opacity when Idle. |
| Affect background triggers motion sickness | `prefers-reduced-motion` freezes it. Ambient animation is ≥6s cycle, ≤8% opacity swing. |
| History sidebar eats screen space | Collapsible, collapsed by default on narrow viewports. Keyboard shortcut to toggle. |
| Affect signal is miscalibrated → background shows wrong mood | Honest failure mode — the operator reads it the same way they'd read any other telemetry. Miscalibration is a separate concern in the affect engine, not this UI. |
| Typewriter animation feels patronising | 300ms total, not per-character. `prefers-reduced-motion` disables. If people hate it, remove in a follow-up — cheap. |
| WebSocket message volume increases (AffectTick, AgentProgress) | All sub-1 KB, rate-capped at ~20/sec max. No-op on modern networks. |
| History-day load is slow for large narrative archives | Paginate: load 30 days by default, "load more" for older. Server-side filter by date range. |

---

## 9. What this doesn't do

- **Token streaming.** Deliberately out of scope. Spec-level rationale: the D' output gate inspects finished outputs, the react loop is multi-call so streaming only covers gaps within a single call, and the real deficit is "I don't know what's happening" — which the status strip addresses better than streamed text. See discussion on branch history.
- **Admin panel.** The audit surfaces (strategies, skills, learning goals, affect-warning dashboard) are deferred to meta-learning Phase 10.
- **Mobile UX.** Current CSS is desktop-first. Mobile layout adjustments (sidebar becomes drawer, status strip stacks) are a follow-up.
- **Non-chat interactions.** This spec is chat-tab focused. Log and Narrative tabs get minor love from shared CSS changes but no structural additions.

---

## 10. Related work

- **Meta-learning spec** (`docs/roadmap/planned/meta-learning.md`) — Phase 10 admin UI will extend the history sidebar with learning-goal and strategy views.
- **Remembrancer followups** (`docs/roadmap/planned/remembrancer-followups.md`) — the superseded Memory Health panel is absorbed into the history sidebar's day-summary + meta-learning admin.
- **Affect monitoring** (`src/affect/`) — source of truth for `AffectTick`. No changes needed here, just a new consumer.

---

## 11. Scope gate

If building all four slices is too much, minimum viable is Slice A alone (~130 lines). Drops the dead overlay, surfaces tool + agent + progress. That's the loudest bug fixed. Everything else is additive.

The attentiveness isn't in any single slice — it's in the combination. But even one slice meaningfully improves the story.
