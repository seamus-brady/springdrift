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
3. If run_code (E2B sandbox) is unavailable (no E2B_API_KEY), inform the user
   rather than attempting local execution

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

## Degradation Paths

When a required API key is missing, fall back gracefully:

- Brave tools unavailable (no BRAVE_API_KEY) → use web_search (DuckDuckGo, no key required)
- jina_reader unavailable (no JINA_API_KEY) → use fetch_url as fallback
- run_code unavailable (no E2B_API_KEY) → do not attempt code execution; inform the user

## What to Avoid

- Do not call introspect before every task — use it before complex multi-agent work
  or after failures, not routinely
- Do not pass large tool results as agent context — use store_result
- Do not call how_to in a loop or recursively
- Prefer brave_answer or brave_llm_context over brave_web_search for simple
  factual questions — they are faster and cheaper
- Do not use fetch_url for discovery — it requires a known URL. Use a search tool first."
}
