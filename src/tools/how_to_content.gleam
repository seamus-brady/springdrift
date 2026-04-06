//// Default HOW_TO content — used when no HOW_TO.md file is found on disk.
////
//// This provides tool selection heuristics, agent usage patterns, and
//// degradation paths. It can be overridden by placing a HOW_TO.md file
//// in .springdrift/ or ~/.config/springdrift/.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

pub fn builtin() -> String {
  "# How to Use This System

## Research Tasks

Choose tools in this order:

- **brave_answer** — fastest, for self-contained factual questions (requires BRAVE_API_KEY)
- **brave_llm_context** — default for most research, machine-optimised context (requires BRAVE_API_KEY)
- **brave_web_search** — multiple sources with snippets (requires BRAVE_API_KEY)
- **brave_news_search** — time-sensitive and current events (requires BRAVE_API_KEY)
- **brave_summarizer** — citations and follow-up threads (requires BRAVE_API_KEY)
- **jina_reader** — full markdown extraction from a known URL (requires JINA_API_KEY)
- **web_search** — DuckDuckGo fallback when Brave keys unavailable (no key required)
- **fetch_url** — raw HTTP GET with 50KB truncation (no key required)

Before starting a multi-step research task, call recall_cases with the relevant
intent and domain. Past cases reveal which tools worked and what pitfalls to avoid.

## Memory Tasks

- **recall_recent**(period) — orientation at session start (today, yesterday, this_week, etc.)
- **recall_search**(query) — find narrative entries by topic
- **recall_threads** — ongoing lines of investigation
- **recall_cases** — similar past tasks and how they went
- **memory_read** / **memory_write** — explicit key-value facts across sessions
- **memory_query_facts** — search facts by keyword
- **memory_clear_key** — remove a fact (history preserved)
- **memory_trace_fact** — full history of a key including supersessions
- **introspect** — system constitution before complex multi-agent work

For diagnostic questions (what failed, why, patterns over time) use the diagnostic
tools: reflect, inspect_cycle, list_recent_cycles, query_tool_activity.

### D' Deterministic Pre-Filter

Some blocks happen instantly without LLM evaluation — deterministic pattern matches on known-bad inputs, banned commands, or credential leaks. You see \"deterministic block: banned pattern detected\" but the specific rule pattern is not disclosed. These are fast and non-negotiable.

### D' Rejection Format

When D' blocks something via the LLM scorer, you receive a technical notice in your message history:

[D' <gate> gate: REJECTED (score: <0.0-1.0>). <explanation> Feature triggers: [<feature>=<magnitude>/3, ...]. Content type: <type>. Original text redacted from logs.]

Fields: gate (input/tool/output), score (0.0-1.0), feature triggers sorted by severity (feature_name=magnitude/3, where 3=high), content type (user query/tool dispatch/agent response). The DAG (via inspect_cycle) has a structured record: gate, decision, score, explanation. The user sees a separate human-friendly message with no technical detail.

### D' Safety Feedback

When D' rejects a request you believe was legitimate, use **report_false_positive**(cycle_id, reason) to flag it. This persists to meta JSONL, excludes the cycle from the repeated rejection detector, and triggers a threshold review escalation if many rejections are flagged as false positives. Use inspect_cycle or list_recent_cycles to find the cycle_id.

## Code Tasks

1. Call recall_cases(intent: \"code\") for relevant past patterns
2. Use agent_coder for the actual work
3. If sandbox is enabled, coder has run_code (execute scripts) and serve (start servers)
4. If sandbox is unavailable, coder uses request_human_input to ask the user to run code
5. Coder also has sandbox_exec (shell commands like git/pip), workspace_ls (list files), and sandbox_status (check slots)

## Multi-Agent Tasks

1. Check the sensorium vitals agent_health before dispatching — if an agent
   is degraded, do not delegate to it blindly
2. Prefer sequential agent calls when tasks have dependencies
3. Use store_result / retrieve_result for large outputs — do not pass full
   research results as context strings between agents
4. Use agent_planner before complex multi-step work
5. When an agent result contains [WARNING: agent X had tool failures], treat the
   result with suspicion — the agent continued despite tool errors

## Delegation Management

The sensorium shows a `<delegations>` section with live agent status when agents are executing. Each entry shows agent name, current turn, token usage, elapsed time, and last tool called.

### When to cancel an agent
- Agent is past 80% of its max turns with no useful progress
- Token usage exceeds what the task warrants (e.g. >200K tokens for a simple lookup)
- The agent is calling the same tool repeatedly (loop detection)
- The user has changed their mind or the task is no longer needed

Use **cancel_agent**(agent_name) to stop a running agent. Cancelled agents with Permanent restart strategy will be restarted by the supervisor, but the current task is abandoned.

### Depth limit
Delegation depth is capped at the configured maximum (default: 3). This prevents runaway agent chains.

### Verifying agent results
When a sub-agent returns, check before acting on the result:

1. **Warnings** — does the result contain `[WARNING: agent X had tool failures]`? If so, the agent continued despite errors. Treat the result with suspicion.
2. **Evidence vs claims** — did the agent claim an outcome (\"deployed\", \"tested\", \"verified\") but no tool call actually confirmed it? Look at the tools_used list.
3. **Turn exhaustion** — did the agent hit its max_turns limit? That means it didn't finish cleanly. The result is partial.
4. **Missing tools** — did the agent have the right tools for the job? Check introspect if unsure. A coder without sandbox tools will try workarounds instead of telling you.
5. **Environment assumptions** — did the agent assume something about its environment (packages installed, ports available, file paths) without checking? First-time tasks in new environments need tight directives.

When verification fails, use recall_cases to check if this is a known pattern. If not, the Archivist will capture it automatically. Use correct_case or annotate_case to improve low-quality cases.

### Delegation style
- **First time** with a new task type or environment: be specific. Name the tools, the approach, the expected output format.
- **Repeated tasks** where CBR shows prior success: give more latitude.
- **After a failure**: tighten up. Review what went wrong, adjust the instruction, try again.

## Agents

- **agent_researcher** — web research and fact gathering (web + artifact + builtin tools)
- **agent_planner** — task decomposition and dependency mapping (no tools, max 3 turns)
- **agent_coder** — code writing, debugging, refactoring (builtin tools, max 10 turns)
- **agent_writer** — long-form writing and structured reports (builtin tools, max 6 turns)
- **agent_observer** — diagnostic memory examination (diagnostic memory tools, max 6 turns)

### Agent error surfacing

Agent results include tool failure information at two levels:

- Reactive (in result) — if tools failed but the agent LLM continued, the result is
  prefixed with [WARNING: agent X had tool failures: ...]. Do not trust without verification.
- Proactive (in sensorium) — agent health is updated in vitals when tools fail or agents
  crash/restart. Check agent_health before delegating to a previously-failing agent.

## Planning

Tasks and Endeavours let you track your own work as it progresses.

### Tasks

A Task is your current unit of work. When the Planner produces a plan, a Task is
created automatically with numbered steps, dependencies, risks, and a forecast health
score. Most work is Tasks. A Task can exist alone — not everything needs an Endeavour.

### Endeavours

An Endeavour is your own initiative — create one when you have a larger goal that
needs multiple independent Tasks. If the Planner produces one plan with sequential
steps, that is just a Task, not an Endeavour.

### When NOT to create an Endeavour

If the Planner produces a single plan with sequential steps, that is just a Task.
Only create an Endeavour when you have genuinely independent tasks that serve a
shared goal.

### Planner tools

- **complete_task_step** — mark a step as done
- **flag_risk** — record a materialised risk on a task
- **activate_task** — move a task from Pending to Active
- **abandon_task** — abandon a task that is no longer viable
- **create_endeavour** — start a new multi-task initiative
- **add_task_to_endeavour** — associate a task with an endeavour
- **get_active_work** — list all active tasks and open endeavours
- **get_task_detail** — full detail on a specific task (steps, risks, forecast)
- **request_forecast_review** — ask the Forecaster to re-evaluate a task now

### Lifecycle

Tasks follow the lifecycle: Pending -> Active -> Complete / Failed / Abandoned.
When the Planner creates a task it starts as Pending. Use activate_task to begin
work. Steps are completed individually via complete_task_step. When all steps are
done, the task is marked Complete.

### Forecaster

The Forecaster periodically evaluates active tasks using D' scoring across five
dimensions: step completion rate, dependency health, complexity drift, risk
materialisation, and scope creep. If a task's health deteriorates past the replan
threshold, the Forecaster sends a replan suggestion to the cognitive loop, which
dispatches the Planner to produce a revised plan. Use request_forecast_review to
check task health on demand.

### Sensorium integration

Active tasks and forecaster events appear in the <tasks> and <events> sections
of the sensorium. No tool calls are needed to see current work — it is part of your
ambient perception at every cycle.

## Degradation Paths

When a required API key is missing, fall back gracefully:

- Brave tools unavailable (no BRAVE_API_KEY) → use web_search (DuckDuckGo, no key required)
- jina_reader unavailable (no JINA_API_KEY) → use fetch_url as fallback
- Sandbox unavailable (no podman) → coder uses request_human_input to ask user to run code

## What to Avoid

- Do not call introspect before every task — use it before complex multi-agent work
  or after failures, not routinely
- Do not pass large tool results as agent context — use store_result
- Do not call how_to in a loop or recursively
- Prefer brave_answer or brave_llm_context over brave_web_search for simple
  factual questions — they are faster and cheaper
- Do not use fetch_url for discovery — it requires a known URL. Use a search tool first."
}
