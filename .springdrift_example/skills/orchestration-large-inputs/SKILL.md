---
name: orchestration-large-inputs
description: How to orchestrate work across large documents and multi-agent delegations without burning token budgets. Reconnaissance-first, search-then-read, parallel-after-reconnaissance.
agents: cognitive
---

# Orchestrating Work Across Large Inputs

When the operator hands you a large input — a 9000-line book, two long
documents to compare, a sprawling research question — your reflex
will be to dispatch researchers and writers to do the work. **Don't
just dispatch.** The right strategy comes in three layers.

## 1. Reconnaissance-first

Before parallel dispatch, before deep section reads, **spend one
small delegation mapping the structure**. The recon delegation:

- Calls `document_info` to confirm the doc is structured and gauge size
- Calls `list_sections` (with `max_depth: 1` for very large books) to
  capture the chapter-level tree
- Returns a compact outline + the section ids you'll need
- **Calls `checkpoint("doc-outline-<doc_id>", outline)`** to save the outline as an artifact and returns the artifact_id in its summary

Without this step, every downstream researcher independently
re-discovers the same structure, blowing token budget on
bootstrapping rather than on the actual work. In the 2026-04-26
incident, 13 researchers each paid this cost separately on a
309-section book.

## 2. Pass the recon artifact to downstream agents

Every subsequent delegation gets the recon artifact_id via the
`referenced_artifacts` parameter:

```
agent_researcher({
  instruction: "Read chapters 3 and 5 and extract memory architecture comparisons",
  referenced_artifacts: "art-recon-abc123"
})
```

The framework auto-prepends the artifact's CONTENT (not just its ID)
as a `<reference_artifact>` block to the agent's first message. The
child sees the structure immediately and doesn't pay the bootstrap
cost. You can pass multiple artifact ids comma-separated.

## 3. Search-then-read, never read-then-search

For any document over a few hundred lines, prefer:

```
search_library("memory architecture") → returns hits with line spans
read_range(doc_id, line_start, line_end + buffer) → targeted excerpt
```

Over:

```
list_sections(doc_id) → 309 entries
read_section_by_id × N → many calls
```

Sequential `list_sections → read_section_by_id` walks are inherently
expensive on large books. The semantic-search-then-targeted-range
pattern surfaces only the relevant material at a fraction of the
token cost.

## 4. Parallel-after-reconnaissance

Parallel dispatch is a force multiplier **after** the structural
context cost has been paid once. The valid sequence:

1. One reconnaissance delegation → produces and checkpoints the outline
2. Dispatch N parallel followups, each with the recon artifact_id in `referenced_artifacts`
3. Synthesise their results in your own response (see `when-to-use-writer`)

What to NOT do: parallel-dispatch N agents who each independently
re-discover the structure. That's not parallelism, it's
N-fold-bootstrap-cost. In Nemo's 2026-04-26 session, "two parallel
researchers, one per document" was attempted — both capped because
both were independently re-bootstrapping. Parallelism without recon
multiplies cost; with recon it multiplies throughput.

## When this applies

- Large document analysis (>500 lines or >50 sections)
- Multi-document comparisons
- Multi-topic research where each topic spans the same source material
- Anything where you'd otherwise dispatch the same orientation work
  multiple times

## When it doesn't apply

- Short input (a paragraph, a code snippet, a one-page memo) — the
  bootstrap cost is negligible, just dispatch directly
- One-shot tasks that don't need parallel breakdown
- Cases where the operator has already provided structured context
  in the prompt (no recon needed)

## Companion: checkpointing during long work

When YOU yourself are doing synthesis work in your own response, save
checkpoints as you go via `checkpoint(label, content)`. Your output
budget is finite; the truncation guard catches catastrophic capping
but you should never rely on it as the routine recovery. Save in
chunks, reference the artifact_ids when you reply.
