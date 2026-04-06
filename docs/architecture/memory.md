# Memory Architecture

Springdrift maintains nine persistent memory stores, all backed by append-only JSON-L
files on disk, with ETS-based in-memory indexes managed by the Librarian actor.

## 1. Overview

| Store | Location | Record type | Purpose |
|---|---|---|---|
| Narrative | `.springdrift/memory/narrative/YYYY-MM-DD.jsonl` | `NarrativeEntry` | Per-cycle record of what happened: summary, intent, outcome, delegation chain |
| Threads | Derived from narrative entries | `Thread` / `ThreadState` | Ongoing lines of investigation grouping related entries |
| Facts | `.springdrift/memory/facts/YYYY-MM-DD-facts.jsonl` | `MemoryFact` | Key-value working memory with scope and confidence |
| CBR | `.springdrift/memory/cbr/cases.jsonl` | `CbrCase` | Problem-solution-outcome patterns for case-based reasoning |
| Artifacts | `.springdrift/memory/artifacts/artifacts-YYYY-MM-DD.jsonl` | `ArtifactRecord` | Large content stored on disk (web pages, extractions) |
| Tasks | `.springdrift/memory/planner/YYYY-MM-DD-tasks.jsonl` | `PlannerTask` | Planned work with steps, dependencies, risks |
| Endeavours | `.springdrift/memory/planner/YYYY-MM-DD-endeavours.jsonl` | `Endeavour` | Self-directed initiatives grouping multiple tasks |
| DAG | In-memory ETS, populated from cycle log | `CycleNode` | Operational telemetry: tokens, tool calls, D' gates, agent output |
| Comms | `.springdrift/memory/comms/YYYY-MM-DD-comms.jsonl` | `CommsMessage` | Sent and received email messages with delivery status |

All stores share three properties:

- **Append-only JSONL** -- no record is ever mutated on disk. Updates are new entries
  that supersede prior values. This makes backup trivial (copy one directory) and
  corruption recovery possible (truncate the last incomplete line).
- **Daily rotation** -- most stores use `YYYY-MM-DD` prefixed files, creating natural
  time partitions.
- **ETS indexing** -- the Librarian replays JSONL at startup (configurable via
  `librarian_max_days`, default 30) and maintains fast in-memory indexes.

## 2. Librarian

`src/narrative/librarian.gleam`

The Librarian is a supervised OTP actor that owns all ETS tables for memory queries.
It is the single owner of memory indexes -- no other process reads or writes ETS
directly. All memory tools (`recall_recent`, `recall_search`, `memory_read`, etc.)
send messages to the Librarian when available, falling back to direct JSONL reads
when the Librarian subject is `None`.

### ETS tables

**Narrative:**

| Table | Type | Key | Value |
|---|---|---|---|
| `entries` | set | `cycle_id` | `NarrativeEntry` |
| `by_thread` | bag | `thread_id` | `NarrativeEntry` |
| `by_date` | bag | `"YYYY-MM-DD"` | `NarrativeEntry` |
| `by_keyword` | bag | keyword (lowercased) | `NarrativeEntry` |
| `by_recency` | ordered | timestamp | `NarrativeEntry` |

**CBR:**

| Table | Type | Key | Value |
|---|---|---|---|
| `cbr_cases` | set | `case_id` | `CbrCase` |

Plus an in-memory `CaseBase` (inverted index + optional embeddings) for retrieval.

**Facts:**

| Table | Type | Key | Value |
|---|---|---|---|
| `facts_by_key` | set | key | `MemoryFact` (current value) |
| `facts_by_cycle` | bag | `cycle_id` | `MemoryFact` |

**Artifacts:**

| Table | Type | Key | Value |
|---|---|---|---|
| `artifacts` | set | `artifact_id` | `ArtifactMeta` |
| `artifacts_by_cycle` | bag | `cycle_id` | `ArtifactMeta` |

### Message-based API

All queries go through typed messages on `Subject(LibrarianMessage)`. Key message
types include:

- `QueryDayRoots`, `QueryDayStats` -- narrative queries by date
- `QueryNodeWithDescendants` -- DAG tree traversal
- `QueryThreadCount`, `QueryPersistentFactCount`, `QueryCaseCount` -- count queries
  used by the Curator for sensorium population
