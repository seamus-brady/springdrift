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

## Access Control

The document library has three actors: the **operator** (human using the web
GUI or email), the **agent** (cognitive loop and specialist agents), and
the **system** (automated pipelines like study cycles and inbox polling).

### Permission Model

| Action | Operator | Agent | System |
|---|---|---|---|
| Upload to inbox | Yes | Yes (store_as_source) | Yes (email attachments) |
| Delete a source | Yes | No — must request_human_input | No |
| Trigger re-study | Yes (UI button) | Yes (if source is stale) | Yes (auto on stale detect) |
| Create export | No | Yes (writer/cognitive) | No |
| Approve export | Yes (UI button) | No — agent cannot self-approve | No |
| Delete export | Yes | No | No |
| Download | Yes | N/A | N/A |
| Deliver via email | Yes (UI button) | Yes (if export is Final) | No |

Key constraints:
- **The agent cannot delete operator-uploaded sources.** If the agent wants
  to remove a document, it must use `request_human_input` to ask the operator.
  This prevents the agent from silently discarding reference material.
- **The agent cannot approve its own exports.** For interactive cycles, the
  operator is the quality gate. For autonomous cycles, D' output gate
  evaluates the export — but the operator must still click "Approve" to
  move it to Final status before delivery.
- **System actions are always logged.** Automated study cycles, inbox
  processing, and email attachment ingestion produce audit entries in the
  document metadata so the operator can see what happened and when.

### Multi-Tenant Extension

In multi-tenant mode, documents are scoped to tenants:
- Each tenant has an isolated `knowledge/` directory
- Uploads are scoped to the authenticated tenant
- Documents from one tenant are never visible to another
- Federated document exchange carries source tenant ID in provenance

---

## Storage Quotas and Cleanup

### Quota Enforcement

The `max_size_mb` config (default 500MB) caps the total size of
`.springdrift/knowledge/`. Enforcement happens at three points:

1. **Upload rejection** — when the inbox receives a new file and accepting
   it would exceed the quota, the upload is rejected with a clear error:
   "Knowledge library is full (487/500 MB). Remove unused documents or
   increase [knowledge] max_size_mb." The WebSocket sends a
   `DocumentUploadRejected` notification so the operator sees it immediately.

2. **Study cycle skip** — if a normalised source would generate an index
   that pushes past the quota, the study cycle is skipped and the document
   stays in "normalised" status. A sensory event warns the agent:
   "knowledge_quota_pressure: 97% of 500MB used, study cycle deferred."

3. **Export write** — if saving an export would exceed quota, the export
   content is held in memory and the agent reports: "Export ready but
   knowledge directory is full. Approve a cleanup to save it."

### Disk Pressure Signals

The sensorium's `<knowledge>` section includes quota status:

```xml
<knowledge documents="34" sources="28" exports="6"
  usage_mb="312" quota_mb="500" usage_pct="62"
  stale="2" pending="1" />
```

When usage exceeds 80%, the `usage_pct` attribute triggers a
`knowledge_quota_warning` sensory event (once, not every cycle). At 95%,
a `knowledge_quota_critical` event fires. These are informational — the
agent can suggest cleanup but cannot delete operator sources.

### Automated Cleanup

The system can automatically clean up:
- **Superseded consolidation reports** — when a new weekly consolidation
  is generated, the previous one for the same period is eligible for
  removal after 30 days (configurable via `consolidation_retention_days`)
- **Orphaned indexes** — tree indexes in `indexes/` with no matching
  source document are removed on startup
- **Failed inbox items** — files in `inbox/` that failed normalisation
  are moved to `inbox/failed/` with an error log, and cleaned up after
  7 days

The system never automatically deletes:
- Operator-uploaded sources (any status)
- Exports (any status)
- Documents with derived CBR cases still in active use

### Manual Cleanup

