# The Remembrancer — Deep Memory Agent

**Status**: Implemented (Phases 1–10) — 2026-04-16
**Original design date**: 2026-03-26
**Dependencies**: CBR self-improvement (implemented), Confidence decay (implemented), Archivist split (implemented), Skills management (planned — blocks Phase 11)

## Implementation status

| Phase | Status | Notes |
|---|---|---|
| 1 — Agent spec + system prompt | ✅ Done | `src/agents/remembrancer.gleam`, max_turns=8, Transient restart |
| 2 — `deep_search` tool | ✅ Done | Reads JSONL archive via `remembrancer/reader.gleam` |
| 3 — `fact_archaeology` tool | ✅ Done | Traces key history + related-key discovery |
| 4 — `resurrect_thread` tool | ✅ Done | Dormant-thread detection with topic filter |
| 5 — `mine_patterns` tool | ✅ Done | CBR cluster detection (domain + shared keywords) |
| 6 — `consolidate_memory` tool | ✅ Done | Data-gathering; synthesis happens in the agent's react loop (simpler than nested XStructor) |
| 7 — `restore_confidence` tool | ✅ Done | Writes new fact via `facts_log.append` (append-only supersede) |
| 8 — `find_connections` tool | ✅ Done | Cross-store reference via `rquery.cross_reference` |
| 9 — Scheduled consolidation | ⚠️ Manual setup | No `schedule.toml` auto-loader exists. Operator asks scheduler agent to create a weekly recurring job delegating to the Remembrancer. See "Follow-up work". |
| 10 — Sensorium integration | ✅ Done (partial) | `<memory last_consolidation="…" consolidation_age="…"/>` rendered in `curator.gleam`. Admin GUI panel deferred. |
| 11 — Skills management integration | ❌ Blocked | Depends on the skills-management roadmap (spec-only). `mine_patterns` surfaces clusters in the report; no auto-proposal. |

## What shipped

- **Agent:** `agents/remembrancer.gleam`, registered via `remembrancer_specs` in `springdrift.gleam`, gated on `remembrancer_enabled` config (default false; enabled for Curragh).
- **Tools (8):** `src/tools/remembrancer.gleam` — `deep_search`, `fact_archaeology`, `mine_patterns`, `resurrect_thread`, `consolidate_memory`, `restore_confidence`, `find_connections`, `write_consolidation_report`.
- **Deep readers:** `src/remembrancer/reader.gleam` (delegates to existing `narrative_log.load_entries`, `cbr_log.load_all`, `facts_log.load_all`) and `src/remembrancer/query.gleam` (pure filter/aggregate: search, trace, cluster, dormant, xref).
- **Persistence:** `src/remembrancer/consolidation.gleam` — `ConsolidationRun` JSONL log at `.springdrift/memory/consolidation/` + markdown reports at `.springdrift/knowledge/consolidation/`.
- **Config (7 fields):** `remembrancer_enabled`, `remembrancer_model`, `remembrancer_max_turns`, `remembrancer_consolidation_schedule`, `remembrancer_review_confidence_threshold`, `remembrancer_dormant_thread_days`, `remembrancer_min_pattern_cases`.
- **Sensorium:** `<memory>` tag in `build_sensorium` when any consolidation run has occurred.
- **Tests:** 16 new unit tests at `test/remembrancer/` (1536 total, all pass).
- **Docs:** CLAUDE.md (agent table, tools table, config field table, memory store table), HOW_TO.md (dev + example).

## Follow-up work (deferred)

See also: `docs/roadmap/planned/remembrancer-followups.md`.

