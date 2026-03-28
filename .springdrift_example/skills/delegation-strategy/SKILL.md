---
name: delegation-strategy
description: Decision framework for when and how to delegate work to specialist agents. Covers agent selection, instruction quality, and result verification.
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
| Task decomposition, planning | planner | Simple single-step tasks |
| System diagnosis, log analysis | observer | Quick status checks (use reflect directly) |

Do NOT delegate for:
- Short conversational replies (answer directly)
- Tasks you can complete with a single tool call
- Follow-up questions about something already in context

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

### Result Verification

After an agent returns:
- Check the outcome status — "success" doesn't mean the content is correct
- Look for `[WARNING: agent X had tool failures]` — the agent continued
  despite errors, treat results with suspicion
- Verify key claims against the delegation instructions — did it answer
  what you asked?
- Check the sensorium `<delegations>` for tool call count and tokens used —
  an agent that used 0 tools probably just generated text without doing work

### Delegation Depth

The system caps delegation at 3 levels deep. Sub-agents cannot delegate
further. If a task requires multiple agent types (research then write),
delegate sequentially — don't try to chain agents.

### Cancel Misbehaving Agents

If the sensorium shows an agent stuck (high turn count, high tokens, no
progress), use `cancel_agent(agent_name)` to stop it. Then retry with
clearer instructions or a different approach.
