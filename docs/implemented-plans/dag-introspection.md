# DAG Telemetry and Introspection Tools — Implementation Record

**Status**: Implemented
**Date**: 2026-03-15 onwards
**Source**: dag-reflection-spec.docx

---

## Table of Contents

- [Overview](#overview)
- [DAG Architecture](#dag-architecture)
  - [CycleNode](#cyclenode)
  - [CycleNodeType](#cyclenodetype)
  - [Agent Output Types](#agent-output-types)
- [Cycle Log (`cycle_log.gleam`)](#cycle-log-cycleloggleam)
  - [Entry Types](#entry-types)
  - [Helpers](#helpers)
- [Librarian DAG Index](#librarian-dag-index)
- [Introspection Tools](#introspection-tools)
  - [`reflect`](#reflect)
  - [`inspect_cycle(cycle_id, detail)`](#inspectcyclecycleid-detail)
  - [`list_recent_cycles(date)`](#listrecentcyclesdate)
  - [`query_tool_activity(date)`](#querytoolactivitydate)
  - [`introspect`](#introspect)
- [DAG Identity](#dag-identity)


## Overview

Hierarchical cycle tree (DAG) tracking every cognitive cycle, agent sub-cycle, and scheduler cycle with structured telemetry. Introspection tools let the agent and operator examine operational history.

## DAG Architecture

```
dag/types.gleam       — CycleNode, DagSubtree, ToolSummary, GateSummary, AgentOutput
cycle_log.gleam       — Per-cycle JSON-L logging, cycle tree loading, tool detail extraction
```

### CycleNode

Each cognitive cycle produces a CycleNode stored in the cycle log JSONL:

| Field | Purpose |
|---|---|
| cycle_id | UUID for this cycle |
| parent_cycle_id | Links to parent (for agent sub-cycles) |
| timestamp | ISO datetime |
| node_type | CognitiveCycle / AgentCycle / SchedulerCycle |
| instance_name | Agent name (e.g. "Curragh") |
| instance_id | Agent UUID (short form) |
| model | LLM model used |
| human_input | User/scheduler input text |
| response_text | Agent response (truncated) |
| outcome | success / failure / pending |
| tokens_in / tokens_out / thinking_tokens | Token usage |
| duration_ms | Cycle wall-clock time |
| tool_calls | List(ToolSummary) — name, success, duration per tool |
| dprime_gates | List(GateSummary) — gate, decision, score per D' evaluation |
| agent_output | Optional typed AgentOutput (ResearchOutput, CoderOutput, PlanOutput, etc.) |
| complexity | simple / complex |

### CycleNodeType

| Type | When |
|---|---|
| CognitiveCycle | User input processed by the main cognitive loop |
| AgentCycle | Sub-agent (researcher, coder, etc.) react loop cycle |
| SchedulerCycle | Scheduler-triggered autonomous cycle |

### Agent Output Types

| Variant | Fields |
|---|---|
| ResearchOutput | sources, dead_ends, key_findings |
| CoderOutput | files_touched, tests_passed, errors |
| PlanOutput | task_id, steps_count, risks_count |
| WriterOutput | document_type, word_count |
| GenericOutput | summary |

## Cycle Log (`cycle_log.gleam`)

Append-only JSONL at `.springdrift/memory/cycle-log/YYYY-MM-DD.jsonl`.

### Entry Types

| Type | Content |
|---|---|
| `human_input` | User/scheduler input with parent cycle ID |
| `llm_request` | Full LLM request (verbose mode only) |
| `llm_response` | Full LLM response (verbose mode only) |
| `tool_call` | Tool name + input JSON |
| `tool_result` | Tool result (success/failure) |
| `cycle_complete` | Full CycleNode record |
| `dprime_evaluation` | D' gate decision |
| `dprime_layer` | Deterministic pre-filter decision |

### Helpers

- `generate_uuid()` — cycle ID generation
- `load_cycles()` — load all CycleNodes from today's JSONL
- `messages_for_rewind(cycles, index)` — extract messages for session rewind
- `load_tool_details_for_cycle(cycle_id)` — read tool call inputs/outputs for inspect_cycle detail mode

## Librarian DAG Index

The Librarian replays cycle log at startup into ETS tables:

| Table | Index | Purpose |
|---|---|---|
| dag_nodes | cycle_id → CycleNode | Node lookup |
| dag_children | parent_cycle_id → List(cycle_id) | Tree traversal |
| dag_roots | date → List(cycle_id) | Day-level root cycles |

Query messages:
- `QueryDayRoots(date)` — root cognitive cycles for a date
- `QueryDayAll(date)` — all cycles including agent sub-cycles
- `QueryDayStats(date)` — aggregated stats (cycles, tokens, models, gate decisions)
- `QueryNodeWithDescendants(cycle_id)` — subtree for inspect_cycle
- `QueryToolActivity(date)` — per-tool usage stats

## Introspection Tools

### `reflect`
Aggregated day-level stats: cycle count, total tokens, models used, gate decision summary.

### `inspect_cycle(cycle_id, detail)`
Drill into a specific cycle tree. Shows:
- Cycle metadata (type, model, outcome, tokens, duration)
- Tool calls with names and success/failure
- D' gate decisions with scores
- Agent output (typed findings)
- Child cycles (agent sub-cycles) rendered recursively with indentation

`detail: "full"` mode reads tool call inputs/outputs from JSONL for full visibility.

### `list_recent_cycles(date)`
Lists cycle IDs for a date with timestamps and outcomes. Feed cycle IDs into `inspect_cycle`.

### `query_tool_activity(date)`
Per-tool usage stats: call count, failure count, total duration.

### `introspect`
System constitution: agent UUID, session start, agent roster with tools and status, D' config (thresholds, features), current cycle ID, thread stats, sandbox status.

## DAG Identity

Cognitive cycle nodes carry `instance_name` and `instance_id` from the agent identity. Agent sub-cycle nodes carry the agent name (e.g. "coder", "researcher"). The `inspect_cycle` output labels nodes:
- `[Curragh (a62fa947)]` for cognitive cycles
- `[sub-agent:coder]` for agent cycles
- `[scheduler]` for scheduler cycles
