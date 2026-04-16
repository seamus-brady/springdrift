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
- `read_section` — read one section without loading the full document

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
