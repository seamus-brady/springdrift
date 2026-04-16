# Document Library — Unified Design

**Status**: Planned
**Priority**: High — unifies document-library, knowledge-management, and learner-ingestion
**Effort**: Large (~800-1200 lines across phases)
**Date**: 2026-04-16
**Inputs**: Curragh's PageIndex Library prototype (April 5-6), knowledge-management.md spec, learner-ingestion.md spec

---

## Outcome

Springdrift gains a persistent, self-managed document library. It can ingest
documents (Markdown, PDF, plain text), build structured hierarchical indexes,
and retrieve specific passages using two-tier search: fast keyword matching
for simple lookups, embedding-based semantic search for reasoning queries.
Every retrieval carries provenance: which document, which section, which
page/line. Documents flow through the existing memory pipeline — study cycles
produce narrative entries, the Archivist promotes them to CBR cases and facts.

## Overview

A Gleam-native document library integrated with the existing memory subsystem.
Documents are parsed into hierarchical tree indexes and stored as JSON alongside
the source files. Retrieval reuses the existing Ollama embeddings (CBR pattern)
for semantic search, with an optional LLM reasoning tier for complex queries.
Storage lives in `.springdrift/knowledge/` — persistent across sessions, backed
up by git, indexed in ETS by the Librarian.

This design merges three planned specs into one implementation:
- **document-library.md** — document store, tools, curator integration
- **knowledge-management.md** — inbound/consolidation/export lifecycle, provenance
- **learner-ingestion.md** — inbox → normalise → study → promote pipeline

---

## Architecture

### Storage Layout

```
.springdrift/knowledge/
├── index.jsonl                    # Append-only document metadata log
├── inbox/                         # Drop zone — unprocessed uploads
│   └── market-report.pdf
├── sources/                       # Normalised source documents (immutable)
│   ├── {domain}/
│   │   └── {slug}.md
│   └── ...
├── indexes/                       # Hierarchical tree indexes (one per source)
│   └── {doc-id}.json
├── consolidation/                 # Remembrancer synthesis output
│   └── YYYY-MM-DD-weekly.md
└── exports/                       # Agent-generated deliverables
    └── {title-slug}.md
```

### Document Index (per-document tree)

Inspired by Curragh's PageIndex prototype. Each source document is parsed into
a tree of nodes representing sections, subsections, and content blocks.

```json
{
  "doc_id": "uuid",
  "root": {
    "id": "node-uuid",
    "title": "Section heading",
    "content": "Full text of this section",
    "depth": 0,
    "source": { "line_start": 1, "line_end": 45, "page": null },
    "embedding": [0.12, -0.34, ...],
    "children": [
      {
        "id": "node-uuid-2",
        "title": "Subsection",
        "content": "...",
        "depth": 1,
        "source": { "line_start": 10, "line_end": 30, "page": null },
        "embedding": [...],
        "children": []
      }
    ]
  }
}
```

Embeddings are computed per-node using Ollama (same model as CBR — `nomic-embed-text`).
When embeddings are unavailable, retrieval degrades to keyword search only.

### Document Metadata (index.jsonl)

Append-only, same pattern as other memory stores:

```json
{
  "op": "create",
  "doc_id": "uuid",
  "type": "source",
  "domain": "legal",
  "title": "Case-Based Reasoning: Foundational Issues",
  "path": "sources/legal/aamodt-plaza-1994.md",
  "status": "normalised",
  "content_hash": "sha256:abc123...",
  "node_count": 34,
  "created_at": "2026-04-16T10:00:00Z",
  "source_url": "https://arxiv.org/...",
  "version": 1
}
```

Status lifecycle for sources: `pending → normalised → studied → promoted → stale`

---

## Retrieval (Three Tiers)

### Tier 1 — Keyword Search

Scans node titles and content for term matches. Returns ranked results with
relevance scores. Fast, no LLM or embedding calls. Suitable for known-item
lookups where the operator knows what they're looking for.

### Tier 2 — Embedding Search (default)

Each tree node has a precomputed embedding vector. Query is embedded and
compared against all nodes using cosine similarity (reuses the existing
`cbr/bridge.gleam` scoring pattern). Returns top-K nodes with provenance.
This is the default search mode — high quality at near-zero runtime cost.

When embeddings are unavailable (Ollama not running), degrades to Tier 1
transparently (same pattern as CBR retrieval fallback).

### Tier 3 — LLM Reasoning (optional)

For complex queries that require multi-hop reasoning across document
structure. The LLM traverses the tree top-down: reads root-level titles,
selects promising branches, descends into relevant sections, aggregates
context. Expensive (multiple LLM calls per query) — only triggered when
explicitly requested via tool parameter.

Mirrors Curragh's two-tier design but adds embeddings as the middle tier,
which covers most use cases without LLM cost.

---

## Tools

Six tools, split between the researcher agent and the cognitive loop:

### Researcher Agent Tools

| Tool | Description |
|---|---|
| `index_document` | Parse and index a document from inbox or URL |
| `search_library` | Search indexed documents (keyword/embedding/reasoning) |
| `get_document` | Retrieve full document or specific section by path |

### Cognitive Loop Tools

| Tool | Description |
|---|---|
| `list_documents` | List indexed documents with metadata (type, status, domain) |
| `store_as_source` | Save web content as a knowledge source (promotes from artifact) |
| `remove_document` | Remove a document and its index |

### Tool Parameters

`search_library`:
- `query` (string, required) — the search query
- `mode` (string, optional) — "keyword", "embedding" (default), or "reasoning"
- `max_results` (int, optional) — default 5
- `domain` (string, optional) — filter by domain

