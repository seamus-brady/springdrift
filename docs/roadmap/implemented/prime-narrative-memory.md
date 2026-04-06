# Prime Narrative and Memory Architecture — Implementation Record

**Status**: Implemented
**Date**: 2026-03-15 onwards
**Source**: springdrift_prime_narrative.docx, springdrift-memory-architecture.docx

---

## Table of Contents

- [Overview](#overview)
- [Memory Stores](#memory-stores)
- [Key Actors](#key-actors)
  - [Librarian (`narrative/librarian.gleam`)](#librarian-narrativelibrariangleam)
  - [Curator (`narrative/curator.gleam`)](#curator-narrativecuratorgleam)
  - [Archivist (`narrative/archivist.gleam`)](#archivist-narrativearchivistgleam)
  - [Housekeeper (`narrative/housekeeper.gleam`)](#housekeeper-narrativehousekeepergleam)
- [Memory Tools (21 tools)](#memory-tools-21-tools)
- [Threading](#threading)
- [Identity System (`identity.gleam`)](#identity-system-identitygleam)


## Overview

Eight-store memory architecture backed by append-only JSONL files, indexed in ETS by the Librarian actor. Enables the agent to remember across sessions, track ongoing investigations, and learn from past outcomes.

## Memory Stores

| Store | Location | Unit | Purpose |
|---|---|---|---|
| Narrative | `memory/narrative/YYYY-MM-DD.jsonl` | NarrativeEntry | What happened each cycle: summary, intent, outcome, entities, delegation chain |
| Threads | (derived from narrative entries) | Thread/ThreadState | Ongoing lines of investigation, grouped by overlap scoring |
| Facts | `memory/facts/YYYY-MM-DD-facts.jsonl` | MemoryFact | Key-value working memory with scope, confidence, provenance, and half-life decay |
| CBR Cases | `memory/cbr/cases.jsonl` | CbrCase | Problem-solution-outcome patterns with categories and usage stats |
| Artifacts | `memory/artifacts/artifacts-YYYY-MM-DD.jsonl` | ArtifactRecord | Large content on disk (web pages, extractions), 50KB truncation |
| Tasks | `memory/planner/YYYY-MM-DD-tasks.jsonl` | PlannerTask | Planned work with steps, dependencies, risks, forecast scores |
| Endeavours | `memory/planner/YYYY-MM-DD-endeavours.jsonl` | Endeavour | Multi-task initiatives |
| DAG Nodes | (in-memory ETS from cycle log) | CycleNode | Operational telemetry per cycle |

## Key Actors

### Librarian (`narrative/librarian.gleam`)
- Unified query layer over all memory stores
- Owns ETS tables for fast queries (narrative, threads, facts, CBR, artifacts, DAG)
- Replays JSONL at startup (configurable window via `librarian_max_days`)
- Messages: QueryDayRoots, QueryDayStats, QueryNodeWithDescendants, QueryThreadCount, etc.
- CBR config includes retrieval weights and decay half-life

### Curator (`narrative/curator.gleam`)
- Assembles system prompt from identity + memory
- Builds sensorium XML (clock, situation, schedule, vitals with meta-states)
- Renders `{{slot}}` substitutions and `[OMIT IF]` rules
- Preamble budget enforcement with priority-based truncation
- Triggers budget-triggered housekeeping when CBR content truncated

### Archivist (`narrative/archivist.gleam`)
- Fire-and-forget `spawn_unlinked` after each cycle
- Two-phase Reflector/Curator pipeline (per ACE paper)
- Phase 1: plain-text insight extraction
- Phase 2: XStructor-structured NarrativeEntry + CbrCase
- Assigns thread, category, provenance, and initialises usage stats
- Updates CBR usage stats for retrieved cases
- Falls back to single-call on Phase 1 failure

### Housekeeper (`narrative/housekeeper.gleam`)
- Supervised GenServer for periodic ETS/memory maintenance
- Three tick intervals: short (6h), medium (12h), long (24h)
- CBR dedup via weighted field similarity
- Case pruning (old low-confidence failures, harmful cases)
- Fact conflict resolution
- Thread pruning (single-cycle threads after N days)
- Budget-triggered dedup on demand from Curator

## Memory Tools (21 tools)

| Tool | Store | Purpose |
|---|---|---|
| `recall_recent` | Narrative | Entries for a time period |
| `recall_search` | Narrative | Keyword search |
| `recall_threads` | Threads | Active research threads |
| `recall_cases` | CBR | Similar past cases (max K=4) |
| `memory_write` | Facts | Store fact with provenance |
| `memory_read` | Facts | Read with confidence decay |
| `memory_clear_key` | Facts | Remove a fact |
| `memory_query_facts` | Facts | Search by keyword |
| `memory_trace_fact` | Facts | Full history of a key |
| `store_result` | Artifacts | Store large content |
| `retrieve_result` | Artifacts | Retrieve by ID |
| `reflect` | DAG | Day-level stats |
| `inspect_cycle` | DAG | Drill into cycle tree |
| `list_recent_cycles` | DAG | Discover cycle IDs |
| `query_tool_activity` | DAG | Per-tool usage stats |
| `introspect` | All | System state |
| `how_to` | HOW_TO.md | Operator guide |
| `cancel_agent` | Registry | Stop agent |
| `report_false_positive` | Meta | Flag D' rejection |
| `correct_case` / `annotate_case` / `suppress_case` / `boost_case` | CBR | Case management |

## Threading
- Overlap scoring: location=3, domain=2, keyword=1, topic=1
- Threshold for thread assignment: configurable (default 3)
- Entries auto-assigned to most similar existing thread
- New thread created when no match exceeds threshold

## Identity System (`identity.gleam`)
- Persona loading from `identity/persona.md`
- Preamble template from `identity/session_preamble.md`
- `{{slot}}` substitutions and `[OMIT IF]` rules
- Agent UUID persisted in `identity.json`
