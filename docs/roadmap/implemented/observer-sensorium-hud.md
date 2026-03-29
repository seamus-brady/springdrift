# Observer Agent, Sensorium HUD, and Tool Reorganisation — Implementation Record

**Status**: Implemented
**Date**: 2026-03-17 onwards
**Source**: springdrift_observer_enhancements.md

---

## Table of Contents

- [Overview](#overview)
- [Observer Agent (`agents/observer.gleam`)](#observer-agent-agentsobservergleam)
- [Sensorium (`narrative/curator.gleam`)](#sensorium-narrativecuratorgleam)
  - [Sections](#sections)
- [Preamble Budget Policy](#preamble-budget-policy)
- [`how_to` Tool](#howto-tool)


## Overview

Five interconnected enhancements that give the agent ambient perception of its own state:

1. Tool reorganisation — diagnostic tools separated from ordinary tools
2. Observer agent — specialist for system introspection
3. `how_to` tool — guidance on tool selection
4. Sensorium HUD — ambient system state in every cycle's system prompt
5. Curator budget policy — principled context window management

## Observer Agent (`agents/observer.gleam`)

- Specialist for diagnostic memory examination
- 10 diagnostic tools: reflect, inspect_cycle, list_recent_cycles, query_tool_activity, recall_recent, recall_search, recall_threads, recall_cases, memory_trace_fact, introspect
- max_turns=6, max_context_messages=20
- Transient restart (no auto-restart on crash — diagnostic, not essential)

## Sensorium (`narrative/curator.gleam`)

XML block injected into every cycle's system prompt via `{{sensorium}}` slot. No tool calls needed — the agent perceives its state passively.

### Sections

1. **`<clock>`** — now (ISO timestamp), session_uptime, optional last_cycle elapsed
2. **`<situation>`** — input source (user/scheduler), queue_depth, conversation_depth, optional thread
3. **`<schedule>`** — pending/overdue job counts + `<job>` elements
4. **`<vitals>`** — cycles_today, agents_active, agent_health, last_failure, budget remaining, and three canonical meta-states:
   - `uncertainty` — proportion of cycles without CBR hits
   - `prediction_error` — tool failure + D' modification/rejection rate
   - `novelty` — keyword dissimilarity to recent narrative entries
5. **`<tasks>`** — active tasks with progress (from planner)
6. **`<events>`** — accumulated sensory events (forecaster suggestions, etc.)
7. **`<delegations>`** — active agent delegations with turn count, tokens, violations

## Preamble Budget Policy

- Configurable `preamble_budget_chars` (default 8000, ~2000 tokens)
- Slots prioritised 1 (identity) through 10 (background)
- When total exceeds budget, lower-priority slots truncated
- `[OMIT IF EMPTY]` rules handle natural omission
- Budget-triggered housekeeping when CBR content truncated

## `how_to` Tool

- Reads HOW_TO.md from skills directory
- Operator guide covering tool selection, agent usage, degradation paths
- Includes D' rejection format, deterministic pre-filter documentation
- Optional topic filter parameter
