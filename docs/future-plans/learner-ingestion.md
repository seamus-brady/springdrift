# Learner Ingestion System — Plan

**Status**: Planned
**Date**: 2026-03-26
**Source**: springdrift-learner-ingestion-spec.md
**Dependency**: CBR categories (implemented), fact provenance (implemented)

---

## Table of Contents

- [Overview](#overview)
- [Why This Matters](#why-this-matters)
- [Filesystem Layout](#filesystem-layout)
- [Pipeline](#pipeline)
  - [Phase 1 — Normalise](#phase-1-normalise)
  - [Phase 2 — Study](#phase-2-study)
  - [Phase 3 — Promote](#phase-3-promote)
- [Staleness Handling](#staleness-handling)
- [Ingestion Status Lifecycle](#ingestion-status-lifecycle)
- [New Components](#new-components)
- [Relationship to Skills](#relationship-to-skills)
- [Existing Infrastructure Already Supports This](#existing-infrastructure-already-supports-this)
- [Implementation Estimate](#implementation-estimate)
- [Budget Concern](#budget-concern)


## Overview

Top-down knowledge acquisition from operator-supplied materials. Complements the existing bottom-up learning loop (narrative → Archivist → CBR) by allowing the agent to study source documents and build case knowledge before encountering a domain in lived experience.

**Key architectural principle**: Ingestion produces narrative, not extracted records. The Ingestor agent runs active study cycles that write NarrativeEntry records, which the existing Archivist processes into CbrCase and MemoryFact records. No new retrieval mechanism is required.

## Why This Matters

- The legal vertical (market analysis) depends on this: "structured study cycles against case law, statutes, and treatises"
- Insurance underwriting needs domain knowledge seeded before the first claim
- Currently Springdrift only learns from experience — it can't be taught
- The CBR system has `DomainKnowledge` category (already implemented) ready for ingested cases

## Filesystem Layout

```
.springdrift/knowledge/
├── inbox/                     # Drop zone — unprocessed raw materials
├── sources/                   # Normalised source documents (immutable)
│   └── {domain}/{slug}.md
├── derived/                   # Staging before promotion to cbr/ and facts/
│   └── {source-slug}-{id}.json
└── index.toml                 # Manifest tracking all sources
```

## Pipeline

### Phase 1 — Normalise
File appears in `inbox/` → clean markdown → write to `sources/{domain}/{slug}.md` → append to `index.toml` (status: Normalised) → delete from inbox.

Sources are **immutable once written**. Updates create new versioned slugs; old entries marked Stale.

### Phase 2 — Study
Ingestor agent reads normalised source → runs active study cycle (reasoning, not extraction) → writes NarrativeEntry records with `study:` cycle ID prefix → updates index (status: Studied).

The study prompt instructs the agent to:
- Identify core problem/solution structure
- Note connections to existing CBR cases
- Mark comprehension gaps as Pitfall candidates
- Write standard NarrativeEntry records

### Phase 3 — Promote
Existing Archivist processes study cycle narratives → generates CbrCase (category: DomainKnowledge) and MemoryFact records → updates index (status: Promoted).

**No changes to the Archivist required.** Study narratives are identical to task narratives from the Archivist's perspective.

## Staleness Handling

When source content changes:
1. Compute new sha256 hash, compare against index
2. Mark old entry as Stale
3. Soft-delete derived CBR cases (`redacted = True` — already supported)
4. Write new source version, re-run Study and Promote

Stale cases retained in JSONL for introspection — history of what the agent previously understood is preserved.

## Ingestion Status Lifecycle

```
Pending → Normalised → Studied → Promoted
                                    ↓
                                  Stale (on source update → re-study)
```

## New Components

| Component | Purpose |
|---|---|
| `src/knowledge/types.gleam` | SourceDoc, IngestionStatus |
| `src/knowledge/ingestor.gleam` | OTP agent: normalise, study, promote, check staleness |
| `src/knowledge/index.gleam` | Parse/update index.toml |
| `src/paths.gleam` additions | knowledge_dir, inbox, sources, derived, index paths |

## Relationship to Skills

| | Skills | Knowledge Sources |
|---|---|---|
| Purpose | *How to behave* | *Facts about the world* |
| Loaded | At session start (system prompt) | Via CBR retrieval at query time |
| Authored by | Operator | Operator-supplied, agent-normalised |
| Format | SKILL.md with frontmatter | Plain markdown |

## Existing Infrastructure Already Supports This

- `CbrCategory::DomainKnowledge` — already implemented (Enhancement 3)
- `CbrCase.redacted` field — already exists for soft-deletion
- `source_narrative_id` on CbrCase — repurposable as `study:{slug}:{hash}`
- `sha256_hex` in springdrift_ffi.erl — already available
- TOML parsing — existing config infrastructure
- Archivist two-phase pipeline — handles study narratives without modification
- Fact provenance — study-derived facts tagged with `derivation: DirectObservation`

## Implementation Estimate

~400-500 lines of new code. Medium effort. The heavy lifting (Archivist, CBR, Librarian) is already built.

## Budget Concern

Study cycles make LLM calls — potentially many for large documents. Needs per-source token budgets and rate limiting. Could be batched during off-peak hours via the scheduler.
