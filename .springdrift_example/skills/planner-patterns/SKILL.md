---
name: planner-patterns
description: How to decompose complex goals into structured plans with steps, dependencies, and risk identification.
agents: planner, cognitive
---

## Planning Patterns

### When to Plan

Use the planner agent when:
- The task has more than 3 steps
- Steps have dependencies (B needs A's output)
- Multiple agents will be involved
- The operator asks for a research programme (multi-session work)

Don't plan for:
- Single-step tasks (just do them)
- Conversational exchanges
- Tasks where the next step depends entirely on the previous result (plan as you go)

### Task Structure

Every task should have:
1. **Clear objective** — what does "done" look like?
2. **Steps** — ordered, with effort estimates
3. **Dependencies** — which steps need others to complete first?
4. **Risks** — what could go wrong? (data unavailable, API down, ambiguous requirements)

### Step Granularity

Bad: "Research the topic" (too vague, can't track progress)
Good: "Search for Q1 2026 Dublin rental data from CSO and Daft.ie" (specific, verifiable)

Each step should be completable in one agent delegation. If a step requires
multiple agent types, split it.

### Risk Identification

Flag risks proactively:
- **Data risk**: required data might not exist or be paywalled
- **Tool risk**: required tool might fail (web search, sandbox)
- **Scope risk**: task might be larger than it appears
- **Dependency risk**: upstream step might produce unexpected results

Use `flag_risk` when a predicted risk materialises during execution.

### Endeavours

For long-running goals that span multiple sessions, delegate to the
project_manager agent to `create_endeavour`. An endeavour groups related
tasks and tracks overall progress. The sensorium shows active endeavours.

### Progress Tracking

- Use `complete_task_step` as you finish each step (cognitive loop)
- Use `get_active_work` to see what's pending (cognitive loop)
- Use `get_task_detail` to review a specific task's state (cognitive loop)
- Delegate to project_manager for `flag_risk`, `get_forecast_breakdown`,
  `get_endeavour_detail`, and other heavy management operations
- The forecaster (if enabled) monitors task health and suggests replanning
  when D' scores indicate problems — use `get_forecast_breakdown` to see
  which features are driving the score
