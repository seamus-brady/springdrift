# Logging & Observability Architecture

Springdrift has three complementary logging systems: system logs for operational
diagnostics, cycle logs for per-cycle telemetry and audit trails, and the DAG for
structured cycle relationships.

---

## 1. System Logger (slog)

`src/slog.gleam` provides structured logging with date-rotated JSON-L output.

### Log Levels

| Function | Level | Purpose |
|---|---|---|
| `debug(module, fn, msg, cycle_id)` | DEBUG | Detailed trace information |
| `info(module, fn, msg, cycle_id)` | INFO | Normal operational events |
| `warn(module, fn, msg, cycle_id)` | WARN | Potential issues |
| `log_error(module, fn, msg, cycle_id)` | ERROR | Failures |

Named `slog` (not `logger`) to avoid collision with Erlang's built-in `logger`
module.

### Output

- **File**: `.springdrift/logs/YYYY-MM-DD.jsonl` (date-rotated JSON-L)
- **stderr**: formatted lines when `--verbose` is set
- **Size limit**: 10MB per file with rotation (renames to `.1`)
- **Retention**: old logs (>30 days) cleaned up on startup via `cleanup_old_logs`

### Entry Format

```json
{"timestamp":"2026-04-06T14:30:00Z","level":"info","module":"cognitive","function":"handle_user_input","message":"Input: Hello","cycle_id":"abc123"}
```

## 2. Cycle Log

`src/cycle_log.gleam` provides per-cycle JSON-L logging for detailed telemetry.

### Location

`.springdrift/memory/cycle-log/YYYY-MM-DD.jsonl`

### Event Types

Every LLM call must thread a `cycle_id: String` and log events:

| Event | Data | Purpose |
|---|---|---|
| `human_input` | Text, parent cycle ID | User or scheduler input |
| `llm_request` | Model, messages, tools (verbose only) | Full LLM request payload |
| `llm_response` | Response text, usage, stop reason (verbose only) | Full LLM response |
| `tool_call` | Tool name, input JSON | Tool dispatch |
| `tool_result` | Tool name, output, success/failure | Tool execution result |
| `agent_dispatch` | Agent name, instruction | Agent delegation |
| `agent_complete` | Agent name, outcome, findings | Agent finished |
| `dprime_decision` | Gate, score, decision, features | Safety gate evaluation |
| `gate_timeout` | Gate, task_id | Gate evaluation timed out |
| `classify` | Complexity, model | Query classification result |

### Verbose Gating

`llm_request` and `llm_response` events are gated by `verbose: Bool` in
`CognitiveState`. In non-verbose mode, only the event type and cycle ID are logged
(no full payloads). This keeps cycle logs manageable during production use.

### Secret Redaction

When `redact_secrets` is True, cycle log entries are scanned for common secret
patterns (API keys, tokens, passwords) and redacted before writing.

## 3. DAG (Directed Acyclic Graph)

The DAG tracks parent-child relationships between cycles, providing a structured
view of how work flows through the system.

### Node Types

| Type | Represents |
|---|---|
| `CognitiveCycle` | Interactive user-triggered cycle |
| `SchedulerCycle` | Autonomous scheduler-triggered cycle |
| `AgentCycle` | Sub-cycle within an agent's react loop |

### Structure

```
UserInput → CognitiveCycle (root)
              ├── AgentCycle (researcher)
              │     ├── tool_call: web_search
              │     └── tool_call: fetch_url
              └── AgentCycle (writer)
                    └── tool_call: request_human_input
```

Each `CycleNode` carries:
- `cycle_id` and `parent_cycle_id`
- Node type
- Start/end timestamps
- Token usage (input, output, thinking)
- Tool call summaries
- D' gate decisions
- Agent output (typed `AgentOutput` variants)

The Librarian indexes DAG nodes in ETS for fast queries. The Observer agent's
`inspect_cycle` and `list_recent_cycles` tools drill into this data.

## 4. DAG-Based Tools

| Tool | Agent | Purpose |
|---|---|---|
| `reflect` | Cognitive / Observer | Aggregated day-level stats |
| `inspect_cycle` | Observer | Drill into a specific cycle tree |
| `list_recent_cycles` | Observer | Discover cycle IDs for a date |
| `query_tool_activity` | Observer | Per-tool usage stats |
| `review_recent` | Observer | Structured self-review across N cycles |
| `detect_patterns` | Observer | Automated pattern detection |

## 5. Cross-Cycle Pattern Detection

`detect_patterns` runs 5 automated detectors:

| Detector | Signal |
|---|---|
| Repeated failures | Same error pattern across multiple cycles |
| Tool clusters | Tools that always appear together |
| Escalation patterns | Increasing safety gate interventions |
| Cost outliers | Cycles with abnormal token usage |
| CBR misses | Cases retrieved but not helpful |

## 6. Cycle Tree

`src/narrative/cycle_tree.gleam` builds hierarchical `CycleNode` trees from
`parent_cycle_id` links. Used by the Observer for tree-structured cycle inspection
and by the TUI/web GUI for displaying delegation chains.

## 7. Key Source Files

| File | Purpose |
|---|---|
| `slog.gleam` | System logger: date-rotated JSON-L + stderr + retention |
| `cycle_log.gleam` | Per-cycle JSON-L logging, event types, UUID generation |
| `dag/types.gleam` | `CycleNode`, `CycleNodeType`, `ToolSummary`, `DprimeDecisionRecord`, `AgentOutput` |
| `narrative/cycle_tree.gleam` | Hierarchical tree builder from parent links |
