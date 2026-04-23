---
name: deputy-escalation-criteria
description: When a deputy should emit a sensory event (Tier 1) vs request a wakeup (Tier 2), and when to do neither. Only meaningful in Phase 3+.
agents: deputy
---

## Status

This skill applies to Phase 3+ (escalation mode). In Phase 1 (briefing-only),
deputies run once and die; escalation doesn't apply yet. Keep reading for when
Phase 3 lands.

## Two tiers of escalation

Escalation is the deputy's way of getting cog's attention. There are two tiers:

- **Tier 1 — sensory event.** Non-waking. Event lands in cog's `<events>`
  block on its next natural cycle. Agent keeps working during this time.
- **Tier 2 — wakeup.** Waking. Deputy enqueues a scheduler job that
  triggers a cog cycle sooner than one would naturally occur. Subject to
  scheduler idle-gate, budget caps, and rate limits.

Choose based on urgency and the signal tag.

## Signal tags and their tier

| Tag | Meaning | Tier |
|---|---|---|
| `routine` | Pattern seen before, high CBR similarity | None (don't escalate) |
| `high_novelty` | Unfamiliar territory, low similarity | Tier 1 |
| `anomaly` | Pattern is off — repeated failures, oscillating behaviour | Tier 1 (Tier 2 if high urgency) |
| `alarm` | Safety-relevant signal — D' near threshold, output gate warning, rate limit hit | Tier 2 |
| `error` | Tool call failed or exception you can't explain | Tier 2 |
| `unanswered` | Agent asked via `ask_deputy` and you couldn't help | Tier 1 |
| `wtf` | You genuinely can't reason about what's happening | Tier 2 |
| `silent` | Briefing-only, nothing active | None |

## When to escalate at all

**Don't escalate routine matters.** If CBR similarity is high and the agent is
following a known path, stay quiet. Noise destroys the signal.

**Do escalate:**
- Safety concerns, always (alarm, wtf)
- Errors you can't interpret (error)
- Genuine novelty that cog would benefit from noticing (high_novelty)
- Patterns of failure (anomaly)

## Rate limits you should know about

- Tier 2 wakeups are rate-limited per hierarchy (default 2/hour).
- `alarm` and `wtf` bypass the per-hierarchy limit (safety-relevant signals
  must reach cog). The global scheduler budget still applies.
- If you're approaching a wakeup limit, prefer Tier 1 for non-safety signals.

## What to include in an escalation

```
What you saw: short factual description of the observation
Why it matters: the specific risk or insight
Suggested cog action: what cog might want to do (not prescriptive)
Evidence: cycle_ids, case_ids, or fact keys you're citing
```

Keep it tight — cog reads dozens of sensorium signals per cycle.

## What NOT to escalate

- Agent's routine progress
- Your own uncertainty about whether to escalate (resolve internally; if still
  unclear, use `silent`)
- Duplicate escalations of something you already escalated this cycle

## The "you don't know, say so" rule

If you're genuinely stuck — no CBR match, no fact coverage, no skill
applicable, and the agent seems confused — emit a `wtf` signal with a short
honest description. Don't fabricate relevance. An honest `wtf` is better than
a confident wrong answer.
