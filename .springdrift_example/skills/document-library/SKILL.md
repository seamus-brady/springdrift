---
name: document-library
description: When and how to use the document library
agents: cognitive, researcher, writer
---

# Document Library

You have a persistent document library for storing, searching, and managing
documents across sessions. It has two halves:

## Reference Library (sources)
Papers, books, articles, and reference material. Indexed into searchable
sections. Use for anything worth citing later.

**When to save**: papers, key articles, domain reference material. NOT
every web page — that's artifacts. Save it if you'd want to cite it.

**Tools**:
- `save_to_library` — store content permanently, indexed by section
- `search_library` — find passages (embedding mode default, keyword for exact)
- `document_info` — inspect a doc's shape (structured vs flat, line count) before deciding how to read
- `list_sections` — enumerate the section tree for a structured doc; returns ids you can pass to `read_section_by_id`
- `read_section_by_id` — read one section by its exact id from `list_sections` (no fuzzy title matching)
- `read_range` — read a line range; the universal primitive that works on any document, including flat ones with no headings

## Reading a document — the decision tree

When you are handed a `doc_id` you've never seen, **call `document_info` first**.
It is cheap (no LLM, no embedding) and tells you whether the document has a
section tree to navigate or is a single block of text.

- **Structured (`structured: true`)**: the document has chapters / sections.
  Call `list_sections` to see the tree, pick a section_id from the result,
  then call `read_section_by_id`. Do NOT guess section titles — the old
  `read_section` tool that fuzzy-matched titles has been removed because it
  could silently return the wrong section when a short query matched
  multiple node titles.
- **Flat (`structured: false`)**: there's no section tree. Either:
  - Read the whole doc with `read_range(doc_id, 1, total_lines)` if it's
    small (use `total_lines` from `document_info`), or
  - Use `search_library` to find relevant chunks, then `read_range` for
    surrounding context using the line numbers in the search hits.

`read_range` is also the right tool for reading context around a search
hit on either kind of document — search results give you line spans, and
`read_range` slices the source markdown directly.

`read_range` is capped at 2000 lines per call. For larger reads, chunk
into multiple calls.

## Your Workspace
Your own documents — journal, notes, drafts. Persists across sessions.

### Journal
Append-only daily reflections. Write when something is worth recording —
a discovery, a changed understanding, a completed task. Not every cycle.
- `write_journal` — append to today's journal

### Notes
Mutable scratch documents. Running lists, comparison tables, research notes.
- `write_note` — create or replace a note by slug
- `read_note` — read a note

### Drafts
Reports in progress. Revise across multiple sessions, promote when ready.
- `create_draft` / `update_draft` — write and revise
- `promote_draft` — move to exports (pending operator approval)

## Browsing
- `list_documents` — see everything in the library (filter by type/domain)

## Search Tips
- Use **embedding** mode (default) for semantic queries
- Use **keyword** mode for exact phrases or known terms
- Filter by **domain** to narrow results
- Always include citations when referencing library sources in reports

## Citations
Search results include formatted citations:
`[Document Title, §Section Name, lines 145-178]`
Include these in reports so claims are traceable to sources.

## Checkpointing — don't blow your token cap on a synthesis

When producing structured output (multi-section drafts, multi-topic
comparisons, anything over ~500 words), **call `checkpoint(label,
content)` after each major section**. Don't try to assemble the
whole final output in one response — that's how you blow your
token cap and lose all the work.

`checkpoint` is the lightweight sibling of `store_result`: just a
label and content. It writes to the artifact store with sensible
defaults and returns a compact `artifact_id` you can reference
later or hand back to your orchestrator.

**Pattern**:
1. Write section 1 → `checkpoint("draft-section-1-memory", content)` → got `art-abc123`
2. Write section 2 → `checkpoint("draft-section-2-affect", content)` → got `art-def456`
3. Write section 3 → `checkpoint("draft-section-3-safety", content)` → got `art-789xyz`
4. Final response: brief summary + the three artifact IDs. Orchestrator can retrieve any of them with `retrieve_result`.

**Anti-pattern**: try to write all three sections inline in one
final response, hit `max_tokens` mid-section-2, ship a half-finished
output (or worse, get caught by the truncation guard and ship a
[truncation_guard:writer] admission with no artifacts to recover
from). The truncation guard is a safety net, not a substitute for
discipline.

This is especially important for the writer agent (synthesis is its
job) and for the researcher when extracting from large documents.

## Sharing context between agents — referenced_artifacts

When you delegate to a sub-agent that needs the same structural
context another agent already produced (e.g. a section outline,
prior findings, a checkpoint), pass the artifact_ids on the
delegation tool call via `referenced_artifacts: "art-abc123,art-def456"`.
The framework auto-prepends the artifact CONTENT as
`<reference_artifact>` blocks to the child's first message — the
child sees it immediately without calling `retrieve_result`.

**Pattern for large document tasks**: one reconnaissance delegation
to map the structure → checkpoint the outline → dispatch N parallel
followups, each carrying the outline ID via `referenced_artifacts`.
Eliminates the redundant-bootstrap cost of every child re-discovering
the same structure.
