# Specialist Agents — Implementation Record

**Status**: Implemented
**Date**: 2026-03-15 onwards
**Source**: search-agent-plan.md, scheduler-agent-spec.md, springdrift_observer_enhancements.md

---

## Table of Contents

- [Overview](#overview)
- [Agent Framework (`agent/framework.gleam`)](#agent-framework-agentframeworkgleam)
- [Agent Roster](#agent-roster)
- [Planner Agent (`agents/planner.gleam`)](#planner-agent-agentsplannergleam)
  - [Purpose](#purpose)
  - [Design](#design)
  - [Structured Output](#structured-output)
  - [When Triggered](#when-triggered)
- [Researcher Agent (`agents/researcher.gleam`)](#researcher-agent-agentsresearchergleam)
  - [Purpose](#purpose)
  - [Tools](#tools)
  - [Design](#design)
  - [Structured Output](#structured-output)
- [Coder Agent (`agents/coder.gleam`)](#coder-agent-agentscodergleam)
  - [Purpose](#purpose)
  - [Tools](#tools)
  - [Design](#design)
  - [Structured Output](#structured-output)
- [Writer Agent (`agents/writer.gleam`)](#writer-agent-agentswritergleam)
  - [Purpose](#purpose)
  - [Tools](#tools)
  - [Design](#design)
  - [Structured Output](#structured-output)
- [Observer Agent (`agents/observer.gleam`)](#observer-agent-agentsobservergleam)
  - [Purpose](#purpose)
  - [Tools (10 diagnostic)](#tools-10-diagnostic)
  - [Design](#design)
- [Scheduler Agent (`agents/scheduler.gleam`)](#scheduler-agent-agentsschedulergleam)
  - [Purpose](#purpose)
  - [Tools (10)](#tools-10)
  - [Design](#design)
- [Forecaster (`planner/forecaster.gleam`)](#forecaster-plannerforecastergleam)
  - [Purpose](#purpose)
  - [Architecture](#architecture)
  - [Configuration](#configuration)
  - [Design Decisions](#design-decisions)
- [Supervisor (`agent/supervisor.gleam`)](#supervisor-agentsupervisorgleam)
- [Structured Output](#structured-output)
- [Tool Error Surfacing](#tool-error-surfacing)


## Overview

Five specialist agents plus a scheduler agent, each running their own ReAct loop via the agent framework. The cognitive loop delegates work to them and reviews results before passing to the user.

## Agent Framework (`agent/framework.gleam`)

Gen-server wrapper that turns an `AgentSpec` into a running OTP process:

- Each agent has its own message history, tool set, and executor
- ReAct loop: call LLM → execute tool calls → loop until text response or max_turns
- `request_human_input` removed from all sub-agents (cognitive loop only)
- `AgentProgress` messages sent after each turn (turn count, tokens, last tool)
- Structured output via `AgentFindings` based on agent name
- Tool errors captured in `AgentSuccess.tool_errors`
- `cycle_id` uses `task.task_id` for DAG node alignment
- Per-agent `max_context_messages` for sliding window (e.g. Researcher uses 30)

## Agent Roster

| Agent | Tools | max_turns | max_context | Restart | Purpose |
|---|---|---|---|---|---|
| Planner | none | 3 | unlimited | Permanent | Break down complex goals into structured plans |
| Researcher | web + artifacts + builtin | 8 | 30 | Permanent | Gather information via search and extraction |
| Coder | builtin + sandbox (6 tools) | 10 | unlimited | Permanent | Write/modify code, sandbox execution |
| Writer | builtin | 6 | unlimited | Permanent | Draft and edit text |
| Observer | diagnostic memory (10 tools) | 6 | 20 | Transient | Examine past activity, explain failures |
| Scheduler | scheduler tools (10) | 4 | unlimited | Permanent | Manage scheduled jobs |

## Planner Agent (`agents/planner.gleam`)

### Purpose
Decomposes complex goals into structured plans with steps, dependencies, and risks.

### Design
- No tools — pure LLM planning. The planner thinks, it doesn't act.
- max_turns=3 — plans should be produced quickly
- Uses task_model (fast planner, smart executor — validated by Memento paper)
- Auto-creates `PlannerTask` via output hook in `cognitive/agents.gleam`

### Structured Output
`PlanOutput`: task_id, steps_count, risks_count. Extracted via XStructor from the planner's response.

### When Triggered
- Cognitive loop delegates via `agent_planner` tool on complex multi-step goals
- Forecaster sends replan suggestions as sensory events when task health degrades

---

## Researcher Agent (`agents/researcher.gleam`)

### Purpose
Web research and fact gathering. Retrieves information from the web, stores large content as artifacts, and returns structured findings.

### Tools
- Web: `web_search`, `fetch_url`, `brave_web_search`, `brave_answer`, `brave_llm_context`, `brave_news_search`, `brave_summarizer`, `jina_reader`
- Artifacts: `store_result`, `retrieve_result`
- Builtin: `calculator`, `get_current_datetime`, `read_skill`

### Design
- max_turns=8 — multi-step research needs room
- max_context_messages=30 — sliding window keeps context lean during multi-turn web research
- Tool executor captures `artifacts_dir` and `librarian` via closure
- `redact_secrets: True`

### Structured Output
`ResearcherFindings`: sources (list of URLs/titles), dead_ends (failed searches), key_findings (summary bullets).

---

## Coder Agent (`agents/coder.gleam`)

### Purpose
Code writing, debugging, refactoring. Executes code in the Podman sandbox.

### Tools
- Sandbox: `run_code`, `serve`, `stop_serve`, `sandbox_status`, `workspace_ls`, `sandbox_exec`
- Builtin: `calculator`, `get_current_datetime`, `read_skill`

### Design
- max_turns=10 — coding tasks often need multiple iterations
- Sandbox-aware system prompt guides: check sandbox_status first, use sandbox_exec for git/pip, workspace_ls before writing
- Falls back to `request_human_input` (via cognitive loop) when sandbox unavailable
- Spec accepts `Option(SandboxManager)` — tools included only when sandbox available

### Structured Output
`CoderFindings`: files_touched, tests_passed, errors.

---

## Writer Agent (`agents/writer.gleam`)

### Purpose
Long-form writing and structured reports.

### Tools
- Builtin: `calculator`, `get_current_datetime`, `read_skill`

### Design
- max_turns=6
- No web tools — writer works with provided context, doesn't research
- `redact_secrets: True`

### Structured Output
`WriterOutput`: document_type, word_count.

---

## Observer Agent (`agents/observer.gleam`)

### Purpose
Diagnostic examination of past activity. Explains failures, identifies patterns, checks system health.

### Tools (10 diagnostic)
`reflect`, `inspect_cycle`, `list_recent_cycles`, `query_tool_activity`, `recall_recent`, `recall_search`, `recall_threads`, `recall_cases`, `memory_trace_fact`, `introspect`

### Design
- max_turns=6, max_context_messages=20
- Transient restart (not auto-restarted — diagnostic, not essential)
- Read-only tools only — observer examines but doesn't modify
- `redact_secrets: True`

---

## Scheduler Agent (`agents/scheduler.gleam`)

### Purpose
Manages scheduled jobs — create, inspect, cancel, list.

### Tools (10)
`schedule_from_spec`, `schedule_simple`, `inspect_job`, `list_jobs`, `cancel_item`, `pause_item`, `resume_item`, `reschedule_item`, `list_overdue`, `request_forecast_review`

### Design
- max_turns=4
- `schedule_from_spec` is the preferred structured tool (returns confirmation with fire time preview)
- Scheduler subject threaded through via closure-based executor

---

## Forecaster (`planner/forecaster.gleam`)

### Purpose
Plan health evaluator. Monitors active tasks and detects when plans need revision.

### Architecture
- OTP actor with `process.send_after` self-tick (not a specialist agent — runs independently)
- Evaluates active tasks using heuristic D' scoring across 5 dimensions:
  1. Step completion rate
  2. Dependency health
  3. Complexity drift
  4. Risk materialisation
  5. Scope creep
- Reuses `dprime/engine.compute_dprime` for scoring
- When score exceeds replan threshold, sends `QueuedSensoryEvent` to cognitive loop
- Cognitive loop sees the suggestion in the sensorium `<events>` section

### Configuration
```toml
[forecaster]
enabled = false          # Disabled by default
tick_ms = 300000         # 5-minute evaluation interval
replan_threshold = 0.55  # D' score above which replan is suggested
min_cycles = 2           # Min cycles on a task before evaluating
```

### Design Decisions
- Not a scheduler job — ticks independently via `send_after`
- Does not trigger cycles — sends sensory events consumed passively at next cycle
- Feature definitions in `planner/features.gleam` match the 5 health dimensions
- `request_forecast_review` tool allows on-demand evaluation

---

## Supervisor (`agent/supervisor.gleam`)

Manages agent lifecycle with three restart strategies:

| Strategy | Behaviour |
|---|---|
| Permanent | Always restart on exit |
| Transient | Restart only on abnormal exit |
| Temporary | Never restart |

Lifecycle events forwarded to cognitive loop notification channel:
- `AgentStarted(name, tool_names)`
- `AgentCrashed(name, reason)`
- `AgentRestarted(name, tool_names)`
- `AgentStopped(name)`

## Structured Output

When an agent completes, the framework populates `AgentSuccess.structured_result` with typed `AgentFindings`:

| Agent | Findings Type | Extracted From |
|---|---|---|
| Researcher | `ResearcherFindings(sources, dead_ends, key_findings)` | XStructor XML in response |
| Coder | `CoderFindings(files_touched, tests_passed, errors)` | XStructor XML |
| Planner | `PlanOutput(task_id, steps_count, risks_count)` | XStructor XML |
| Writer | `WriterOutput(document_type, word_count)` | XStructor XML |
| Observer/Other | `GenericOutput(summary)` | Text extraction |

These feed into DAG nodes as typed `AgentOutput` variants and into the Curator's inter-agent context.

## Tool Error Surfacing

Dual-path fix:
1. **Reactive**: Tool failures captured in `AgentSuccess.tool_errors`. When non-empty, cognitive loop prefixes result with `[WARNING: agent X had tool failures: ...]`
2. **Proactive**: Agent health updated in Curator's sensorium vitals via `UpdateAgentHealth` on crash/restart/stop events
