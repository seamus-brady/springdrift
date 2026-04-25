# Cognitive Loop — Implementation Record

**Status**: Implemented
**Date**: Core from project inception, major refactors 2026-03-15 onwards
**Source**: cognitive-refactor-spec.docx, 12-factor-agents design principles

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Message Types (`agent/types.gleam`)](#message-types-agenttypesgleam)
- [Cycle Flow](#cycle-flow)
- [CognitiveState](#cognitivestate)
- [CognitiveStatus](#cognitivestatus)
- [Model Selection and Fallback](#model-selection-and-fallback)
- [Context Management](#context-management)
- [Notification Channel](#notification-channel)


## Overview

The cognitive loop is Springdrift's central orchestrator — a single OTP process that receives user input, classifies complexity, routes through safety gates, calls the LLM, dispatches tools, delegates to sub-agents, and delivers responses. It implements a 12-Factor Agents style ReAct loop.

## Architecture

```
agent/cognitive.gleam        — Main loop: message handling, cycle management
agent/cognitive_state.gleam  — CognitiveState: all mutable state in one record
agent/cognitive_config.gleam — CognitiveConfig: startup configuration
agent/cognitive/llm.gleam    — LLM request building, model selection, meta intervention
agent/cognitive/agents.gleam — Tool dispatch, agent delegation, escalation
agent/cognitive/safety.gleam — D' gate spawning, result handling, rejection messaging
agent/cognitive/memory.gleam — Session persistence, save/load coordination
agent/cognitive/escalation.gleam — Mid-cycle model upgrade criteria
agent/worker.gleam           — Unlinked think workers with retry + exponential backoff
agent/framework.gleam        — Gen-server wrapper for agent specs → running processes
agent/supervisor.gleam       — Restart strategies (Permanent/Transient/Temporary)
agent/registry.gleam         — Pure data structure tracking agent status + tools
```

## Message Types (`agent/types.gleam`)

The cognitive loop's public API is the `CognitiveMessage` type:

| Message | Purpose |
|---|---|
| `UserInput(text, reply_to)` | User sends a message |
| `SchedulerInput(...)` | Scheduler-triggered autonomous cycle |
| `QueuedSensoryEvent(event)` | Ambient perception (forecaster, sandbox crashes) |
| `SetModel(model)` | Runtime model switch |
| `RestoreMessages(messages)` | Session restoration |
| `UserAnswer(answer)` | Response to `request_human_input` |
| `ThinkComplete(task_id, response)` | Worker finished LLM call |
| `ThinkError(task_id, error)` | Worker failed |
| `ThinkWorkerDown(task_id)` | Worker process died |
| `SafetyGateComplete(...)` | D' tool gate result |
| `InputSafetyGateComplete(...)` | D' input gate result |
| `OutputGateComplete(...)` | D' output gate result |
| `AgentComplete(...)` | Sub-agent finished |
| `AgentEvent(...)` | Agent lifecycle event |
| `AgentProgress(...)` | Agent turn progress |
| `SaveResult(...)` | Session save completed |
| `ClassifyComplete(...)` | Query complexity result |

## Cycle Flow

```
UserInput
  → Classify complexity (Simple/Complex) via LLM
  → Reset D' iteration counters
  → D' input gate (deterministic pre-filter → canary probes → LLM scorer)
    → REJECT: user sees friendly message, agent sees technical notice
    → ACCEPT: continue
  → Consume meta intervention (InjectCaution, TightenAllGates, ForceCooldown, EscalateToUser)
  → Select model (task_model for Simple, reasoning_model for Complex)
  → Build request (system prompt from Curator, context trim, tools)
  → Spawn think worker (with retry + exponential backoff)
  → ThinkComplete:
    → Text response (no tools):
      → D' output gate (deterministic → LLM scorer)
        → ACCEPT: deliver to user
        → MODIFY: revise (up to max_modifications), then deliver with warning
        → REJECT: user sees friendly message, agent told response wasn't delivered
      → Spawn Archivist (fire-and-forget narrative + CBR)
    → Tool calls:
      → Check D' exemption (memory, planner, builtin, agent delegations → skip D')
      → Non-exempt: D' tool gate (deterministic → LLM scorer)
        → ACCEPT: dispatch tools
        → REJECT: tool failure injected into message history
      → Execute tools, collect results
      → Check escalation criteria (tool failures, D' scores → model upgrade)
      → Loop: next think worker with tool results
    → Agent delegation:
      → Track in active_delegations
      → AgentProgress updates per turn
      → AgentComplete: review results, write back, continue
  → Apply meta observation (Layer 3b)
  → Save session
  → Idle
```

## CognitiveState

Single record holding all mutable state:

| Category | Fields |
|---|---|
| Core process | self, provider, notify |
| Model config | model, task_model, reasoning_model, max_tokens, archivist_model |
| Conversation | system, max_context_messages, tools, messages |
| Loop control | status, cycle_id, pending, save_in_progress, verbose |
| Memory | memory (MemoryContext: narrative_dir, cbr_dir, librarian, curator) |
| Agent subsystem | registry, agent_completions, active_delegations, supervisor |
| Cycle telemetry | cycle_tool_calls, cycle_started_ms, cycle_node_type |
| D' safety | input_dprime_state, tool_dprime_state, output_dprime_state, dprime_decisions |
| Input queue | input_queue, input_queue_cap |
| Sensory events | pending_sensory_events, active_task_id |
| Identity | identity (IdentityContext: agent_uuid, agent_name, session_since) |
| Runtime config | config (RuntimeConfig: retry, threading, memory_limits, escalation, deterministic, etc.) |
| Session counters | session_tool_calls, session_tool_failures, session_dprime_modifications, session_dprime_rejections, session_cycles, session_cbr_hits |
| CBR tracking | retrieved_case_ids |
| Meta observer | meta_state |

## CognitiveStatus

| Status | Meaning |
|---|---|
| Idle | Waiting for input |
| Thinking(task_id) | LLM call in progress |
| Classifying | Query complexity classification |
| WaitingForAgents | Sub-agent(s) working |
| WaitingForUser | Waiting for `request_human_input` answer |
| EvaluatingSafety(...) | D' gate evaluation in progress |

## Model Selection and Fallback

1. **Initial**: Simple → task_model, Complex → reasoning_model
2. **Fallback**: On retryable error (500, 503, 529, 429, timeout) exhausting retries, fall back to task_model. Response prefixed with `[model_x unavailable, used model_y]`
3. **Escalation**: Mid-cycle upgrade from task_model to reasoning_model when tool failures or D' scores exceed thresholds

## Context Management

- Full history always stored in `CognitiveState.messages` and on disk
- `context.trim` applied only inside `build_request` (sliding window)
- Per-agent `max_context_messages` on AgentSpec (e.g. Researcher uses 30)
- Session persistence via `storage.save`/`storage.load` to `session.json`

## Notification Channel

Pure data types (`Notification`) with no embedded Subject references:
- AssistantReply, ToolCalling, SafetyGateNotice, ModelEscalation
- AgentStarted, AgentCrashed, AgentRestarted, AgentStopped
- SchedulerJobStarted, SchedulerJobCompleted, SchedulerJobFailed
- SandboxStarted, SandboxContainerFailed, SandboxUnavailable
- InputQueued, InputQueueFull, SaveWarning

Forwarded to TUI and web GUI via relay process.
