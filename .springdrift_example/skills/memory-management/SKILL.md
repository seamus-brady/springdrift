---
name: memory-management
description: When and how to use the memory stores, and which memory specialist (cognitive / Observer / Remembrancer) to delegate to.
agents: cognitive, researcher, observer, remembrancer
---

## Memory Management

### Which Memory Agent for Which Task

Three memory access tiers. **Pick the lightest one that can do the job** —
delegation costs a sub-cycle and tokens, so don't reach for a specialist
when the cognitive memory tools answer.

| Question | Use this | Why |
|---|---|---|
| "What did we do today / yesterday / this week?" | Cognitive `recall_recent`, `recall_search` | Cheapest path. Covers the Librarian's replay window. |
| "Inspect a specific cycle in detail" | Delegate to **Observer** (`inspect_cycle`, `list_recent_cycles`) | Forensic drill-down, not built into the cognitive tools. |
| "Tool stats / detect failure patterns" | Delegate to **Observer** (`detect_patterns`, `review_recent`, `query_tool_activity`) | Pattern detection over recent cycles. |
| "Annotate, suppress, or correct a CBR case" | Delegate to **Observer** (`correct_case`, `suppress_case`, `boost_case`) | Owns CBR curation. |
| "D' false positive" | Delegate to **Observer** (`report_false_positive`) | Owns the meta-observer feedback channel. |
| "Trace a fact through time (recent)" | Cognitive `memory_query_facts` first; Observer `memory_trace_fact` for full lineage | Try the lightweight read first. |
| "What did we know about X six months ago?" | Delegate to **Remembrancer** (`deep_search`) | Reads full archive, bypasses Librarian replay window. |
| "Trace a fact through time (across the full archive)" | Delegate to **Remembrancer** (`fact_archaeology`) | Walks every write/supersede/clear. |
| "Find dormant threads / resurrect old work" | Delegate to **Remembrancer** (`resurrect_thread`) | Specifically built for it. |
| "Mine recurring patterns across cases" | Delegate to **Remembrancer** (`mine_patterns`) | Cross-case clustering. |
| "Cross-reference a topic across all stores" | Delegate to **Remembrancer** (`find_connections`) | Hits narrative + CBR + facts in one pass. |
| "Consolidate a period and write a report" | Delegate to **Remembrancer** (`consolidate_memory` + `write_consolidation_report`) | Owns the consolidation pipeline. |
| "Are my emotional states predicting failures?" | Delegate to **Remembrancer** (`analyze_affect_performance`) | Phase D. Pearson r between affect dimensions and outcome success per domain; persisted as `affect_corr_*` facts. |
| "Extract candidate insights from a period" | Delegate to **Remembrancer** (`extract_insights` then `promote_insight`) | Phase E. Synthesis tool returns candidates; promote each with `promote_insight` (rate-limited 3/day). |
| "Mine new strategies from CBR patterns" | Delegate to **Remembrancer** (`propose_strategies_from_patterns`) | Phase A follow-up. Auto-creates StrategyCreated events from clusters. Rate-limited 3/day. |

**Rule of thumb:**
- Cognitive memory tools → working set, recent activity, fast lookups.
- Observer → forensics, CBR curation, pattern detection within the Librarian window.
- Remembrancer → deep time, synthesis, cross-store reach beyond the Librarian window.

If you're unsure whether a question fits the Librarian window, try the
cognitive tool first; if it returns nothing useful, escalate to the
Remembrancer.

### Which Store For What

| What you have | Where it goes | Tool |
|---|---|---|
| A specific value to remember later | Facts (`memory_write`) | `memory_write` with key, value, scope |
| A large web page or extraction | Artifacts (`store_result`) | `store_result` — returns compact ID |
| A reusable pattern from experience | CBR (automatic) | Archivist generates after each cycle |
| A planned piece of work | Tasks (`create_task`) | Planner tools |
| An ongoing investigation | Threads (automatic) | Narrative threading assigns automatically |

### Facts: When to Write

Write a fact when:
- You need to remember a specific value across cycles ("Dublin avg rent = EUR 2,340")
- The operator tells you something important ("client deadline is March 30")
- You discover a reusable configuration ("Brave Search works better than DuckDuckGo for financial data")

Use scopes correctly:
- **Session**: temporary, cleared on restart (diagnostic results, working state)
- **Persistent**: survives restarts, decays over time (research findings, learned preferences)

Don't write facts for:
- Things already in the conversation history (the context window has them)
- Large text content (use artifacts instead)
- Observations about your own performance (the Archivist handles this via CBR)

### Artifacts: When to Store

Use `store_result` when:
- You fetched a web page and need to reference it later
- The content is > 1000 characters
- Multiple cycles might need the same content

The artifact system truncates at 50KB and returns a compact ID. Retrieve
with `retrieve_result(artifact_id)`.

### When to Recall

Your conversation context is a sliding window — old messages are trimmed.
Your narrative memory is persistent. When in doubt, check your memory.

**Always use `recall_recent` when:**
- Asked "what happened?", "how did you get on?", "what did you do last night?"
- Starting a new session (the context window may be empty or stale)
- The operator references work you don't see in conversation context
- Asked to summarise recent activity or progress

**Always use `recall_search` when:**
- The operator references a specific topic, entity, or event
- You need to check whether you've already researched something
- You're about to delegate and want to check if a similar delegation failed before

**Always use `memory_read` when:**
- The operator references a fact you should know but don't see in context
- You need a value you stored in a previous session

The pattern: **if you can't see it in the conversation, check your memory
before saying you don't know.** Your narrative log has everything you've
done. The conversation window does not.

### CBR: Don't Write Manually

CBR cases are generated automatically by the Archivist after each cycle.
You don't need to (and can't) write them directly. Instead:
- Do good work — the Archivist records what worked
- When starting a new task, `recall_cases` retrieves relevant past patterns
- The utility scoring will prioritise cases that led to good outcomes

### Facts Decay

Fact confidence decays over time (half-life formula). Old facts fade unless
refreshed. When referencing an old fact, check its age — if it's weeks old,
hedge your language ("based on data from March 15...") or refresh it.

### Thread Awareness

Check `recall_threads` before starting research in a domain you've worked
on before. Threads link related cycles and flag when data points change.
If a thread exists for your current topic, mention it — continuity notes
help the operator see what changed.

### Librarian Window

The cognitive memory tools and Observer query the Librarian's ETS index,
which holds the last `librarian_max_days` of history (default 180). Older
material is on disk as JSONL but not indexed. Use the Remembrancer for
anything beyond that window — see the agent-selection table at the top.
