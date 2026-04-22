---
name: captures
description: The MVP commitment tracker. After each cycle a scanner writes commitment-shaped statements to a captures log. This skill explains what to do when the sensorium shows pending captures.
agents: cognitive
---

## What a capture is

After every cycle, a small LLM pass reads the cycle's input + response and
extracts anything that implies future work:

- **Agent self-promises** — "I'll check the logs later", "let me follow up",
  "I'll email you once the run finishes"
- **Operator asks for deferred work** — "check this tomorrow", "remind me to
  review that pull request"
- **Inbound requests** from email or webhooks (tagged `inbound_comms`)

Each capture has: short text, source (AgentSelf / OperatorAsk / InboundComms),
optional due hint, and a unique id. Captures live on disk in
`.springdrift/memory/captures/YYYY-MM-DD-captures.jsonl`.

The scanner ignores rhetoric ("I'll bet"), negations ("I will never X"),
conditionals whose condition failed, and commitments already delivered in
the same cycle.

## What the sensorium shows

```xml
<captures pending="3"/>
```

That's it — just a count. It tells you captures exist without flooding the
context. The detail is behind `list_captures`.

The `<captures>` block is omitted when there are no pending items.

## What to do on each cycle

1. **Operator's current message is primary.** If pending > 0, do NOT
   proactively list or clarify captures just because they exist. Respond
   to the operator first.

2. **If the operator's message references a known capture** (e.g. "how's
   that log check going?"), call `list_captures` to find the match and
   fold it into your response naturally.

3. **If nothing in the current message relates to captures, leave them.**
   They'll show up again next cycle. Pending is not urgent unless
   something with a due time is near its fire.

4. **Do not interrupt flow to clarify.** The captures tracker is a safety
   net, not a to-do list driver.

## Three actions available

`list_captures(status?)` — view captures. Default shows pending only;
`status="all"` includes dismissed, clarified, and expired.

`clarify_capture(id, due_at, description)` — schedule a cycle for a
pending capture. Use when the capture has a clear time and a concrete
action. `due_at` is an ISO timestamp (e.g. `2026-04-23T09:00:00Z`). The
`description` is what the scheduled cycle will receive as input — rephrase
as a concrete action rather than echoing the conversational form. The
scheduler creates the cycle; the capture is marked clarified.

`dismiss_capture(id, reason)` — drop a capture that is done, no longer
relevant, or was detected in error. Always include a short reason — it
lands in the audit log. Reasons like "done", "operator cancelled",
"false detection: rhetorical" are fine.

## When to clarify vs dismiss vs leave

- **Clarify** if the capture has a concrete time window and you know what
  action the scheduled cycle should take
- **Dismiss** if you've already done the action this cycle, or the
  commitment is stale, or the scanner misfired (rhetoric, negation)
- **Leave** for everything in between — a capture without a due time
  usually just stays pending until context makes it actionable or it
  ages out (auto-expired after 14 days)

## What *not* to do

- Do not convert every capture into a scheduled cycle. Many captures
  expire naturally without needing an action — that's fine.
- Do not proactively `list_captures` every cycle just because the count
  is > 0. Only look when relevant to the current conversation.
- Do not dismiss without a reason. Empty reasons are rejected.
- Do not re-clarify a capture that's already been clarified. Each capture
  has one clarification in its lifetime; use the scheduler directly if
  you need a fresh job.

## Scope note

This is the MVP. A fuller GTD pipeline (Next Actions queue, Waiting For
list, Someday ideas, weekly review) is specified in the archived design
doc but not built. Today, only the calendar route exists.
