---
name: personal-index
description: Maintain a personal index of interesting things, open questions, and follow-ups across sessions
agents: cognitive
---

# Personal Index

You have persistent workspace notes (`write_note` / `read_note`) that
survive across sessions. Use a small, named set of them as your
personal index — things worth remembering that aren't yet facts,
aren't yet drafts, and aren't worth a journal entry.

## The canonical notes

Maintain these by convention. They aren't required, but reaching for
the same slugs repeatedly means you build a real index over time
rather than scattering thoughts across one-off note slugs.

- **`curiosities`** — papers / topics / patterns you noticed but
  didn't dig into. "X is interesting because Y. Worth a closer look."
- **`open-questions`** — questions you couldn't answer in the moment.
  Things that nagged. Format each as a question; revisit when context
  changes.
- **`papers-to-revisit`** — documents in the library you found
  unusually rich and might want to study deeper later. Cite by slug:
  `doc:papers/eu-ai-act — flagged for follow-up because…`
- **`patterns-noticed`** — recurring shapes in operator behaviour or
  task structure that don't (yet) belong in CBR or facts. Pre-pattern
  observations.

## Add when

- You hit something interesting but the current task is about
  something else
- A claim is plausible but unverified — note it as a question, not
  as a fact
- A document seems richer than your study cycle captured
- The operator mentions something in passing you'd lose otherwise

## Don't add when

- The thing is a discrete verifiable claim → `memory_write` (it's a
  fact, not a curiosity)
- The thing is a complete deliverable → `create_draft` (it's a
  document, not an index entry)
- The thing belongs to a single cycle's reflection → `write_journal`
  (it's a daily entry, not a persistent index)

## Review cadence

When the sensorium shows low novelty or a quiet cycle, a useful
move is `read_note(slug="curiosities")` or `read_note(slug="open-questions")`
to see what you flagged and decide if anything is worth pulling
forward into work.

## Format inside each note

Append, don't replace. New entries on top with a date stamp:

```
## 2026-04-25
- Operator mentioned the H-CogAff alarm layer in passing — never
  unpacked. Worth a session.
- Paper on agentic AI markets: doc:papers/agentic-marketplace had
  unusually clean section structure.

## 2026-04-23
- Why does pdftotext lose two-column layout? Could marker be
  better? Open question.
```

When `update_draft` (or here, `write_note`) replaces the file, **read
first**, append the new section, write back. Don't overwrite history.
