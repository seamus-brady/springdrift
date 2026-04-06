---
name: delegation-strategy
description: Decision framework for when and how to delegate work to specialist agents and agent teams. Covers agent selection, team strategies, cost awareness, and result verification.
agents: cognitive
---

## Agent Delegation Strategy

### When to Delegate

Delegate when the task matches an agent's specialisation:

| Task Type | Agent | When NOT to delegate |
|---|---|---|
| Web research, data gathering | researcher | Simple factual questions you already know |
| Code writing, execution, debugging | coder | Trivial calculations (use calculator) |
| Text drafting, editing, reports | writer | Short conversational replies |
| Task decomposition, plan structure, risk analysis | planner | Simple single-step tasks |
| Endeavour lifecycle, phases, sessions, blockers, forecaster config | project_manager | Quick task step completion (use cognitive loop tools) |
| Cycle inspection, pattern detection, CBR curation, fact tracing | observer | Quick status checks (use reflect directly) |
| Email communication | comms | Nothing — always delegate email |

Do NOT delegate for:
- Short conversational replies (answer directly)
- Tasks you can complete with a single tool call
- Follow-up questions about something already in context

### What's on the Cognitive Loop vs Agents

You have 16 tools directly available. Everything else requires delegation:

**Your tools (fast, synchronous):**
- Memory: `recall_recent`, `recall_search`, `recall_threads`, `recall_cases`
- Facts: `memory_write`, `memory_read`, `memory_clear_key`, `memory_query_facts`
- Status: `reflect`, `introspect`
- Tasks: `complete_task_step`, `activate_task`, `get_active_work`, `get_task_detail`
- Utility: `how_to`, `cancel_agent`

**Delegate to Observer for:**
- Cycle forensics: `inspect_cycle`, `list_recent_cycles`, `query_tool_activity`
- Pattern analysis: `review_recent`, `detect_patterns`
- CBR curation: `correct_case`, `annotate_case`, `suppress_case`, `unsuppress_case`, `boost_case`
- Fact tracing: `memory_trace_fact`
- Safety feedback: `report_false_positive`

**Delegate to Planner for:**
- Pure reasoning: plan decomposition, steps, dependencies, risk identification
- Returns structured XML output (no tools of its own)

**Delegate to Project Manager for:**
- `create_endeavour`, `add_task_to_endeavour`, `get_endeavour_detail`
- `flag_risk`, `abandon_task`, `request_forecast_review`
- Phase management: `add_phase`, `advance_phase`
- Session management: `schedule_work_session`, `cancel_work_session`, `list_work_sessions`
- Blockers: `report_blocker`, `resolve_blocker`
- Forecaster: `get_forecaster_config`, `update_forecaster_config`, `get_forecast_breakdown`
- Delete: `delete_task`, `delete_endeavour`
- Task editing: `update_task`, `add_task_step`, `remove_task_step`, `update_endeavour`

### Single Agent vs Team

**Default: use a single agent.** Most tasks are best handled by one specialist.

Use a **team** only when:
- The task genuinely benefits from multiple perspectives (e.g. research that
  needs both academic and industry sources)
- Accuracy matters enough to justify the cost of debate (e.g. factual claims
  that will be sent externally)
- The task has distinct sequential phases that different agents handle best
  (e.g. research → analysis → writing)
- A lead needs to coordinate specialist outputs into a coherent whole

Do NOT use a team for:
- Simple single-perspective tasks (one researcher is enough)
- Tasks where speed matters more than thoroughness
- Follow-up or clarification work
- Anything a single agent can handle adequately

### Team Strategies

| Strategy | When to use | Cost |
|---|---|---|
| `ParallelMerge` | Breadth — same question, multiple angles | 2-5 agent runs + 1 synthesis |
| `Pipeline` | Depth — sequential phases building on each other | N agent runs + 1 synthesis |
| `DebateAndConsensus` | Accuracy — experts may disagree, need convergence | 2-5× agent runs + 1 synthesis |
| `LeadWithSpecialists` | Orchestration — one agent coordinates the rest | N+1 agent runs, no extra synthesis |

**Cost awareness:** Teams cost 3-5× a single agent dispatch. A ParallelMerge
with 2 members uses ~2 agent react loops + 1 synthesis LLM call. A 3-member
DebateAndConsensus with 2 rounds uses ~9 agent runs + 1 synthesis. Check the
sensorium's `tokens_remaining` before dispatching a team — if budget is tight,
use a single agent instead.

Config guards enforce limits:
- `team_max_members` (default 5) — prevents runaway fan-out
- `team_token_budget` (default 200,000) — total token cap across all members
- `team_max_debate_rounds` (default 3) — caps debate iterations

### Instruction Quality

Bad: "Research Dublin rental market"
Good: "Search for Dublin residential rental prices Q1 2026. Use web_search
for Daft.ie and CSO data. Report average rent, year-on-year change, and
supply levels. If sources conflict, note the discrepancy."

Always specify:
1. **What** to find (specific data points, not vague topics)
2. **Where** to look (specific sources if known)
3. **How** to handle problems (what to do if data is unavailable)
4. **What format** to return (structured findings, not narrative)

For teams, the instruction goes to ALL members. Each member also receives their
`<team_role>` and `<perspective>` overlays, so the instruction should describe
the overall objective, not per-member tasks.

### Result Verification

After an agent or team returns:
- Check the outcome status — "success" doesn't mean the content is correct
- Look for `[WARNING: agent X had tool failures]` — the agent continued
  despite errors, treat results with suspicion
- Verify key claims against the delegation instructions — did it answer
  what you asked?
- Check the sensorium `<delegations>` for tool call count and tokens used —
  an agent that used 0 tools probably just generated text without doing work

### Parallel Dispatch

When you call multiple agents in one response (e.g. `agent_researcher` and
`agent_coder`), they run simultaneously. Results come back in whatever order
they finish, then you synthesise. Use this when the tasks are independent.

If tasks are dependent (writer needs researcher's output), call them in
separate turns — call researcher first, get the result, then call writer
with that context.

### Delegation Depth

The system caps delegation at 3 levels deep. Sub-agents cannot delegate
further. Teams count as one delegation level from the cognitive loop's
perspective, even though they internally dispatch multiple agents.

### Cancel Misbehaving Agents

If the sensorium shows an agent stuck (high turn count, high tokens, no
progress), use `cancel_agent(agent_name)` to stop it. Then retry with
clearer instructions or a different approach.
