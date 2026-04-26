---
name: when-to-use-writer
description: Decision criteria for delegating to the writer agent vs synthesising directly in your own response.
agents: cognitive
---

# When to Use the Writer Agent (And When Not To)

The writer agent is designed for **unstructured-to-narrative
translation** — taking messy research findings, scattered notes, or
contradictory drafts and producing polished prose with hedging,
citations, and structural rewriting.

It is **not** designed for "make this look like a final answer." If
your research is already structured, delegating to the writer is
overhead that adds a token-starved layer with no benefit.

## Use the writer when

- Findings are unstructured: scattered bullet points, half-finished
  thoughts, contradictory drafts that need editorial judgment
- The deliverable is **flowing prose** that builds an argument or
  tells a story across multiple paragraphs
- The output needs **substantial rewriting**, not just reorganisation
- High-stakes audience (operator-facing reports for clients,
  regulators, archival publication) where careful hedging and
  citation matter
- The piece is long enough to benefit from a separate editorial
  pass with its own context window

## Synthesise directly in your own response when

- Research is already well-organised — tables, bullet points, clear
  comparisons, or numbered findings ready to present
- The task is **synthesis-of-presentation**, not narrative
  construction. You're picking what to surface from a body of
  structured material, not turning prose into prose.
- You're in rapid iteration with the operator and the overhead of
  delegation costs more than the benefit
- Your research output fits comfortably in your own response budget
  and you can write the synthesis inline

## The 2026-04-26 lesson

In that session, 14 researcher delegations produced
well-structured comparative material — tables, bullet points,
section-by-section overlap. Delegating to the writer for "final
form" meant:

1. Truncating findings to fit the writer's input budget
2. Getting zero useful output because the writer hit its own cap
3. Synthesising directly anyway after the failed writer call

The orchestrator had the material in working memory the whole time.
The writer detour was pure overhead. Reflexive writer delegation
adds a token-starved layer with no benefit when the input is
already structured.

## Decision in one line

**If you can imagine writing the response yourself in 200-500 words
of structured points, do it.** If the response needs prose to
breathe and an editor's eye, delegate.

## Companion: never delegate when downstream is capped

If the writer's previous delegation in this cycle returned a
`[truncation_guard:writer]` admission, the writer is structurally
the wrong tool for this scope. Either:

- Synthesise directly yourself
- Decompose: ask the writer for one section at a time via
  `update_draft` calls, with a smaller scope per call
- Ask the operator to widen the writer's `max_tokens` in
  `.springdrift/config.toml`

Don't re-dispatch hoping it'll work this time.
