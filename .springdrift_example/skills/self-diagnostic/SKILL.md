---
name: self-diagnostic
description: Seven-step health check procedure using existing introspection tools. Run on boot, daily, or when meta-states indicate anomalies.
agents: observer, cognitive
---

## Self-Diagnostic Procedure

Run these checks in order. Report results as a structured summary. Flag any
issues as sensory events.

### Voice and delegation notes

- The sensorium and these steps address the agent as "you"; that's skill
  grammar. The **final report to the operator is written in first person**
  about the agent's own state. "My affect is stable", "I have 4 active
  tasks" — not "your affect is stable", "your active work".
- Pattern-detection tools (`detect_patterns`, `query_tool_activity`,
  `memory_trace_fact`, CBR curation) live on the **Observer agent**, not
  the cognitive loop. When the cognitive loop needs them, delegate via
  `agent_observer`. Calling them at root returns "Unknown tool".

### Step 1: System State

Call `introspect`. Verify:
- All 5 agents registered (planner, researcher, coder, writer, observer)
- D' safety enabled
- Sandbox status (if expected)
- Agent UUID present

Flag: `agent_missing` if any agent not registered.

### Step 2: Cycle Persistence

Call `reflect` for today. Then `list_recent_cycles`. Verify:
- Cycle count from `reflect` matches `list_recent_cycles` count
- Success rate > 70%
- No unexplained gaps in cycle timestamps
- Token budget within limits (if scheduler active)

Flag: `cycle_data_mismatch` if counts differ.
Flag: `low_success_rate` if < 70%.

### Step 3: Tool Health

Call `query_tool_activity` for today. Check:
- All expected tools have been called at least once
- No tool has failure rate > 20%
- `web_search` and `fetch_url` are functional (if researcher active)

Flag: `high_tool_failures` with tool name if > 20% failure rate.

### Step 4: Memory Health

Call `memory_query_facts` with keyword "". Call `recall_threads`. Call
`recall_cases` with a generic query.

Verify:
- Facts store is responding (any result, even empty)
- Thread index exists (thread count > 0 if sessions > 1)
- CBR returns results for a broad query
- CBR cases span multiple categories (not all one type)

Flag: `memory_empty` if no facts, threads, or cases exist after multiple sessions.

### Step 5: Memory Round-Trip

Write a test fact: `memory_write(key: "_diagnostic_test", value: "ok", scope: "session")`.
Read it back: `memory_read(key: "_diagnostic_test")`.
Clear it: `memory_clear_key(key: "_diagnostic_test")`.

Verify each operation succeeds.

Flag: `memory_write_fail` if write or read fails.

### Step 6: Safety Gate Health

From `reflect` output, check D' gate statistics:
- Input gate has evaluated at least some inputs (not all bypassed)
- Rejection rate is not 100% (gates are not stuck rejecting)
- Deterministic blocks are a minority of total decisions
- No evidence of repeated false positives

Flag: `gate_stuck_rejecting` if rejection rate > 50%.
Flag: `gate_not_evaluating` if no gate decisions recorded.

### Step 7: Meta-State Assessment

Read sensorium vitals (available in your context):
- `uncertainty` should be < 0.8
- `prediction_error` should be < 0.5
- If both are elevated, the agent is operating in unfamiliar territory
  with poor predictions — escalate to operator

Flag: `high_uncertainty` if > 0.8.
Flag: `high_prediction_error` if > 0.5.

### Reporting

After all checks, store results:
- `memory_write(key: "last_diagnostic", value: <JSON summary>, scope: "session")`
- For each flag: `memory_write(key: "diagnostic_flag_<name>", value: <detail>, scope: "session")`
- If no flags: `memory_write(key: "diagnostic_status", value: "healthy", scope: "session")`

If any critical flags (agent_missing, memory_write_fail, gate_stuck_rejecting),
report to the operator via `request_human_input` with a summary of findings.