- **Phase 11 — Skills-proposal pipeline.** SHIPPED 2026-04-18 with `skills-management`. `propose_skills_from_patterns` in `tools/remembrancer.gleam` mines clusters via `src/skills/pattern.gleam`, generates bodies via `src/skills/body_gen.gleam`, and gates via `src/skills/safety_gate.gleam` (deterministic + rate limit + same-scope cooldown + LLM conflict classifier + D' scorer). Accepted proposals become Active skills on disk.
- **Phase 9 — TOML-driven scheduled consolidation.** Either build a `schedule.toml` auto-loader or keep the runtime-created approach. Currently runtime-only.
- **Phase 10 — Web GUI Memory Health panel.** Sensorium tag shipped; admin-page tab (memory-depth stats, consolidation history, "Run Consolidation" button) deferred.
- **Advanced sensorium metrics.** `decayed_facts`, `dormant_threads` counts — skipped because computing them every cycle would require scanning the full archive. Could be cached in the Librarian later.

---

## Table of Contents

- [Overview](#overview)
- [The Name](#the-name)
- [Why a Dedicated Agent](#why-a-dedicated-agent)
- [Architecture](#architecture)
- [Tools](#tools)
  - [Deep Narrative Search](#deep-narrative-search)
  - [Fact Archaeology](#fact-archaeology)
  - [Pattern Mining](#pattern-mining)
  - [Thread Resurrection](#thread-resurrection)
  - [Memory Consolidation](#memory-consolidation)
  - [Decay Override](#decay-override)
  - [Knowledge Graph](#knowledge-graph)
- [Agent Specification](#agent-specification)
- [When the Remembrancer Runs](#when-the-remembrancer-runs)
  - [On Demand](#on-demand)
  - [Scheduled Consolidation](#scheduled-consolidation)
  - [Triggered by the Cognitive Loop](#triggered-by-the-cognitive-loop)
  - [Triggered by the Forecaster](#triggered-by-the-forecaster)
- [Relationship to Other Memory Actors](#relationship-to-other-memory-actors)
- [D' Integration](#d-integration)
- [Sensorium Integration](#sensorium-integration)
- [Web GUI](#web-gui)
- [Persistence](#persistence)
- [Configuration](#configuration)
- [Implementation Order](#implementation-order)
- [What This Enables](#what-this-enables)

---

## Overview

The Remembrancer is a specialist agent dedicated to making old knowledge useful again. It works across the full depth of the agent's memory — months and years, not just today and yesterday — finding forgotten patterns, resurrecting dormant threads, synthesising historical cases into higher-level knowledge, and surfacing relevant ancient history when the current work connects to it.

The existing memory actors each serve a specific function: the Librarian indexes and queries, the Archivist records each cycle, the Housekeeper prunes and deduplicates. None of them asks: "what do we know from six months ago that matters right now?"

The Remembrancer does.

---

## The Name

The Remembrancer is a real historical office. The City of London has maintained a Remembrancer since 1571 — an official whose role is to maintain the institutional memory of the Corporation, brief officials on historical precedent, and ensure that past decisions inform present ones. The title predates modern record-keeping; the Remembrancer was the person who literally remembered what the institution had done and why.

The role exists because institutions forget. People leave, documents get filed, context evaporates. The Remembrancer's job is to make sure that when a question arises that the institution has answered before, that answer is found — not by searching an archive, but by an agent who knows the archive, understands the context, and can judge what's relevant.

That's precisely what this agent does for Springdrift.

---

## Why a Dedicated Agent

The Observer agent has diagnostic tools but looks at recent activity — cycles, tool usage, current system state. It answers "what happened today?" and "what's broken?"

The Remembrancer answers different questions:

- "Have we seen this kind of problem before?" — across months of CBR cases
- "What did we used to know about this topic?" — facts that have decayed below useful confidence
- "Is there an old thread that connects to what we're working on now?" — dormant threads from weeks ago
- "What patterns have emerged over time that we haven't codified?" — implicit knowledge buried in hundreds of narrative entries
- "What have we forgotten that we shouldn't have?" — important knowledge lost to decay or pruning

These questions require deep traversal of the memory stores, cross-referencing across time periods, and synthesis that's more than search — it's historical reasoning.

---

## Architecture

```
agents/remembrancer.gleam           — Agent spec: tools, system prompt, max_turns
tools/remembrancer.gleam            — Specialist tools for deep memory operations
remembrancer/reader.gleam           — Direct JSONL file reader (bypasses ETS entirely)
remembrancer/query.gleam            — File-based query engine: grep, filter, aggregate
remembrancer/consolidation.gleam    — Synthesis types and persistence
```

### Why Not ETS

The Librarian's ETS tables hold a configurable window of recent data (default 30 days). Everything older is only on disk as JSONL files. The Remembrancer's entire purpose is working with old data — data that isn't in ETS and never will be.

The Remembrancer does NOT use the Librarian for data access. It reads the raw JSONL files directly from disk using its own file-based reader. This is a deliberate architectural choice:

- **ETS is for fast, recent queries.** The Librarian optimises for "what happened today?" with O(1) lookups.
- **Disk is for deep, historical queries.** The Remembrancer optimises for "what happened three months ago?" with sequential file scans.
- **No ETS bloat.** Loading months of history into ETS would consume unbounded memory. The Remembrancer reads files, processes them, and releases the memory.
- **No Librarian dependency.** The Remembrancer works even if the Librarian's ETS window is set to 1 day. The raw files are always there.

### File-Based Query Engine

The `remembrancer/reader.gleam` module provides direct JSONL access:

```gleam
/// Read all narrative entries from JSONL files in a date range.
/// Reads directly from disk — no ETS, no Librarian.
pub fn read_narrative_entries(
  narrative_dir: String,
  from_date: String,
  to_date: String,
) -> List(NarrativeEntry)

/// Read all CBR cases from the cases.jsonl file.
/// Scans the full file — no index, no ETS.
pub fn read_all_cases(cbr_dir: String) -> List(CbrCase)

/// Read all facts from JSONL files in a date range.
pub fn read_facts(
  facts_dir: String,
  from_date: String,
  to_date: String,
) -> List(MemoryFact)

/// Read cycle log entries for a date range.
pub fn read_cycle_log(
  cycle_log_dir: String,
  from_date: String,
  to_date: String,
) -> List(CycleLogEntry)

/// Read meta observer history.
pub fn read_meta_history(
  meta_dir: String,
  from_date: String,
  to_date: String,
) -> List(MetaObservation)
```

The `remembrancer/query.gleam` module provides filtering and aggregation over the raw data:

```gleam
/// Filter entries by keyword across summaries and keywords fields.
pub fn search_entries(
  entries: List(NarrativeEntry),
  query: String,
) -> List(NarrativeEntry)

/// Filter cases by domain, category, utility threshold.
pub fn filter_cases(
  cases: List(CbrCase),
  domain: Option(String),
  category: Option(CbrCategory),
  min_utility: Option(Float),
) -> List(CbrCase)

/// Find all versions of a fact key across all files.
pub fn trace_fact_key(
  facts_dir: String,
  key: String,
) -> List(MemoryFact)

/// Find clusters of similar cases by keyword overlap.
pub fn cluster_cases(
  cases: List(CbrCase),
  min_overlap: Float,
  min_cluster_size: Int,
) -> List(CaseCluster)

/// Find threads with no activity since a given date.
pub fn find_dormant_threads(
  entries: List(NarrativeEntry),
  dormant_since: String,
) -> List(ThreadSummary)

/// Cross-reference a topic across all memory stores.
pub fn cross_reference(
  topic: String,
  entries: List(NarrativeEntry),
  cases: List(CbrCase),
  facts: List(MemoryFact),
) -> CrossReference
```

This is essentially an in-process version of what SD Audit does in Python — but running inside the agent so the Remembrancer can reason about the results.

### Performance

Sequential JSONL scanning is slower than ETS lookup but fast enough for batch operations:
- 1000 narrative entries (~1MB JSONL): <100ms to read and parse
- 10,000 CBR cases (~5MB JSONL): <500ms
- Acceptable for a scheduled weekly consolidation or on-demand deep search
- NOT acceptable for per-cycle queries — that's why the Librarian exists for recent data

The Remembrancer is a batch agent, not a real-time query service. It runs infrequently, reads a lot, thinks deeply, and writes consolidated knowledge back to the stores.

---

## Tools

### Deep Narrative Search

```gleam
pub fn deep_search_tool() -> Tool {
  tool.new("deep_search")
  |> tool.with_description(
    "Search narrative memory across months or years. Unlike recall_search "
    <> "(which covers recent entries), deep_search traverses the full archive. "
    <> "Use for historical precedent, long-term patterns, and forgotten knowledge."
  )
  |> tool.add_string_param("query", "Search terms", True)
  |> tool.add_string_param("from_date", "Start date YYYY-MM-DD (default: 90 days ago)", False)
  |> tool.add_string_param("to_date", "End date YYYY-MM-DD (default: today)", False)
  |> tool.add_integer_param("max_results", "Maximum entries to return (default: 20)", False)
  |> tool.build()
}
```

Searches across the full narrative JSONL archive, not just the Librarian's ETS window. Reads directly from disk for entries older than `librarian_max_days`.

### Fact Archaeology

```gleam
pub fn fact_archaeology_tool() -> Tool {
  tool.new("fact_archaeology")
  |> tool.with_description(
    "Trace the complete history of a fact key across all time — every write, "
    <> "supersession, deletion, and conflict. Shows the full story of what the "
    <> "agent believed about a topic and how that belief changed over time. "
    <> "Also finds related facts by key similarity."
  )
  |> tool.add_string_param("key", "Fact key to trace (or partial key for fuzzy match)", True)
  |> tool.add_bool_param("include_related", "Also find facts with similar keys (default: true)", False)
  |> tool.build()
}
```

Goes beyond `memory_trace_fact` (which traces a single key) — finds related keys, shows the full timeline of belief change, highlights contradictions and supersessions across months.

### Pattern Mining

```gleam
pub fn mine_patterns_tool() -> Tool {
  tool.new("mine_patterns")
  |> tool.with_description(
    "Scan CBR cases for patterns that haven't been codified as skills. "
    <> "Finds clusters of similar successful approaches, recurring pitfalls, "
    <> "and domain-specific heuristics buried in case history. "
    <> "Returns proposed patterns with supporting case IDs."
  )
  |> tool.add_string_param("domain", "Domain to mine (or 'all')", False)
  |> tool.add_string_param("category", "CBR category to focus on (Strategy, Pitfall, etc.)", False)
  |> tool.add_integer_param("min_cases", "Minimum cases to form a pattern (default: 3)", False)
  |> tool.build()
}
```

The engine for the skills learning loop (from the skills management spec). The Remembrancer runs pattern mining; the results feed into skill proposals.

### Thread Resurrection

```gleam
pub fn resurrect_thread_tool() -> Tool {
  tool.new("resurrect_thread")
  |> tool.with_description(
    "Find dormant research threads that connect to a current topic. "
    <> "A dormant thread is one with no activity for >7 days but with "
    <> "unresolved questions or incomplete investigations. "
    <> "Returns thread summaries with relevance scores."
  )
  |> tool.add_string_param("topic", "Current topic to find connections for", True)
  |> tool.add_integer_param("dormant_days", "Minimum days of inactivity (default: 7)", False)
  |> tool.build()
}
```

Threads that went quiet might be relevant again. The Remembrancer finds them by keyword and domain overlap with the current work.

### Memory Consolidation

```gleam
pub fn consolidate_tool() -> Tool {
  tool.new("consolidate_memory")
  |> tool.with_description(
    "Synthesise a period of narrative entries into higher-level knowledge. "
    <> "Reads N entries from a date range and produces: a summary of what was "
    <> "learned, key facts worth preserving, patterns worth codifying, and "
    <> "connections between threads that weren't obvious at the time."
  )
  |> tool.add_string_param("from_date", "Start date YYYY-MM-DD", True)
  |> tool.add_string_param("to_date", "End date YYYY-MM-DD", True)
  |> tool.add_string_param("focus", "Optional focus domain or topic", False)
  |> tool.build()
}
```

This is Schank's memory consolidation and the System M paper's "sleep-like consolidation phase" — replaying episodic memories to extract generalizable patterns. The output can be:
- New persistent facts (high-level knowledge)
- Skill proposals (from consolidated patterns)
- Thread summaries (connecting previously separate investigations)
- CBR case upgrades (increasing confidence on validated patterns)

### Decay Override

```gleam
pub fn restore_confidence_tool() -> Tool {
  tool.new("restore_confidence")
  |> tool.with_description(
    "Restore confidence on a decayed fact or CBR case that the Remembrancer "
    <> "has verified is still accurate. Decay reduces confidence over time, "
    <> "but if the underlying information is re-verified (by checking sources "
    <> "or confirming with current data), confidence can be restored."
  )
  |> tool.add_string_param("type", "fact | case", True)
  |> tool.add_string_param("id", "Fact key or case ID", True)
  |> tool.add_number_param("new_confidence", "Restored confidence (0.0-1.0)", True)
  |> tool.add_string_param("reason", "Why confidence was restored", True)
  |> tool.build()
}
```

Confidence decay is right — old information should be trusted less by default. But the Remembrancer can re-verify old facts and restore their confidence. This creates a verification cycle: decay → Remembrancer review → re-verification → confidence restored (or fact deprecated if wrong).

### Knowledge Graph

```gleam
pub fn find_connections_tool() -> Tool {
  tool.new("find_connections")
  |> tool.with_description(
    "Find connections between entities, domains, and topics across all memory stores. "
    <> "Cross-references narrative entries, CBR cases, facts, and threads to build "
    <> "a connection map around a topic. Shows how different pieces of knowledge relate."
  )
  |> tool.add_string_param("topic", "Central topic to map connections from", True)
  |> tool.add_integer_param("depth", "How many hops to follow (default: 2)", False)
  |> tool.build()
}
```

Not a persistent knowledge graph — a query-time graph constructed from existing memory stores. "Show me everything we know that connects to this topic" — across narrative entries, CBR cases, facts, threads, and endeavours.

---

## Agent Specification

```gleam
pub fn spec(librarian: Option(Subject(LibrarianMessage))) -> AgentSpec {
  AgentSpec(
    name: "remembrancer",
    system_prompt: remembrancer_system_prompt(),
    tools: remembrancer_tools(librarian),
    max_turns: 8,
    max_context_messages: Some(30),
    max_consecutive_errors: 3,
    restart_strategy: Transient,    // Not essential — restart on crash, but don't force-restart on clean exit
    redact_secrets: True,
  )
}
```

System prompt emphasises:
- You are the institutional memory of this agent
- Your job is to find what has been forgotten, connect what has been separated, and surface what is relevant
- You work across the full depth of memory, not just recent activity
- When you find something relevant, explain WHY it matters to the current context, not just THAT it exists
- Qualify confidence: decayed facts are less certain, old cases may reflect outdated approaches

---

## When the Remembrancer Runs

### On Demand

The cognitive loop delegates to the Remembrancer when the operator or agent asks questions about historical knowledge:

```
"Have we researched this topic before?"
"What do we know about insurance underwriting from our earlier work?"
"Are there any old threads that connect to the current project?"
```

### Scheduled Consolidation

A weekly scheduled job triggers the Remembrancer to consolidate the past week's narrative:

```toml
[[task]]
name = "weekly-consolidation"
kind = "recurring"
interval_ms = 604800000    # Weekly
query = "Run memory consolidation for the past week. Identify patterns, synthesise knowledge, propose skills, and restore confidence on verified facts."
```

This is the "sleep-like consolidation" from the System M paper — offline processing that replays episodic memory to extract generalizable knowledge.

### Triggered by the Cognitive Loop

When the CBR retrieval returns no matches (`session_cbr_hits` stays at 0 for several cycles — high uncertainty), the cognitive loop can delegate to the Remembrancer:

"I'm not finding relevant cases for this topic. Check the deep archive — have we encountered anything similar in older memory?"

### Triggered by the Forecaster

When an Endeavour's health degrades, the Forecaster can suggest consulting the Remembrancer:

"Task health declining. The Remembrancer may find relevant historical patterns from similar past endeavours."

---

## Relationship to Other Memory Actors

| Actor | Time Horizon | Data Access | Remembrancer Relationship |
|---|---|---|---|
| **Librarian** | Recent (configurable days) | ETS in-memory index | Remembrancer does NOT use the Librarian. It reads raw JSONL directly from disk. |
| **Archivist** | Per cycle | Writes JSONL | Remembrancer reads what the Archivist wrote, across the full archive |
| **Housekeeper** | Periodic | ETS + JSONL | Remembrancer may rescue knowledge before Housekeeper prunes it |
| **Curator** | Per cycle | Queries Librarian | Remembrancer's consolidated findings are written as facts/cases, which the Curator picks up via the Librarian |
| **Observer** | Recent | Queries Librarian | Observer diagnoses current state; Remembrancer diagnoses historical patterns |
| **SD Audit** | Any (offline) | Reads JSONL (Python) | Same data access pattern as the Remembrancer, but external and offline. The Remembrancer is SD Audit running inside the agent. |

The Remembrancer is architecturally distinct from the other memory actors: it bypasses ETS entirely and works directly with the immutable log files. This is the same access pattern as SD Audit (the Python tool), but running inside the agent so it can reason about what it finds and write consolidated knowledge back to the stores.

---

## How Knowledge Surfaces

The Remembrancer finds things. The question is: where do the findings go so they're actually useful?

### Five Output Channels

| Output | Where It Goes | Who Sees It | When |
|---|---|---|---|
| **Consolidated facts** | `memory/facts/` via `memory_write` | Agent (via Curator's fact slot), operator (via admin) | Persistent — available every cycle |
| **Upgraded CBR cases** | `memory/cbr/cases.jsonl` via Librarian | Agent (via `recall_cases`), operator (via admin) | Retrieved when relevant to a query |
| **Skill proposals** | `memory/skills/` JSONL | Operator (via Skills admin tab, approval required) | On pattern detection |
| **Consolidation reports** | `knowledge/consolidation/` as markdown documents | Operator (via Documents panel in web GUI) | Weekly or on demand |
| **Sensory events** | Sensorium `<events>` section | Agent (passive perception, no tool call needed) | Next cycle after Remembrancer runs |

### Consolidation Reports as Documents

The most visible output. When the Remembrancer runs a consolidation, it produces a markdown report:

```
.springdrift/knowledge/consolidation/
├── 2026-03-23-weekly.md
├── 2026-03-16-weekly.md
└── 2026-03-25-dprime-patterns.md
```

Example report:

```markdown
# Weekly Consolidation — 2026-03-17 to 2026-03-23

## Key Findings

### D' Safety System Stabilised
Over 89 cycles this week, the D' output gate evolved from blocking
"good morning" (false positive rate ~40%) to making substantive quality
judgments. The deterministic pre-filter now catches 38% of adversarial
inputs before any LLM call.

Confidence: 0.85 (based on 89 evaluated cycles with consistent behaviour
after threshold adjustments on March 22).

### CBR Retrieval Quality Improving
Utility scores show upward trend: mean 0.54 (week 1) → 0.61 (week 2).
5 cases have utility > 0.80 — all are Strategy or Pitfall category.
12 cases have never been retrieved — candidates for review or pruning.

### Three-Paper Integration Complete but Unverified
The task system shows 15/16 steps complete, but step 16 (validation) is
pending. 6 CBR cases were generated from this work, all DomainKnowledge
category. Recommend re-verification before citing in external reports.

## Facts Restored
- "dprime_reject_threshold" confidence restored from 0.31 → 0.85
  (verified by direct observation of gate behaviour)

## Patterns Detected
- **Proposed skill**: "Search tool selection" — 5 cases show brave_answer
  outperforms web_search for factual queries (awaiting operator approval)

## Dormant Threads Worth Revisiting
- "Vertex AI Integration" — dormant 3 days, blocked on GCP quota.
  May be relevant if quota arrives.
```

These reports appear in the Documents panel of the web GUI (from the web-gui-v2 spec). The operator can read them, share them, or ask the agent to act on specific findings.

### The Flow

```
Remembrancer reads raw JSONL files
  → Synthesises findings
  → Writes consolidated facts (high-confidence, persistent scope)
  → Writes/upgrades CBR cases (with provenance: source_agent="remembrancer")
  → Proposes skills (via skills management pipeline)
  → Writes consolidation report (markdown in knowledge/consolidation/)
  → Emits sensory events for urgent findings
  → Operator sees report in Documents panel
  → Agent sees new facts and cases via normal retrieval next cycle
```

The key insight: the Remembrancer writes to the SAME stores that all other agents read from. It doesn't have its own special output channel. It writes facts (which the Curator picks up), cases (which `recall_cases` retrieves), and reports (which the operator reads). The existing infrastructure distributes the knowledge — the Remembrancer just produces it.

---

## D' Integration

The Remembrancer's tools are internal memory operations — they read from the agent's own stores. These are D' exempt (same as other memory tools via `is_dprime_exempt`).

However, when the Remembrancer produces synthesis (consolidation summaries, pattern proposals, restored confidence), that output passes through the cognitive loop's normal flow and is subject to the output gate if delivered to the user.

---

## Sensorium Integration

The Remembrancer's activity appears in the sensorium:

```xml
<memory consolidation_age="3d" decayed_facts="23" dormant_threads="7"
        last_consolidation="2026-03-23T09:00:00Z"/>
```

The agent sees at a glance how stale its deep memory is and whether consolidation is overdue.

---

## Web GUI

### Memory Health Panel (admin)

A dedicated view showing:

```
Memory Depth
=============

Narrative:  439 entries across 15 days (oldest: 2026-03-11)
CBR Cases:  134 total, 23 decayed below 0.3 confidence
Facts:      267 active, 89 older than 30 days (avg decayed confidence: 0.44)
Threads:    152 total, 7 dormant >7 days with unresolved questions

Last Consolidation: 3 days ago
Pending Patterns:   2 (awaiting skill proposal review)
Confidence Restorations: 5 this month

[Run Consolidation] [Mine Patterns] [Find Dormant Threads]
```

### Timeline View

Visual timeline showing memory density and activity over weeks/months. Highlights gaps (periods with no narrative entries) and consolidation events.

---

## Persistence

Consolidation results stored in append-only JSONL:
```
.springdrift/memory/consolidation/YYYY-MM-DD-consolidation.jsonl
```

Operations: `ConsolidationRun`, `PatternDetected`, `SkillProposed`, `ConfidenceRestored`, `ThreadResurrected`, `ConnectionFound`.

The consolidation log is itself part of the memory — the Remembrancer can review past consolidations to track how the agent's knowledge has evolved over time.

---

## Configuration

```toml
[remembrancer]
# Enable the Remembrancer agent (default: false)
# enabled = false

# Model for consolidation (default: reasoning_model — needs the powerful model for synthesis)
# model = ""

# Max turns per Remembrancer invocation (default: 8)
# max_turns = 8

# Schedule consolidation (default: weekly)
# consolidation_schedule = "weekly"

# Minimum decayed confidence before a fact is flagged for review (default: 0.3)
# review_confidence_threshold = 0.3

# Minimum dormant days before a thread is considered for resurrection (default: 7)
# dormant_thread_days = 7

# Minimum CBR cases to form a pattern (default: 3)
# min_pattern_cases = 3
```

---

## Implementation Order

| Phase | What | Effort |
|---|---|---|
| 1 | Agent spec + system prompt | Small |
| 2 | deep_search tool (direct JSONL reading beyond Librarian window) | Medium |
| 3 | fact_archaeology tool (full key timeline + related keys) | Medium |
| 4 | resurrect_thread tool (dormant thread detection + relevance scoring) | Medium |
| 5 | mine_patterns tool (CBR cluster detection) | Medium |
| 6 | consolidate_memory tool (synthesis via LLM) | Large — the core capability |
| 7 | restore_confidence tool | Small |
| 8 | find_connections tool (cross-store graph query) | Medium |
| 9 | Scheduled consolidation (weekly job) | Small |
| 10 | Sensorium + web GUI integration | Medium |
| 11 | Integration with skills management (pattern → skill proposal) | Medium (depends on skills management) |

Phase 1-4 delivers the search and discovery capabilities. Phase 5-6 delivers the synthesis capability. Phase 7-11 adds the feedback loops and visibility.

---

## What This Enables

An agent that doesn't just accumulate memory — it cultivates it. Old knowledge is reviewed, verified, consolidated, and connected to current work. Patterns that emerge over months are codified into skills. Dormant threads are resurrected when they become relevant again. Facts that have decayed are either re-verified or deprecated — not left in limbo.

The Remembrancer is the difference between an agent with a filing cabinet and an agent with institutional wisdom. The filing cabinet holds documents. The Remembrancer knows what's in them, why they matter, and when to bring them up.

That's what law firms lose when partners retire. That's what insurance companies lose when underwriters leave. That's what the Remembrancer preserves.
