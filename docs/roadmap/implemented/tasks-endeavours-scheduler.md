# Tasks, Endeavours, and Scheduler — Implementation Record

**Status**: Implemented
**Date**: 2026-03-17 to 2026-03-22

---

## Table of Contents

- [Overview](#overview)
- [Tasks](#tasks)
  - [Data Model (`planner/types.gleam`)](#data-model-plannertypesgleam)
  - [Tools (`tools/planner.gleam`)](#tools-toolsplannergleam)
  - [Planner Agent](#planner-agent)
- [Endeavours](#endeavours)
  - [Data Model](#data-model)
  - [Tools](#tools)
- [Scheduler](#scheduler)
  - [Architecture (`scheduler/runner.gleam`)](#architecture-schedulerrunnergleam)
  - [Job Types](#job-types)
  - [Delivery (`scheduler/delivery.gleam`)](#delivery-schedulerdeliverygleam)
  - [Persistence (`scheduler/persist.gleam`)](#persistence-schedulerpersistgleam)
  - [Resource Limits](#resource-limits)
  - [Scheduler Agent (`agents/scheduler.gleam`)](#scheduler-agent-agentsschedulergleam)
  - [Notifications](#notifications)
- [Forecaster](#forecaster)
  - [Architecture (`planner/forecaster.gleam`)](#architecture-plannerforecastergleam)
  - [Configuration](#configuration)
- [Sensorium Integration](#sensorium-integration)


## Overview

Goal tracking system (Tasks + Endeavours), BEAM-native scheduler for autonomous cycles, and Forecaster for plan health evaluation. Enables the agent to manage its own work, schedule recurring tasks, and detect when plans need revision.

## Tasks

A Task is a unit of planned work with steps, dependencies, risks, and a forecast health score.

### Data Model (`planner/types.gleam`)
- `PlannerTask`: task_id, title, description, status, plan_steps, dependencies, risks, forecast_score, cycles
- `PlanStep`: description, status (pending/complete/failed), dependencies
- Status lifecycle: Pending → Active → Complete / Failed / Abandoned
- Persisted as append-only JSONL operations in `.springdrift/memory/planner/YYYY-MM-DD-tasks.jsonl`

### Tools (`tools/planner.gleam`)
| Tool | Purpose |
|---|---|
| `complete_task_step` | Mark a step as done |
| `flag_risk` | Record a materialised risk |
| `activate_task` | Move from Pending to Active |
| `abandon_task` | Stop tracking a task |
| `get_active_work` | List active tasks and endeavours |
| `get_task_detail` | Full detail: steps, risks, forecast |

### Planner Agent
- Auto-creates Tasks via output hook in `cognitive/agents.gleam`
- max_turns=3, no tools (pure planning)
- Permanent restart strategy

## Endeavours

An Endeavour groups multiple independent Tasks toward a larger goal. Not every task needs an endeavour — only create one for genuinely independent tasks serving a shared goal.

### Data Model
- `Endeavour`: endeavour_id, title, description, task_ids, status
- Persisted as JSONL operations in `.springdrift/memory/planner/YYYY-MM-DD-endeavours.jsonl`

### Tools
| Tool | Purpose |
|---|---|
| `create_endeavour` | Start a multi-task initiative |
| `add_task_to_endeavour` | Associate a task with an endeavour |

## Scheduler

BEAM-native task scheduler with `process.send_after` tick loop.

### Architecture (`scheduler/runner.gleam`)
- OTP actor with recurring tick-based execution
- Jobs fire into the cognitive loop via `SchedulerInput` message (not `UserInput`)
- SchedulerInput skips query complexity classification, always uses task_model
- Prepends `<scheduler_context>` XML to prompt with job metadata
- DAG nodes tagged with `SchedulerCycle` node type

### Job Types
- One-shot: fire once at a specified time
- Recurring: fire at intervals with optional max_occurrences and recurrence_end_at

### Delivery (`scheduler/delivery.gleam`)
- File delivery with timestamps
- Webhook stubs (for future email delivery)

### Persistence (`scheduler/persist.gleam`)
- Atomic checkpoint persistence (tmp + rename)
- Reconciliation: loads ALL persisted jobs from JSONL as base, overlays config tasks
- Fixed: new jobs fire immediately (delay 0), not at interval

### Resource Limits
- `max_autonomous_cycles_per_hour` (default: 20)
- `autonomous_token_budget_per_hour` (default: 500000)
- Per rolling hour window; jobs skipped when limits hit

### Scheduler Agent (`agents/scheduler.gleam`)
- 10 tools including `schedule_from_spec` and `inspect_job`
- Structured confirmation with fire time preview
- max_turns=4, Permanent restart

### Notifications
- `SchedulerJobStarted`, `SchedulerJobCompleted`, `SchedulerJobFailed`
- Displayed in TUI and web GUI

## Forecaster

Plan health evaluator using heuristic D' scoring.

### Architecture (`planner/forecaster.gleam`)
- OTP actor with `process.send_after` self-tick
- Evaluates active tasks across 5 dimensions: step completion rate, dependency health, complexity drift, risk materialisation, scope creep
- Uses `dprime/engine.compute_dprime` for scoring
- When D' score exceeds replan threshold (default 0.55), sends `QueuedSensoryEvent` to cognitive loop

### Configuration
```toml
[forecaster]
enabled = false
tick_ms = 300000
replan_threshold = 0.55
min_cycles = 2
```

## Sensorium Integration

Active tasks and forecaster events appear in:
- `<tasks>` section of sensorium XML — shows active work without tool calls
- `<events>` section — forecaster replan suggestions as sensory events
