# Virtual Memory Management — Implementation Record

**Status**: Implemented
**Date**: 2026-03-17 onwards
**Source**: narrative/virtual_memory.gleam, narrative/curator.gleam

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Named Slots](#named-slots)
- [Budget Enforcement (`apply_preamble_budget`)](#budget-enforcement-applypreamblebudget)
- [Slot Rendering](#slot-rendering)
- [What Makes This Different](#what-makes-this-different)
- [Configuration](#configuration)


## Overview

Fixed-budget context window management with named, prioritised slots. Solves the context engineering problem that most agent frameworks leave to the user: how to fit memory, identity, task context, and tool results into a finite token budget without losing critical information.

Inspired by Letta's virtual memory pattern — a fixed set of named memory slots with deterministic allocation, not an unbounded dump of everything into the prompt.

## Architecture

```
narrative/virtual_memory.gleam  — Slot definitions, rendering, CBR grouping by category
narrative/curator.gleam         — Slot assembly, budget enforcement, sensorium generation
```

## Named Slots

The system prompt is assembled from prioritised slots, highest priority first:

| Priority | Slot | Content | Source |
|---|---|---|---|
| 1 | `identity` | Agent persona from `identity/persona.md` | Static file |
| 2 | `sensorium` | Ambient perception XML (clock, situation, schedule, vitals, tasks, events, delegations) | Computed per cycle by Curator |
| 3 | `active_threads` | Ongoing research threads with domains, keywords, data points | Librarian query |
| 4 | `recent_facts` | Persistent facts with decayed confidence and provenance | Librarian query |
| 5 | `cbr_cases` | Relevant past cases organised by category (Strategies, Pitfalls, Troubleshooting, etc.) | Librarian retrieval |
| 6 | `skills` | Available skills from SKILL.md files | Skills discovery |
| 7 | `schedule_context` | Scheduler job metadata (for scheduler-triggered cycles) | Scheduler query |
| 8 | `working_memory` | Scratchpad for inter-cycle context (agent completions, delegation results) | Cognitive state |
| 9 | `constitution` | Archivist-generated self-model from recent narrative | Updated post-cycle |
| 10 | `background` | Low-priority contextual information | Various |

## Budget Enforcement (`apply_preamble_budget`)

- Configurable `preamble_budget_chars` (default 8000, ~2000 tokens)
- Slots rendered in priority order
- When cumulative chars exceed budget, lower-priority slots are truncated or cleared
- `[OMIT IF EMPTY]` rules in the preamble template handle natural omission of empty slots
- Budget-triggered housekeeping: when CBR content is truncated, signals the Housekeeper to run immediate dedup (with 30-minute debounce)

## Slot Rendering

Each slot is rendered by the Curator into a text block with `{{slot_name}}` substitution in the preamble template:

- **Sensorium**: Self-describing XML with `<clock>`, `<situation>`, `<schedule>`, `<vitals>` (including meta-states), `<tasks>`, `<events>`, `<delegations>` sections
- **CBR cases**: Grouped by CbrCategory (Pitfalls first, then Strategies, Troubleshooting, Code Patterns, Domain Knowledge) with per-case metadata
- **Facts**: Displayed with decayed confidence and provenance tags
- **Threads**: Summarised with domains, keywords, entry count, last activity

## What Makes This Different

Most agent frameworks either:
1. **Dump everything** — concatenate all memory into the prompt, hit token limits, lose information unpredictably
2. **Leave it to the user** — provide raw memory APIs but no allocation strategy
3. **Use RAG retrieval** — vector search for relevant chunks, no guaranteed structure

Springdrift's approach:
- **Named slots** with semantic meaning — the system knows what each section IS, not just what tokens it contains
- **Priority-based truncation** — identity never gets cut; background gets cut first
- **Deterministic assembly** — same state always produces the same prompt (testable, debuggable)
- **Budget awareness** — the system knows when it's running out of room and can trigger cleanup
- **Category-organised CBR** — cases grouped by type (pitfall, strategy, etc.), not just by similarity score

## Configuration

```toml
[narrative]
# Max chars for rendered preamble slots (default: 8000, ~2000 tokens)
# preamble_budget_chars = 8000
```

The budget applies to the preamble (memory section) only. The system prompt, user messages, and tool definitions have their own token budgets managed by `context.trim`.