The operator can:
- Delete individual documents via the web GUI (sidebar → right-click → Delete)
- Bulk-delete by domain (sidebar → right-click domain folder → "Delete all")
- The `remove_document` tool is available but restricted (agent must confirm
  via request_human_input for operator-uploaded sources)

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
# consolidation_retention_days = 30   # Days to keep superseded consolidation reports
# quota_warning_pct = 80              # Emit warning sensory event at this usage %
# quota_critical_pct = 95             # Emit critical sensory event at this usage %
```

---

## Web GUI — Documents Panel

The Documents panel is a tab in the web GUI alongside Chat, Log, Narrative,
Scheduler, and Cycles. It gives the operator full visibility and control
over the knowledge lifecycle.

### Layout

```
┌─ Documents ─────────────────────────────────────────────────┐
│                                                              │
│  ┌─ Sidebar ──────────┐  ┌─ Main Panel ──────────────────┐ │
│  │                     │  │                               │ │
│  │  📂 Knowledge Base  │  │  [Rendered document content]  │ │
│  │    legal/           │  │                               │ │
│  │      aamodt...  ✅  │  │  Section navigation:          │ │
│  │      contract.. 📖  │  │  1. Introduction              │ │
│  │    research/        │  │  2. Background                │ │
│  │      gartner..  ⏳  │  │    2.1 Prior work             │ │
│  │                     │  │    2.2 Methodology            │ │
│  │  📥 Inbox (1)       │  │  3. Results                   │ │
│  │    report.pdf  ⏳   │  │                               │ │
│  │                     │  └───────────────────────────────┘ │
│  │  📤 Exports         │  ┌─ Detail Sidebar ─────────────┐ │
│  │    q2-analysis ✅   │  │  Status: Promoted             │ │
│  │                     │  │  Domain: legal                │ │
│  │  🔍 [Search...]     │  │  Indexed: 34 nodes            │ │
│  │                     │  │  Studied: 2026-04-10          │ │
│  └─────────────────────┘  │  CBR cases: 3 derived         │ │
│                            │  Facts: 7 derived             │ │
│  [+ Upload] [↻ Re-index]  │  Hash: sha256:abc1...         │ │
│                            └──────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

### Three Sections in Sidebar

**Knowledge Base** (sources):
- Tree view organised by domain
- Status icons: ⏳ Pending, 📖 Studied, ✅ Promoted, ⚠️ Stale
- Click to view rendered markdown with section navigation
- Section navigation built from the tree index (clickable headings)

**Inbox**:
- Shows pending uploads not yet normalised
- Drag-and-drop zone or file picker button
- Progress indicator during normalisation
- Auto-clears when documents move to sources/

**Exports**:
- Reverse chronological list of agent-generated reports
- Status: Draft, Reviewed, Final, Delivered
- Download as Markdown or HTML
- Delivery history (who received it, when, via which channel)

### Document Viewer (Main Panel)

Click any document in the sidebar to view:
- Rendered markdown in the main area
- Section navigation from the tree index (jump to heading)
- For sources: study status, number of derived CBR cases and facts
- For exports: D' score, delivery recipients, linked endeavour

### Detail Sidebar

Metadata panel showing:
- Document status and lifecycle stage
- Domain classification
- Content hash and version
- Node count from tree index
- Provenance: source URL, upload date, who uploaded
- Derived artifacts: linked CBR case IDs, fact keys

### Upload Flow

1. Operator drags file to inbox area (or clicks "Upload" button)
2. HTTP POST to `/api/documents/upload` with multipart form data
3. Server writes to `.springdrift/knowledge/inbox/`
4. WebSocket notification: `DocumentUploaded { filename, status: "pending" }`
5. If auto_study enabled: normalisation runs, then study cycle triggers
6. Progress updates via WebSocket: `DocumentStatusChanged { doc_id, status }`
7. Document appears in Knowledge Base sidebar when normalised

### Supported Upload Formats

- Markdown (.md) — stored directly, no conversion needed
- Plain text (.txt) — stored directly
- PDF (.pdf) — text extracted via Erlang or external tool, stored as markdown
- Operator can also paste a URL — researcher fetches and normalises

### Download / Export

- Any document downloadable as raw markdown
- Exports downloadable as markdown or HTML
- Bulk export of all sources for a domain (zip)

### HTTP Endpoints

| Method | Path | Purpose |
|---|---|---|
| POST | `/api/documents/upload` | Upload file to inbox |
| GET | `/api/documents` | List all documents (JSON) |
| GET | `/api/documents/:id` | Get document content + metadata |
| GET | `/api/documents/:id/tree` | Get tree index for section navigation |
| DELETE | `/api/documents/:id` | Remove document |
| POST | `/api/documents/:id/restudy` | Trigger re-study cycle |

### WebSocket Messages

| Client → Server | Server → Client | Purpose |
|---|---|---|
| `RequestDocuments` | `DocumentsData` | Initial document list |
| — | `DocumentUploaded` | New upload notification |
| — | `DocumentStatusChanged` | Status transition notification |
| `RequestDocumentTree` | `DocumentTreeData` | Tree index for section nav |

---

## Email Attachments — Inbound Document Pipeline