`index_document`:
- `filepath` (string) — path in inbox, or URL to fetch
- `domain` (string) — classification domain (legal, research, etc.)
- `title` (string, optional) — override auto-detected title

---

## Integration with Existing Subsystems

### Librarian

The Librarian gains a new ETS table for document metadata (same pattern as
narrative, CBR, facts, artifacts). At startup, replays `index.jsonl` into ETS.
Supports queries: by type, by domain, by status, by date range. The tree
indexes are loaded on-demand (not held in ETS — too large).

### Curator / Sensorium

The sensorium gains a `<knowledge>` section showing document counts by type
and status. When documents are stale (source changed since last study), a
sensory event is emitted so the agent notices without tool calls.

### Archivist / Study Pipeline

Source documents flow through study cycles (from learner-ingestion.md):

```
Source document in sources/{domain}/{slug}.md
  → Researcher reads and extracts key findings
  → NarrativeEntry records written (cycle_id: study:{slug})
  → Archivist processes into CbrCase (category: DomainKnowledge) + MemoryFact
  → Librarian indexes
  → Agent retrieves via recall_cases / memory_read
  → Document status updated to "promoted"
```

No new retrieval mechanism for study-derived knowledge. The existing CBR
pipeline handles it identically to experience-derived knowledge.

### D' Safety

| Document Type | D' Gate | What It Checks |
|---|---|---|
| Source (operator upload) | None — operator is trusted | — |
| Source (agent-discovered) | Tool gate on store_as_source | Standard tool safety |
| Export (report) | Output gate | unsourced claims, accuracy, confidentiality |

---

## Provenance Chain

Every retrieval result carries a full provenance path:

```
Document: sources/legal/aamodt-plaza-1994.md
  → Section: "3.2 Similarity Assessment" (line 145-178)
    → Node ID: node-abc123
      → Derived CBR case: case-xyz789
        → Used in export: exports/q2-analysis.md
```

SD Audit can trace any claim back through the chain to its original source
document and section.

---

## Configuration

```toml
[knowledge]
# enabled = false                     # Enable document library (default: false)
# max_size_mb = 500                   # Max total knowledge directory size
# max_source_size = 1048576           # Max single source document (bytes, default: 1MB)
# auto_study = true                   # Auto-run study cycles on new sources
# max_tree_depth = 6                  # Max index hierarchy depth
# embedding_enabled = true            # Embed tree nodes (reuses CBR embedding config)
# retrieval_max_results = 5           # Default search result count
```

---

## Implementation Phases

| Phase | What | Effort | Depends On |
|---|---|---|---|
| 1 | Knowledge directory + index.jsonl + Librarian ETS | Small | None |
| 2 | Markdown tree indexer (port Curragh's Python to Gleam) | Medium | Phase 1 |
| 3 | Embedding per tree node (reuse Ollama infra) | Small | Phase 2, CBR embeddings |
| 4 | Tools: index_document, search_library, get_document, list_documents | Medium | Phase 2 |
| 5 | Inbox → normalise → sources pipeline | Medium | Phase 1 |
| 6 | Study cycles (Ingestor → Archivist → CBR promotion) | Medium | Phase 5, Archivist |
| 7 | store_as_source tool (researcher → knowledge source) | Small | Phase 5 |
| 8 | Sensorium integration + stale detection | Small | Phase 1 |
| 9 | Consolidation output (Remembrancer → consolidation/) | Medium | Phase 1, Remembrancer |
| 10 | Export storage (agent reports → exports/) | Small | Phase 1 |
| 11 | Web GUI Documents panel | Large | Phase 1-10, Web GUI v2 |
| 12 | PDF support (text extraction + page-level indexing) | Medium | Phase 2 |
| 13 | LLM reasoning retrieval (Tier 3) | Medium | Phase 2 |

**Phase 1-4 is the MVP**: directory structure, tree indexer, embedding search, tools.
Delivers a working document library the agent can index and search.

**Phase 5-7 adds the knowledge pipeline**: documents flow through study cycles
into CBR and facts.

**Phase 8-13 adds polish**: sensorium awareness, consolidation, exports, web
GUI, PDF, and LLM reasoning search.

---

## What Curragh Validated

Curragh's Python prototype (April 5-6) validated:
- Markdown heading hierarchy → tree structure works well
- JSON persistence of tree indexes is sufficient (no database needed)
- Keyword search with relevance scoring covers basic lookups
- Tree-building bug (children not attaching) — watch for this in the Gleam port
- LLM reasoning retrieval was designed but blocked by coder max turns — defer to Phase 13

The prototype's `MarkdownIndexer`, `DocumentIndex`, and `LibraryManager`
map directly to the Gleam implementation in Phases 1-4. The key difference:
the Gleam version integrates with ETS/Librarian instead of standalone JSON
files, and adds embedding search (Tier 2) which the prototype lacked.

---

## Relationship to Other Specs

| Spec | Relationship |
|---|---|
| knowledge-management.md | **Subsumed** — this spec replaces it |
| learner-ingestion.md | **Subsumed** — inbox → study → promote pipeline is Phase 5-6 |
| remembrancer.md | Produces consolidation reports (Phase 9) |
| skills-management.md | Pattern reports from consolidation feed skill proposals |
| comms-agent.md | Delivers exports to stakeholders |
| web-gui-v2.md | Documents panel (Phase 11) |
| sd-audit.md | Provenance chains trace through knowledge sources |