- `IndexArtifact`, `QueryArtifactsByCycle`, `QueryArtifactById`,
  `RetrieveArtifactContent` -- artifact operations
- `QuerySchedulerCycles` -- scheduler-triggered cycle history

At startup, the Librarian replays JSONL files from disk into ETS. The replay window
is bounded by `librarian_max_days` (default 30 days). Legacy `facts.jsonl` files are
auto-migrated to the daily-rotated format.

## 3. Narrative log

`src/narrative/types.gleam`, `src/narrative/log.gleam`

The narrative log is the primary record of what the agent did and why. Each cognitive
cycle produces one `NarrativeEntry`:

```
NarrativeEntry(
  schema_version: Int,
  cycle_id: String,
  parent_cycle_id: Option(String),
  timestamp: String,
  entry_type: EntryType,           // Narrative | Conversation
  summary: String,
  intent: Intent,                  // goal + category
  outcome: Outcome,                // Success | Failure + assessment
  delegation_chain: List(DelegationStep),
  decisions: List(Decision),
  keywords: List(String),
  topics: List(String),
  entities: Entities,              // people, locations, organisations, domains, tools
  sources: List(Source),
  thread: Option(Thread),
  metrics: Metrics,                // input_tokens, output_tokens, tool_calls, model
  observations: List(Observation),
)
```

Entries are written to daily-rotated files at
`.springdrift/memory/narrative/YYYY-MM-DD.jsonl`. The `narrative/log.gleam` module
provides `append_entry` (write) and `read_entries_for_date` / `read_entries_for_range`
(read). Full JSON encode/decode roundtrips are supported.

`parent_cycle_id` links sub-agent cycles to their parent, forming a DAG. The
`narrative/cycle_tree.gleam` module builds hierarchical `CycleNode` trees from these
links.

## 4. Archivist

`src/narrative/archivist.gleam`

The Archivist generates narrative entries and CBR cases after each cognitive cycle.
It runs as a fire-and-forget `spawn_unlinked` process -- failures never affect the
user.

### Two-phase pipeline

**Phase 1 (Reflection):** A plain-text LLM call focused on honest assessment of what
worked and what failed. No structured output constraints. The prompt asks the LLM to
reflect on the cycle's input, response, agent delegations, and tool usage.

**Phase 2 (Curation):** Takes the Phase 1 reflection as context and generates
structured `NarrativeEntry` + `CbrCase` via XStructor (XML + XSD validation). The
reflection grounds the structured output in honest assessment rather than
post-hoc rationalisation.

### Fallback chain

1. If Phase 1 fails: fall back to single-call XStructor generation (no reflection
   context).
2. If Phase 2 fails but Phase 1 succeeded: the reflection text is preserved in logs
   (insights not lost).
3. If both fail: cycle completes normally with no narrative entry.

### ArchivistContext

The cognitive loop constructs an `ArchivistContext` carrying everything the Archivist
needs:

```
ArchivistContext(
  cycle_id: String,
  parent_cycle_id: Option(String),
  user_input: String,
  final_response: String,
  agent_completions: List(AgentCompletionRecord),
  model_used: String,
  classification: String,
  total_input_tokens: Int,
  total_output_tokens: Int,
  tool_calls: Int,
  dprime_decisions: List(String),
  thread_index_json: String,
  retrieved_case_ids: List(String),
)
```

After generating the entry, the Archivist:
- Assigns a thread via `threading.assign_thread`
- Appends the entry to JSONL via `narrative/log.append_entry`
- Notifies the Librarian to update ETS indexes
- Updates CBR usage stats for any cases retrieved during the cycle
- Pushes `UpdateConstitution` to the Curator

## 5. CBR (Case-Based Reasoning)

`src/cbr/types.gleam`, `src/cbr/log.gleam`, `src/cbr/bridge.gleam`

CBR captures reusable problem-solution-outcome patterns. Cases are derived from
narrative entries by the Archivist.

### CbrCase structure