When the comms agent receives an email with attachments, they flow into the
document library automatically. This bridges the gap between the email
channel and the knowledge pipeline.

See also: [mail-attachments.md](mail-attachments.md) for the full attachment spec.

### Inbound Flow

```
Email with attachment arrives
  → Inbox poller detects attachment metadata
  → Attachment content fetched via AgentMail API
  → Written to .springdrift/knowledge/inbox/{message-id}-{filename}
  → Document metadata logged with provenance: source_type = "email",
    sender, message_id, received_at
  → If auto_study enabled: normalisation + study cycle runs
  → Agent notified via sensory event: "new document from email"
```

### Provenance

Email-sourced documents carry full provenance:
- `source_type: "email"`
- `sender: "alice@example.com"`
- `message_id: "msg-abc123"`
- `received_at: "2026-04-16T10:00:00Z"`
- `subject: "Q2 market data attached"`

This traces all the way through: email → inbox → source → study → CBR case.

### Safety

- Inbound attachments pass through the D' input gate before acceptance
- Executable files (.exe, .sh, .bat) are rejected at the deterministic layer
- Content is scanned for prompt injection patterns (same as web content)
- Attachments from senders not on the comms allowlist are quarantined
  (logged but not processed until operator approves)

### Supported Attachment Types

- Text/Markdown — direct to inbox
- PDF — text extracted, stored as markdown
- Images — stored as artifacts (not indexed as knowledge)
- Other — stored as artifacts with metadata, not auto-studied

---

## Operator Experience — End to End

### Uploading a Document

1. Open web GUI → Documents tab
2. Drag a PDF into the inbox zone (or click Upload)
3. See "market-report.pdf — Pending" appear in inbox
4. Within seconds: status changes to "Normalised" — the markdown extraction ran
5. If auto_study is on: status changes to "Studying..." with a progress note
6. After study completes: document moves to Knowledge Base under its domain
7. Status shows "Promoted" with a count of derived CBR cases and facts
8. Click the document to read the rendered markdown with section headings

### Searching the Library

1. Type a query in the search box in the Documents sidebar
2. Results appear ranked by relevance with provenance breadcrumbs:
   `legal / aamodt-plaza-1994 / Section 3.2 — Similarity Assessment`
3. Click a result to jump directly to that section in the viewer
4. The agent can also search the library via chat: "What do our legal
   sources say about similarity assessment in CBR?"

### Receiving a Document via Email

1. Someone emails an attachment to the agent's address
2. The comms agent picks it up and routes the attachment to inbox
3. A toast notification appears: "New document from alice@example.com"
4. The document appears in inbox, then flows through the normal pipeline
5. The operator can view it in the Documents panel or ask the agent about it

### Monitoring Study Progress

1. Documents in "Studying" state show which cycle is running
2. The Narrative tab shows study cycle entries as they're written
3. Once promoted, the detail sidebar shows derived artifacts:
   "3 CBR cases, 7 facts derived from this document"
4. The operator can trigger a re-study via the "Re-index" button if the
   source content has changed

### Working with Exports

1. The agent generates a report (via writer agent or cognitive loop)
2. The report appears in Exports as "Draft"
3. For autonomous cycles: D' output gate evaluates → status becomes "Reviewed"
4. Operator reads it, clicks "Approve" → status becomes "Final"
5. Operator clicks "Send" → comms agent delivers to configured recipients
6. Status becomes "Delivered" with recipient list and timestamp

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
| 11 | Web GUI Documents panel (upload, browse, viewer, section nav) | Large | Phase 1-10, Web GUI v2 |
| 12 | PDF support (text extraction + page-level indexing) | Medium | Phase 2 |
| 13 | Email attachment inbound pipeline (comms → inbox) | Medium | Phase 5, mail-attachments |
| 14 | Export approval + delivery workflow (approve → comms send) | Medium | Phase 10, comms agent |
| 15 | LLM reasoning retrieval (Tier 3) | Medium | Phase 2 |

**Phase 1-4 is the MVP**: directory structure, tree indexer, embedding search, tools.
Delivers a working document library the agent can index and search.

**Phase 5-7 adds the knowledge pipeline**: documents flow through study cycles
into CBR and facts.

**Phase 8-10 adds internal awareness**: sensorium, consolidation, exports.

**Phase 11-14 adds the operator experience**: web GUI with upload/browse/viewer,
email attachment pipeline, export approval and delivery workflow.

**Phase 15 adds advanced retrieval**: LLM reasoning search for complex queries.

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
