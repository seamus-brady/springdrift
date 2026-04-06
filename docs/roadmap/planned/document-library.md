# Document Library — Notes, Journals, and Project Documents

**Status**: Planned
**Priority**: Medium — extends memory beyond structured stores
**Effort**: Large (~500-800 lines)

## Problem

The agent's memory is optimised for structured data — narrative entries, CBR
cases, facts, artifacts. But operators and agents also need to work with
longer-form documents: project notes, meeting summaries, journal entries,
research digests, reference materials, and ongoing project updates.

Currently, large content goes into the artifact store (50KB truncation) or
facts (key-value, no structure for long text). Neither is suitable for
documents the agent should maintain, update, and reference over time.

There is no concept of a document the agent owns and curates — something
it writes to, revises, and consults as part of its ongoing work.

## Proposed Solution

### 1. Document Store

A new memory store for agent-managed documents:

```
.springdrift/memory/documents/
├── index.jsonl              Document metadata (id, title, type, created, updated, tags)
└── docs/
    ├── <doc-id>.md          Document content (Markdown)
    └── ...
```

Each document has:
- Stable ID (UUID)
- Title, type (note, journal, report, reference, project-update)
- Tags for retrieval
- Created/updated timestamps
- Content in Markdown (no size limit — these are full documents)

### 2. Document Types

- **Notes** — free-form, operator or agent created
- **Journal** — chronological entries, agent appends after significant work
- **Project updates** — structured status reports on endeavours/tasks
- **Reference** — operator-supplied materials the agent should consult
- **Library** — curated collection of external documents the agent has
  processed and summarised

### 3. Tools

- `create_document(title, type, content, tags)` — create a new document
- `update_document(id, content)` — replace or append to document content
- `list_documents(type?, tags?)` — search by type and tags
- `read_document(id)` — retrieve full content
- `delete_document(id)` — remove a document

### 4. Integration Points

- The Curator could inject document summaries into the system prompt
  (similar to how facts and CBR cases are injected)
- The Archivist could auto-create journal entries after significant work
- The writer agent could be delegated document creation/editing tasks
- Documents could be attached to endeavours as project documentation

## Open Questions

- Should documents be versioned (git-style history within the store)?
- How should document content interact with the preamble budget?
- Should the Librarian index document content for full-text search?
- Relationship to the planned knowledge management feature?