```
CbrCase(
  case_id: String,
  timestamp: String,
  schema_version: Int,
  problem: CbrProblem,             // user_input, intent, domain, entities, keywords, query_complexity
  solution: CbrSolution,           // approach, agents_used, tools_used, steps
  outcome: CbrOutcome,             // status, confidence, assessment, pitfalls
  source_narrative_id: String,
  profile: Option(String),
  redacted: Bool,
  category: Option(CbrCategory),   // Strategy | CodePattern | Troubleshooting | Pitfall | DomainKnowledge
  usage_stats: Option(CbrUsageStats),
)
```

### Retrieval

`cbr/bridge.gleam` provides `CaseBase`, which maintains an inverted index and optional
Ollama embeddings. Retrieval fuses six weighted signals:

| Signal | Source | Default weight |
|---|---|---|
| Weighted field score | Intent/domain match, keyword/entity Jaccard | Configurable |
| Inverted index overlap | Token overlap from inverted index | Configurable |
| Recency | More recent cases score higher | Configurable |
| Domain match | Exact domain string match | Configurable |
| Embedding cosine similarity | Ollama `nomic-embed-text` vectors | Configurable |
| Utility score | Laplace-smoothed usage tracking | Configurable |

Weights are configurable via `RetrievalWeights` in the `[cbr]` config section.
When embeddings are unavailable, embedding weight is redistributed proportionally
to the other signals. Default retrieval cap is K=4 cases.

### Categories

Cases are typed by `CbrCategory`, assigned deterministically by the Archivist based
on outcome:

- `Strategy` -- high-level approach that worked
- `CodePattern` -- reusable code snippet or template
- `Troubleshooting` -- how to diagnose/fix a specific problem
- `Pitfall` -- what NOT to do (learned from failure)
- `DomainKnowledge` -- factual knowledge about a domain

The Curator organises injected cases by category in the system prompt.

### Self-improvement via usage stats

Cases track their own utility via `CbrUsageStats`:

```
CbrUsageStats(
  retrieval_count: Int,
  retrieval_success_count: Int,
  helpful_count: Int,
  harmful_count: Int,
)
```

When `recall_cases` returns cases, their IDs are recorded on `CognitiveState`. The
Archivist updates usage stats post-cycle based on outcome success/failure. The
utility score uses Laplace smoothing: `(successes + 1) / (retrievals + 2)`. With no
data, this returns 0.5 (neutral prior).

## 6. Facts

`src/facts/types.gleam`, `src/facts/log.gleam`

Facts are discrete key-value assertions with scope and confidence. Every write is
permanent -- supersessions are recorded as new entries, not mutations.

```
MemoryFact(
  schema_version: Int,
  fact_id: String,
  timestamp: String,
  cycle_id: String,
  agent_id: Option(String),
  key: String,
  value: String,
  scope: FactScope,                // Session | Persistent | Global
  operation: FactOp,               // Write | Delete | Superseded
  supersedes: Option(String),
  confidence: Float,
  source: String,
  provenance: Option(FactProvenance),
)
```

### Scopes

- **Session** -- cleared when the session ends
- **Persistent** -- survives across sessions
- **Global** -- shared across profiles

### Confidence decay

Fact confidence decays at read time using a half-life formula:

```
confidence_t = confidence_0 * 2^(-age_days / half_life_days)
```

The default half-life is 30 days (`dprime/decay.gleam`). Stored confidence is never
mutated -- decay is applied at query time only. This means the same fact will appear
less confident over time unless refreshed by a new write.

### Provenance

Optional `FactProvenance` tracks where a fact came from:

- `source_cycle_id` -- which cycle wrote it
- `source_tool` -- which tool produced it
- `source_agent` -- which agent wrote it
- `derivation` -- `DirectObservation | Synthesis | OperatorProvided | Unknown`

## 7. Artifacts

`src/artifacts/types.gleam`, `src/artifacts/log.gleam`, `src/tools/artifacts.gleam`

Artifacts store large content (web pages, extractions) on disk with compact IDs.
This keeps the agent's context window lean -- the researcher agent stores full page
content via `store_result` and retrieves it on demand via `retrieve_result`.

```
ArtifactRecord(
  schema_version: Int,
  artifact_id: String,
  cycle_id: String,
  stored_at: String,
  tool: String,
  url: String,
  summary: String,
  char_count: Int,
  truncated: Bool,
)
```

Content over 50KB is truncated (with `truncated: True` flag). `ArtifactMeta` is the
metadata-only projection indexed in ETS -- it omits the content field.

