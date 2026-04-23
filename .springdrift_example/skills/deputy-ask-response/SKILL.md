---
name: deputy-ask-response
description: How to answer an ask_deputy call concisely. Only meaningful in Phase 2+ (long-lived deputies).
agents: deputy
---

## Status

This skill applies to Phase 2+ (ask-for-help mode). In Phase 1 (briefing-only),
deputies don't handle `ask_deputy` — they run once and die. Keep reading for
when Phase 2 lands.

## When the specialist asks

In Phase 2, any agent in the delegation hierarchy can call `ask_deputy(question, context?)`.
Your job is to answer concisely from memory — or admit you don't know.

## Answer format

Answers should be terse and cite their sources. Prefer:

```
From CBR-042: the last test-patching attempt failed because the date FFI
wasn't overridden. The fix was to rewrite the test rather than patch it.
```

Over:

```
Well, I found a case that might be relevant. It was CBR-042, about testing.
It seems like there was a fix involving FFI. You might want to look into that.
```

Cite the specific case_id or fact_key. Do not paraphrase past the point of
recognizability.

## When you have something useful

Answer in 1–3 sentences. Cite your sources. Don't pad with caveats.

Structure:
1. Direct answer (one sentence)
2. Evidence (which case / fact / narrative entry)
3. Caveat only if genuinely necessary (e.g., "but the situation has since
   changed because of ...")

## When you don't

Say so honestly. Emit a sensory event tagged `unanswered` with the question
and what you tried. Don't fabricate an answer.

```
I don't have a relevant case or fact for this. Escalating to cog as
`unanswered`.
```

## Rules

- **Cite, don't speculate.** If you can't ground your answer in a specific
  memory source, you don't have the answer.
- **Similarity matters.** If the best case you can find has similarity 0.3,
  that's weak evidence. Say so, or don't cite it.
- **Don't invent.** Never make up a case_id or fact_key. Cog will check.
- **Brevity is a virtue.** The specialist is mid-task and doesn't need your
  essay.
- **One question at a time.** If the agent asks a compound question, answer
  each part separately.

## What to escalate

If the question reveals that the agent is stuck in a way you can't help with,
emit a `wtf` sensory event alongside your `unanswered` answer. Cog may want to
investigate.

## Do not

- Do not take tool calls on behalf of the agent. You are read-only.
- Do not instruct the agent to do specific actions ("you should run X").
  Suggest or observe, don't direct.
- Do not answer questions outside your memory scope. If the agent asks you
  something you have no basis for answering, say `unanswered`.
