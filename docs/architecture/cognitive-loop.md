# Cognitive Loop Architecture

The cognitive loop is Springdrift's central orchestration process. It receives
input (user messages, scheduler triggers, sensory events), coordinates query
classification, safety evaluation, LLM calls, tool dispatch, agent delegation,
and output delivery. All other subsystems -- agents, safety, memory, scheduling
-- are wired through the cognitive loop.

---

## 1. Process Model

The cognitive loop is a single OTP process (`src/agent/cognitive.gleam`) started
via `cognitive.start(cfg)`. It receives a `CognitiveConfig` record and spawns
an unlinked process that runs an infinite `cognitive_loop(state)` tail-recursive
loop, selecting on its own `Subject(CognitiveMessage)`.

```
cognitive.start(cfg) → spawn_unlinked → cognitive_loop(state)
                                          ↓
                                     selector.receive_forever
                                          ↓
                                     handle_message(state, msg)
                                          ↓
                                     maybe_drain_queue(next_state)
                                          ↓
                                     cognitive_loop(next_state)
```

There is no shared mutable state. All cross-process communication uses typed
`Subject(T)` channels.

## 2. CognitiveState

Defined in `src/agent/cognitive_state.gleam`. The state record carries everything
the loop needs, organised into logical groups:

| Group | Fields | Mutability |
|---|---|---|
| Core process | `self`, `provider`, `notify` | Read-only after init |
| Model config | `model`, `task_model`, `reasoning_model`, `thinking_budget_tokens`, archivist/appraiser models | `model` switches per-cycle |
| Conversation | `system`, `max_context_messages`, `tools`, `messages` | Messages grow each cycle |
| Loop control | `status`, `cycle_id`, `pending`, `verbose` | Status transitions per cycle |
| Memory context | `narrative_dir`, `cbr_dir`, `librarian`, `curator` | Read-only after init |
| Agent subsystem | `registry`, `agent_completions`, `active_delegations`, `supervisor` | Updated on agent events |
| Cycle telemetry | `cycle_tool_calls`, `cycle_started_ms`, `cycle_tokens_in/out`, `cycle_node_type` | Reset each cycle |
| D' safety | `input_dprime_state`, `tool_dprime_state`, `output_dprime_state`, `dprime_decisions` | Isolated per gate type |
| Input queue | `input_queue`, `input_queue_cap` | Queue grows when busy |
| Sensory events | `pending_sensory_events` | Accumulated between cycles |
| Identity | `agent_uuid`, `agent_name`, `session_since`, `write_anywhere` | Read-only after init |
| Runtime config | `retry_config`, `classify_timeout_ms`, `threading_config`, ... | Read-only after init |
| Meta observer | `meta_state` | Updated post-cycle |
| Drift tracking | `drift_state` | Updated post-output-gate |

State is split into sub-records (`MemoryContext`, `IdentityContext`, `RuntimeConfig`)
for clarity and to signal which parts are immutable after startup.

## 3. Message Types

The cognitive loop's public API surface is the `CognitiveMessage` type
(`src/agent/types.gleam`). Every capability is a message variant:

| Message | Source | Purpose |
|---|---|---|
| `UserInput(text, reply_to)` | TUI / Web GUI | User typed a message |
| `SchedulerInput(job_name, query, kind, for_, ...)` | Scheduler | Autonomous cycle trigger |
| `UserAnswer(answer)` | TUI / Web GUI | Response to `request_human_input` |
| `SetModel(model)` | TUI | Switch active model |
| `GetMessages(reply_to)` | Storage | Retrieve conversation history |
| `ClassifyComplete(cycle_id, complexity, text, reply_to)` | Classification worker | Query complexity result |
| `ThinkComplete(task_id, resp)` | Think worker | LLM response arrived |
| `ThinkError(task_id, error, retryable)` | Think worker | LLM call failed |
| `ThinkWorkerDown(task_id, reason)` | Monitor | Think worker process died |
| `AgentComplete(outcome)` | Agent framework | Agent finished work |
| `AgentProgress(progress)` | Agent framework | Agent turn update |
| `AgentQuestion(question, agent, reply_to)` | Agent framework | Agent needs human input |
| `AgentEvent(event)` | Supervisor | Lifecycle event (started/crashed/restarted/stopped) |
| `SafetyGateComplete(...)` | Safety worker | Tool gate result |
| `InputSafetyGateComplete(...)` | Safety worker | Input gate result |
| `PostExecutionGateComplete(...)` | Safety worker | Post-exec gate result |
| `OutputGateComplete(...)` | Safety worker | Output gate result |
| `GateTimeout(task_id, gate)` | `send_after` timer | Gate evaluation timed out |
| `WatchdogTimeout(generation)` | `send_after` timer | Stuck status recovery |
| `SetSupervisor(supervisor)` | Startup | Wire supervisor subject |
| `QueuedSensoryEvent(event)` | Forecaster / Poller | Ambient perception event |
| `ForecasterSuggestion(...)` | Forecaster | Plan health alert |

