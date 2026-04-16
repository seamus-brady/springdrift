---
name: memory-management
description: When and how to use the seven memory stores. Covers facts, CBR, artifacts, and the distinction between them.
agents: cognitive, researcher, observer
---

## Memory Management

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

### Deep Memory: Delegate to the Remembrancer

The memory tools above (`recall_recent`, `recall_search`, `recall_threads`,
`recall_cases`) query the Librarian's ETS index — fast, but bounded to a
recent window (default 30 days). For older work, **delegate to the
Remembrancer agent**. It reads raw JSONL from disk, so it reaches months
or years of archive.

Good reasons to delegate to `agent_remembrancer`:
- "Have we researched this before?" — `deep_search` across months
- "What did we used to know about X?" — `fact_archaeology` traces belief over time
- "What patterns have emerged in my cases?" — `mine_patterns` clusters CBR cases
- "Are there dormant threads worth revisiting?" — `resurrect_thread`
- "Write a weekly consolidation of what we learned" — `consolidate_memory` + `write_consolidation_report`
- "Is this old fact still accurate? I re-verified it" — `restore_confidence`

Do NOT use the Remembrancer for recent cycles — that's the Observer's
job (and it's faster). Rough rule: within the last ~30 days use the
Librarian-backed tools above; beyond that, delegate to the Remembrancer.
