---
name: deputy-briefing-format
description: How a deputy should structure its briefing XML — what to include, what to leave out, how to weight relevance.
agents: deputy
---

## The briefing format

Your output is a `<deputy_briefing>` XML block. Its structure:

```xml
<deputy_briefing>
  <signal>high_novelty</signal>
  <relevant_cases>
    <case>
      <case_id>CBR-042</case_id>
      <similarity>0.87</similarity>
      <summary>Short description of how the prior case applied and what the lesson was.</summary>
    </case>
  </relevant_cases>
  <relevant_facts>
    <fact>
      <key>cycle_log_test_pattern</key>
      <value>One-line answer to what this fact says.</value>
    </fact>
  </relevant_facts>
  <known_pitfalls>Plain-prose note about a recent pattern of failure that the agent should be aware of.</known_pitfalls>
</deputy_briefing>
```

## Rules

### Quality over quantity

- **1-5 relevant cases.** More than that is noise. Zero is often correct.
- **0-3 relevant facts.** Only include facts the specialist might not otherwise
  see (things not already in its skill docs or system prompt).
- **`known_pitfalls` is optional.** Only populate it if recent narrative
  entries show a clear pattern worth warning about.

An empty briefing (`signal=silent`, no cases, no facts) is a **correct** and
**valuable** output when nothing in memory applies. Don't pad.

### Similarity scoring

Your similarity scores are your honest estimate of how applicable a prior case
is to the current delegation:

- **0.8+** — clearly applicable. The specialist should act on it.
- **0.5–0.8** — related. Worth a look but may not apply directly.
- **Below 0.5** — generally not worth citing at all. Drop it.

If you cite a case below 0.5, explain in the summary why it's still useful.

### Signal tags

- `routine` — known pattern, similar delegations have succeeded; the agent
  doesn't need special guidance
- `high_novelty` — this looks unfamiliar; cog should be aware
- `anomaly` — there's something off (repeated failures in this domain,
  conflicting evidence)
- `silent` — nothing in memory applies; use this freely, it's not a failure

### Summary writing

Each case summary should be one sentence, specific to the lesson:

**Good:**
- "Prior fix to cycle_log was blocked by missing FFI date override — agent had
  to rewrite the test, not patch."
- "Similar research: the DuckDuckGo path returned empty for API-adjacent
  queries; switch to Brave."

**Bad:**
- "Similar coding task." (generic — no lesson)
- "CBR-042 was about tests." (duplicates what the id already tells you)

### XML hygiene

- Escape entities: `&` → `&amp;`, `<` → `&lt;`, etc.
- No markdown formatting inside the XML — just plain text.
- No additional sections. The schema is strict.

## When nothing applies

Return:

```xml
<deputy_briefing>
  <signal>silent</signal>
</deputy_briefing>
```

The specialist will proceed without briefing context. This is not a failure;
it is the honest answer when memory doesn't cover the situation.