## 4. Status Machine

`CognitiveStatus` tracks what the loop is currently doing. Only one status
is active at a time:

```
         UserInput
            │
            ▼
     ┌─────────────┐
     │  Classifying │ ──── async query complexity
     └──────┬──────┘
            │ ClassifyComplete
            ▼
     ┌──────────────────┐
     │ EvaluatingSafety  │ ──── input D' gate (if enabled)
     └───────┬──────────┘
             │ InputSafetyGateComplete
             ▼
     ┌─────────────┐
     │   Thinking   │ ──── LLM call via think worker
     └──────┬──────┘
            │
        ┌───┴───┐
        ▼       ▼
   [text]    [tool calls]
     │          │
     │    ┌─────────────────┐
     │    │ EvaluatingSafety │ ──── tool D' gate (if enabled)
     │    └───────┬─────────┘
     │            │
     │    ┌───────────────────┐
     │    │ WaitingForAgents  │ ──── parallel agent dispatch
     │    └───────┬───────────┘
     │            │ AgentComplete (all)
     │            ▼
     │      [re-think with results]
     │            │
     ├────────────┘
     ▼
[output gate] ──── autonomous cycles only (full), interactive (deterministic only)
     │
     ▼
  ┌──────┐
  │ Idle │ ──── drain queue, wait for next input
  └──────┘
```

**Watchdog**: every non-Idle transition starts a watchdog timer
(`gate_timeout_ms * 3`). If the loop is still non-Idle when the watchdog fires
(same generation), it forces recovery to Idle. This prevents permanent stuck
states from dropped messages.

## 5. Cycle Lifecycle

### User input cycle

1. **Guard** -- if not Idle, queue the input (up to `input_queue_cap`).
2. **Reset cycle state** -- clear agent completions, tool calls, tokens, D' decisions.
   Reset per-cycle D' iteration counters. Clear Curator scratchpad.
3. **Classify** -- spawn unlinked worker: `query_complexity.classify(text, provider,
   task_model, timeout)`. On timeout or panic, falls back to `Simple`.
4. **ClassifyComplete** -- `Complex` switches to `reasoning_model`; `Simple` stays
   on `task_model`. If input D' gate is enabled, evaluate input safety.
5. **Input safety** -- fast-accept path: deterministic rules → canary probes → accept.
   On escalation: full LLM scorer. On reject: reply with rejection notice.
6. **Build request** -- Curator assembles system prompt (persona + sensorium + memory).
   Context trim applied. Tools attached.
7. **Think** -- spawn think worker with retry (`call_with_retry`). Worker sends
   `ThinkComplete` or `ThinkError`.
8. **ThinkComplete** -- if text response: proceed to output gate. If tool calls:
   evaluate tool safety gate, then dispatch.
9. **Tool dispatch** -- agent tool calls go to supervisor; memory/planner tools
   execute inline; team tools spawn team orchestrator.
10. **Agent completion** -- results accumulated in `WaitingForAgents`. When all
    complete, results combined into a user message, loop re-thinks.
11. **Output gate** -- interactive: deterministic rules only. Autonomous: full D'
    evaluation + normative calculus.
