# Frontdoor — separating the cognitive loop from its communication channels

**Status**: Shipped 2026-04-21 (PR #90) + adapter wire-up completed (PR #92)

## Problem

The cognitive loop today is wired directly into whichever communication
channel originated a request. Every `UserInput`, `SchedulerInput`, and
`AgentQuestion` message carries a `reply_to: Subject(CognitiveReply)` that
points straight at the caller. The cognitive loop sends replies into that
subject. The caller owns the reply subject and decides what to do with it.

This coupling creates a class of bugs and design frictions:

1. **Questions broadcast to the wrong mouth.** `QuestionForHuman` is emitted
   as a *notification* (via the shared `notify` channel) because the
   cognitive loop doesn't know which connection — if any — should receive
   it. The notification layer broadcasts it to every open WebSocket, even
   if the question was raised inside an autonomous scheduler cycle where no
   human is expected to answer. Each browser dutifully sets
   `waitingForAnswer = true`, the next chat message is dispatched as
   `user_answer`, and the answer is routed into the stashed
   `reply_to` of whichever cycle stashed last — possibly the scheduler's
   throwaway subject, not the user's WebSocket.

2. **Replies delivered to the wrong caller.** Because the scheduler's
   autonomous cycle and a queued interactive user cycle both end up in the
   same cognitive loop with their own `reply_to` subjects, any internal
   state-threading bug that mis-associates `reply_to` with cycle is
   effectively undiagnosable — the cognitive loop can only "send to
   whoever was passed in."

3. **No way to route by destination policy.** Delivery rules (drop, modify,
   fan-out) can't live in the caller because the caller is one of many
   equivalent shells. They can't live in the cognitive loop either because
   that's the thing we're trying to keep abstract. There's no third place.

The agent needs a mouth — an explicit output surface — not a brain wired
directly into every listener.

## Shape

Add a supervised OTP actor, `Frontdoor`, that is the sole intermediary
between the cognitive loop and every external communication channel. The
cognitive loop stops carrying `reply_to` on externally-facing message
variants and instead publishes structured outputs to a single subject.
Frontdoor owns the routing policy.

```
   ┌─ WS connections (one source_id each)
   │
   │     (register/deliver)
   ▼
┌──────────────┐   inbound       ┌────────────┐
│              │ ──────────────▶ │            │
│  Frontdoor   │                 │ Cognitive  │
│              │ ◀────────────── │            │
└──────────────┘   output        └────────────┘
   ▲
   │     (register/deliver)
   │
   ├─ TUI (source_id = "tui")
   ├─ Scheduler waiter (source_id = "scheduler:<job>:<uuid>")
   └─ Comms poller (source_id = "comms:<msg_id>")
```

Key properties:

- **One output subject.** Cognitive publishes every outbound event to
  `output_channel: Subject(CognitiveOutput)`. Frontdoor subscribes.

- **Source-tagged inputs.** Inbound messages carry a `source_id: String`,
  not a `reply_to` subject. The source_id is opaque to cognitive — it's
  just a token that flows back out with each output.

- **Cycle → source mapping.** Frontdoor maintains
  `cycle_owners: Dict(cycle_id, source_id)`. When cognitive starts a cycle
  for a given source_id, it tells Frontdoor. When an output for that
  cycle_id appears, Frontdoor looks up the source_id and forwards to the
  registered destination.

- **Source-aware delivery policy.** Questions raised inside a scheduler
  cycle have no human source to route to. Frontdoor drops them and
  synthesises a `no_human_available` tool result back to cognitive, so the
  LLM can continue without hanging on a broadcast nobody will answer. This
  is the concrete fix for the current bug.

- **Notification fan-out unchanged for now.** Notifications (`ToolCalling`,
  `AgentProgressNotice`, `StatusChange`, etc.) stay on the existing
  `notify` channel that the web GUI already listens to. Frontdoor owns
  only the *reply / question* channel, which is the part currently coupled
  via `reply_to`.

## Types

```gleam
// src/frontdoor/types.gleam

pub type SourceId = String  // opaque token identifying a destination

pub type SourceKind {
  UserSource          // interactive — browser WS, TUI
  SchedulerSource     // autonomous — scheduler runner, comms poller
}

/// Everything cognitive publishes for external consumption.
pub type CognitiveOutput {
  /// Final reply for a cycle.
  CognitiveReplyOutput(
    cycle_id: String,
    response: String,
    model: String,
    usage: Option(Usage),
    tools_fired: List(String),
  )
  /// Question raised for a human (cognitive tool or sub-agent).
  HumanQuestionOutput(
    cycle_id: String,
    question: String,
    question_id: String,   // correlate answer → question
    origin: QuestionOrigin,
  )
  /// Cognitive state change (used where a channel needs to re-open input).
  StatusOutput(cycle_id: Option(String), status: StatusKind)
}

pub type QuestionOrigin {
  CognitiveLoopOrigin
  AgentOrigin(agent_name: String)
}

/// What each destination receives from Frontdoor.
pub type Delivery {
  DeliverReply(cycle_id: String, reply: CognitiveReplyOutput)
  DeliverQuestion(cycle_id: String, question: HumanQuestionOutput)
  DeliverStatus(status: StatusOutput)
  DeliverClosed         // Frontdoor is shutting this source down
}

pub type FrontdoorMessage {
  // destination lifecycle
  Subscribe(source_id: SourceId, kind: SourceKind, sink: Subject(Delivery))
  Unsubscribe(source_id: SourceId)

  // inbound — Frontdoor assigns cycle_id, forwards to cognitive
  InboundUserMessage(source_id: SourceId, text: String)
  InboundUserAnswer(source_id: SourceId, question_id: String, text: String)
  InboundScheduler(
    source_id: SourceId,
    job_name: String,
    query: String,
    kind: JobKind,
    for_: ForTarget,
    title: String,
    body: String,
    tags: List(String),
  )

  // outbound — cognitive publishes these; Frontdoor routes
  Publish(output: CognitiveOutput)

  // cognitive → Frontdoor: "this cycle_id is for this source_id"
  ClaimCycle(cycle_id: String, source_id: SourceId)
}
```

## Message-flow walkthrough

**User types in /chat:**

1. WS connection starts → generates `source_id = "ws:<uuid>"` → sends
   `Subscribe(source_id, UserSource, own_sink)` to Frontdoor.
2. User sends text → WS sends `InboundUserMessage(source_id, text)` to
   Frontdoor.
3. Frontdoor generates `cycle_id`, sends `UserInput(source_id, cycle_id, text)`
   to cognitive (no `reply_to`).
4. Cognitive processes the cycle. Whenever it would have done
   `process.send(reply_to, CognitiveReply(...))`, it now does
   `process.send(output_channel, Publish(CognitiveReplyOutput(cycle_id, ...)))`.
5. Frontdoor receives `Publish`, looks up `cycle_owners[cycle_id] → source_id`,
   looks up `destinations[source_id] → sink`, sends `DeliverReply(...)`.
6. WS receives the delivery, renders the assistant message.

**Scheduler fires an autonomous job:**

1. Scheduler runner generates `source_id = "scheduler:<job>:<uuid>"`, sends
   `Subscribe(source_id, SchedulerSource, own_sink)` + `InboundScheduler(...)`
   to Frontdoor.
2. Frontdoor generates cycle_id, claims it for source_id, dispatches
   `SchedulerInput(source_id, cycle_id, ...)` to cognitive.
3. Cognitive runs the cycle. If the LLM calls `request_human_input`,
   cognitive publishes `HumanQuestionOutput(cycle_id, question, ..., origin=CognitiveLoopOrigin)`.
4. Frontdoor receives the publish, looks up source_id = "scheduler:<job>:<uuid>",
   sees `SchedulerSource` — **no human at this destination**.
5. Frontdoor synthesises a canned answer (`"No human available in this
   autonomous cycle. Proceed with your best estimate or return your current
   findings."`) and sends it back to cognitive as if it were a user answer
   on the matching `question_id`.
6. Cognitive continues the react loop with the synthesised answer. Scheduler
   cycle proceeds without hanging and without a broadcast to interactive
   clients.

**Mobile /m open at the same time:**

1. Has its own `source_id`, its own sink, its own `cycle_owners` entries.
2. Sees no question broadcast — Frontdoor only routes to the cycle's owner.
3. Sees no reply for the scheduler cycle — it's not the owner.
4. Sees its own cycle's replies as normal.

## Scope of change

**New module:**
- `src/frontdoor/types.gleam` — types above
- `src/frontdoor.gleam` — supervised OTP actor with routing state

**Changed types (`src/agent/types.gleam`):**
- `UserInput(text: String, reply_to: ...)` → `UserInput(source_id: String, cycle_id: String, text: String)`
- `UserAnswer(answer: String)` → `UserAnswer(source_id: String, question_id: String, answer: String)`
- `SchedulerInput(..., reply_to: ...)` → `SchedulerInput(source_id: String, cycle_id: String, ...)`
- `AgentQuestion(question, agent, reply_to: ...)` → `AgentQuestion(cycle_id: String, question_id: String, question: String, agent: String)`
- `QueuedInput` / `QueuedSchedulerInput` — carry source_id instead of reply_to
- Add `output_channel: Subject(Publish)` threading via CognitiveConfig/State

**Internal cognitive messages unchanged:**
- `ClassifyComplete`, `ThinkComplete`, gate callbacks — these are cognitive's
  internal plumbing. They keep `reply_to` fields but those are now internal
  subjects that route back into the cognitive loop's own machinery, not
  external channels.

**Cognitive loop changes:**
- `handle_user_input` / `handle_scheduler_input` / `handle_classify_complete`
  etc. stop passing `reply_to` through to `worker.spawn_think`. Instead they
  carry `cycle_id + source_id` through the PendingThink record.
- On cycle completion, publish `CognitiveReplyOutput` to `output_channel`
  with `cycle_id`.
- On `request_human_input` (own or agent), publish `HumanQuestionOutput`.
  The answer will come back from Frontdoor as `UserAnswer(source_id,
  question_id, text)` — correlate on `question_id`.

**Adapter changes:**
- `src/web/gui.gleam` — WS init registers a source_id with Frontdoor,
  subscribes to a `Delivery` sink. Replaces the `reply_subject` selector
  arm with a `delivery_subject` selector arm. UserMessage/UserAnswer frames
  relay through Frontdoor instead of dispatching directly to cognitive.
- `src/tui.gleam` — registers `source_id = "tui"` with Frontdoor. Replaces
  its direct cognitive dispatch with Frontdoor dispatch.
- `src/scheduler/runner.gleam` — `spawn_job` subscribes a per-job sink,
  sends `InboundScheduler`, receives delivery, unsubscribes.
- `src/comms/poller.gleam` — inbound emails go through Frontdoor as
  `InboundScheduler` equivalents.

**Test updates:**
- `test/agent/cognitive_test.gleam` — uses `reply_to` in fixture setup. Updated
  to route through a test Frontdoor helper.

## Migration strategy

Phases:

1. **Add Frontdoor module** (no callers yet). Types, actor, basic routing
   tests. Builds on its own.
2. **Add `output_channel` to cognitive**. Parallel path: cognitive keeps
   sending to `reply_to` *and* publishes to `output_channel`. Everything
   still works via the old path.
3. **Migrate web GUI** to receive via Frontdoor sink. Drop its direct
   `reply_subject`. Verify manually.
4. **Migrate TUI, scheduler, comms poller** in the same way.
5. **Remove `reply_to` from the three external message variants**. At this
   point nothing else reads them, so it's a pure cleanup.
6. **Implement question-drop policy** for SchedulerSource. This is the
   behavioural fix.
7. **Tests + PR.**

Each phase keeps the build green. Steps 1–4 are additive; step 5 is the
teardown.

## Out of scope (follow-up)

- Fan-out to multiple destinations for the same cycle (e.g. every connected
  browser sees every cycle's reply). Current behaviour delivers only to the
  originating source; fan-out would be a later policy change.
- Persistent source_ids that survive reconnection. Current design treats
  each WS connection as a fresh source_id.
- Slack / email / webhook destinations as first-class Frontdoor sinks.
  Possible later; requires no further cognitive changes.