Daily-rotated JSONL files: `artifacts-YYYY-MM-DD.jsonl`. The Librarian replays
artifact metadata from disk at startup (bounded by `librarian_max_days`).

The researcher agent's tool executor captures `artifacts_dir` and `librarian` via
closure, wiring the tools to the correct storage location and index.

## 8. Threading

`src/narrative/threading.gleam`

Threads group related narrative entries into ongoing lines of investigation. Thread
assignment uses overlap scoring between a new entry's entities and existing threads:

| Entity type | Weight |
|---|---|
| Location | 3 |
| Domain | 2 |
| Keyword | 1 |

A new entry joins an existing thread when the overlap score meets or exceeds the
threshold (default: 4). If no thread matches, a new thread is created. Thread
assignment is deterministic -- given the same entry and thread index, the result is
always the same.

Threads are derived data, not a separate store. The Librarian maintains a
`ThreadIndex` in ETS, populated from narrative entries. Thread state includes the
thread's domains, keywords, data points, and active/inactive status.

The `recall_threads` tool exposes threads to the LLM, showing active research lines
with their domains, keywords, and data point counts.

## 9. Housekeeping

`src/narrative/housekeeping.gleam`

Periodic maintenance operations triggered by the Curator:

### CBR deduplication

Compares cases using symmetric weighted field similarity (intent, domain, keyword
Jaccard, entity Jaccard). Cases exceeding a configurable similarity threshold are
deduplicated -- the higher-confidence case survives.

### CBR pruning

Removes old, low-confidence failure cases that have no pitfalls recorded. These
are cases where the agent failed but learned nothing reusable. Pruning threshold
is configurable via `[housekeeping]` config.

### Fact conflict resolution

Detects same-key facts with different values and keeps the one with higher
confidence. The lower-confidence fact is superseded (not deleted -- the JSONL
record is preserved with a `Superseded` operation).

Housekeeping produces a `HousekeepingReport` summarising what was cleaned up,
formatted by `format_report` for logging.

## 10. Key source files

| File | Purpose |
|---|---|
| `src/narrative/librarian.gleam` | Supervised actor owning all ETS memory indexes |
| `src/narrative/curator.gleam` | System prompt assembly from identity + memory |
| `src/narrative/archivist.gleam` | Async LLM-based narrative + CBR generation |
| `src/narrative/types.gleam` | `NarrativeEntry`, `Intent`, `Outcome`, `Thread`, `Metrics` |
| `src/narrative/log.gleam` | Append-only JSONL read/write for narrative entries |
| `src/narrative/threading.gleam` | Overlap scoring and thread assignment |
| `src/narrative/housekeeping.gleam` | CBR dedup, pruning, fact conflict resolution |
| `src/narrative/summary.gleam` | Periodic LLM summaries (weekly/monthly) |
| `src/narrative/cycle_tree.gleam` | Hierarchical CycleNode tree from parent links |
| `src/cbr/types.gleam` | `CbrCase`, `CbrProblem`, `CbrSolution`, `CbrOutcome`, `CbrQuery` |
| `src/cbr/log.gleam` | Append-only JSONL for CBR cases |
| `src/cbr/bridge.gleam` | `CaseBase`, inverted index, weighted retrieval |
| `src/facts/types.gleam` | `MemoryFact`, `FactScope`, `FactOp`, `FactProvenance` |
| `src/facts/log.gleam` | Daily-rotated JSONL for facts |
| `src/artifacts/types.gleam` | `ArtifactRecord`, `ArtifactMeta` |
| `src/artifacts/log.gleam` | Daily-rotated JSONL for artifacts |
| `src/tools/artifacts.gleam` | `store_result`, `retrieve_result` tools |
| `src/planner/types.gleam` | `PlannerTask`, `Endeavour`, task/endeavour operations |
| `src/planner/log.gleam` | Daily-rotated JSONL for tasks and endeavours |
| `src/comms/types.gleam` | `CommsMessage`, `CommsChannel`, `DeliveryStatus` |
| `src/comms/log.gleam` | Daily-rotated JSONL for comms messages |
| `src/embedding.gleam` | Ollama embedding HTTP client for CBR retrieval |
| `src/dprime/decay.gleam` | Half-life confidence decay (pure functions) |