12. **Deliver** -- send `CognitiveReply(response, model, usage)` to reply subject.
    Spawn Archivist. Post-cycle meta observer. Transition to Idle.
13. **Drain queue** -- if Idle and queue non-empty, process next queued input.

### Scheduler input cycle

Scheduler inputs (`SchedulerInput`) skip query classification, always use
`task_model`, and prepend `<scheduler_context>` XML with job metadata. DAG nodes
are tagged with `SchedulerCycle` (vs `CognitiveCycle` for interactive). The
scheduler reports `JobComplete` with `tokens_used` for budget tracking.

## 6. Model Switching and Fallback

The loop maintains three model references:

- `task_model` -- used for Simple queries and all scheduler cycles
- `reasoning_model` -- used for Complex queries (detected by classifier)
- `model` -- the currently active model for the cycle (set during classification)

**Fallback**: when a retryable error (500, 503, 529, 429, network, timeout) exhausts
worker retries and the failed model isn't `task_model`, the loop falls back to
`task_model`. The response is prefixed with
`[model_x unavailable, used model_y]`.

## 7. Input Queue

When the loop is busy (status != Idle), incoming `UserInput` and `SchedulerInput`
messages are queued as `QueuedInput` variants:

- `QueuedInput(text, reply_to)` -- user input
- `QueuedSchedulerInput(job_name, query, ...)` -- scheduler input
- `QueuedSensoryInput(event)` -- sensory events (don't trigger cycles)

Queue capacity is bounded by `input_queue_cap` (default 10). When full, the input
is rejected and `InputQueueFull` notification is sent.

`maybe_drain_queue` runs after every message handler returns. If Idle and the queue
is non-empty, it processes the next item immediately. Sensory events are drained
without triggering cycles -- they accumulate in `pending_sensory_events`.

## 8. Context Management

Full message history is always stored in `CognitiveState.messages` and persisted
to disk. Context trimming is applied only inside `build_request` before the LLM
call via `context.trim`. This preserves complete history while keeping LLM context
windows manageable.

Agent frameworks apply their own `context.trim` per-agent via `max_context_messages`
on `AgentSpec` (e.g. Researcher uses 30 to stay lean during multi-turn web research).

## 9. Cycle Telemetry

Every cycle tracks:

- `cycle_id` -- UUID, used as DAG node ID and cycle log key
- `cycle_tool_calls` -- list of `ToolSummary` (name, duration_ms, success)
- `cycle_started_ms` -- monotonic timestamp for elapsed time calculation
- `cycle_tokens_in`, `cycle_tokens_out` -- accumulated token usage
- `cycle_node_type` -- `CognitiveCycle` or `SchedulerCycle`
- `dprime_decisions` -- all D' gate decisions made during the cycle

This data feeds into DAG nodes (via cycle log), the Archivist (for narrative
generation), and the sensorium (for ambient perception).

## 10. Sensory Events

`SensoryEvent` is a lightweight ambient perception channel. Events accumulate in
`pending_sensory_events` between cycles and are drained into the Curator's
`CycleContext` at cycle start, then rendered as `<events>` in the sensorium XML.

Events never trigger a cycle. They are consumed passively. Sources include:
- Forecaster replan suggestions
- Inbox poller (new email detected)
- Canary probe degradation notices

## 11. Source File Organisation

The cognitive loop is split across several modules:

| File | Responsibility |
|---|---|
| `agent/cognitive.gleam` | Entry point, core loop, message dispatch, user input handling |
| `agent/cognitive_state.gleam` | `CognitiveState` record + sub-records (`MemoryContext`, etc.) |
| `agent/cognitive_config.gleam` | `CognitiveConfig` startup configuration |
| `agent/cognitive/agents.gleam` | Agent dispatch, completion handling, team orchestration |
| `agent/cognitive/safety.gleam` | D' gate evaluation, input/tool/output gate handlers |
| `agent/cognitive/llm.gleam` | LLM request building, think error/worker-down handlers |
| `agent/cognitive/memory.gleam` | Session save/restore, gate message filtering |
| `agent/cognitive/escalation.gleam` | Escalation config for agent oversight |
