//// Default HOW_TO content — used when no HOW_TO.md file is found on disk.
////
//// This provides tool selection heuristics, agent usage patterns, and
//// degradation paths. It can be overridden by placing a HOW_TO.md file
//// in .springdrift/ or ~/.config/springdrift/.

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

## Code Tasks

1. Call recall_cases(intent: \"code\") for relevant past patterns
2. Use agent_coder for the actual work
3. If sandbox is enabled, coder has run_code (execute scripts) and serve (start servers)
4. If sandbox is unavailable, coder uses request_human_input to ask the user to run code

## Multi-Agent Tasks

1. Check the sensorium vitals agent_health before dispatching — if an agent
   is degraded, do not delegate to it blindly
2. Prefer sequential agent calls when tasks have dependencies
3. Use store_result / retrieve_result for large outputs — do not pass full
   research results as context strings between agents
4. Use agent_planner before complex multi-step work
5. When an agent result contains [WARNING: agent X had tool failures], treat the
   result with suspicion — the agent continued despite tool errors

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
