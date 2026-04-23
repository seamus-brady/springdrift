//// Librarian — supervised actor that owns ETS-backed query layers for the
//// Prime Narrative, CBR case store, and Facts store.
////
//// The Librarian retrieves, ranks, and surfaces relevant memories from the
//// narrative log, CBR cases, and semantic facts. It owns ETS tables that serve
//// as a fast query cache over the immutable JSONL files on disk. On startup it
//// replays JSONL files to populate the indexes. The Archivist notifies the
//// Librarian when new entries are written so the cache stays current.
////
//// Narrative ETS tables:
////   - entries (set)           — cycle_id → NarrativeEntry
////   - by_thread (bag)         — thread_id → NarrativeEntry
////   - by_date (bag)           — "YYYY-MM-DD" → NarrativeEntry
////   - by_keyword (bag)        — keyword (lowercased) → NarrativeEntry
////   - by_recency (ordered)    — timestamp → NarrativeEntry
////
//// CBR:
////   - cbr_cases (set)         — case_id → CbrCase (metadata)
////   - CaseBase                — inverted index + optional embeddings (retrieval)
////
//// Facts ETS tables:
////   - facts_by_key (set)      — key → MemoryFact (current value)
////   - facts_by_cycle (bag)    — cycle_id → MemoryFact

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types as agent_types
import artifacts/log as artifacts_log
import artifacts/types as artifacts_types
import captures/log as captures_log
import captures/types as captures_types
import cbr/bridge
import cbr/log as cbr_log
import cbr/types as cbr_types
import dag/types as dag_types
import deputy/types as deputy_types
import facts/types as facts_types
import gleam/erlang/process.{type Pid, type Subject}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/order
import gleam/string
import narrative/librarian/artifacts_index
import narrative/librarian/cbr_index
import narrative/librarian/dag_index
import narrative/librarian/facts_index
import narrative/librarian/narrative_index
import narrative/librarian/planner_index
import narrative/librarian/scratchpad_index
import narrative/log as narrative_log
import narrative/types.{
  type NarrativeEntry, type ThreadIndex, type ThreadState, ThreadIndex,
}
import planner/types as planner_types
import slog

// ---------------------------------------------------------------------------
// CBR Configuration
// ---------------------------------------------------------------------------

/// Configuration for CBR retrieval (weighted field scoring + inverted index).
pub type CbrConfig {
  CbrConfig(
    weights: bridge.RetrievalWeights,
    min_score: Float,
    embed_fn: option.Option(fn(String) -> Result(List(Float), String)),
    cbr_decay_half_life_days: Int,
  )
}

pub fn default_cbr_config() -> CbrConfig {
  CbrConfig(
    weights: bridge.default_weights(),
    min_score: 0.01,
    embed_fn: option.None,
    cbr_decay_half_life_days: 60,
  )
}

// ---------------------------------------------------------------------------
// FFI — ETS operations (typed per value type)
// ---------------------------------------------------------------------------

// Domain-specific opaque ETS table types prevent cross-domain misuse.
// Each domain has its own type so the compiler catches table/value mismatches.
@external(erlang, "springdrift_ffi", "days_between")
fn days_between(date_a: String, date_b: String) -> Int

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

@external(erlang, "springdrift_ffi", "mailbox_size")
fn get_mailbox_size() -> Int

@external(erlang, "springdrift_ffi", "count_lines")
fn count_lines(path: String) -> Int

@external(erlang, "springdrift_ffi", "add_days")
fn add_days_to_date(date: String, days: Int) -> String

// All per-store ETS FFI declarations live in their respective sub-modules:
//   - narrative/librarian/narrative_index
//   - narrative/librarian/cbr_index
//   - narrative/librarian/facts_index
//   - narrative/librarian/scratchpad_index
//   - narrative/librarian/dag_index
//   - narrative/librarian/artifacts_index
//   - narrative/librarian/planner_index

// Planner-typed operations live in `narrative/librarian/planner_index` —
// tasks and endeavours share one ETS-table shape but hold different value
// types, and the sub-module keeps per-value-type FFI signatures encapsulated.

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

pub type LibrarianMessage {
  // --- Narrative ingestion ---
  /// Notify the Librarian that a new entry was written to JSONL.
  IndexEntry(entry: NarrativeEntry)
  /// Update the in-memory thread index.
  UpdateThreadIndex(index: ThreadIndex)

  // --- Narrative queries ---
  /// Query: get entries by date range
  QueryDateRange(
    from: String,
    to: String,
    reply_to: Subject(List(NarrativeEntry)),
  )
  /// Query: search by keyword
  QuerySearch(keyword: String, reply_to: Subject(List(NarrativeEntry)))
  /// Query: get entries for a thread
  QueryThread(thread_id: String, reply_to: Subject(List(NarrativeEntry)))
  /// Query: get N most recent entries
  QueryRecent(n: Int, reply_to: Subject(List(NarrativeEntry)))
  /// Query: get all entries
  QueryAll(reply_to: Subject(List(NarrativeEntry)))
  /// Query: get thread index
  QueryThreadIndex(reply_to: Subject(ThreadIndex))
  /// Query: get thread heads (latest entry per thread)
  QueryThreadHeads(reply_to: Subject(List(NarrativeEntry)))
  /// Query: look up by cycle_id
  QueryByCycleId(
    cycle_id: String,
    reply_to: Subject(Result(NarrativeEntry, Nil)),
  )

  // --- CBR ingestion ---
  /// Notify the Librarian that a new CBR case was written.
  IndexCase(cbr_case: cbr_types.CbrCase)

  // --- CBR queries ---
  /// Retrieve scored cases matching a query.
  RetrieveCases(
    query: cbr_types.CbrQuery,
    reply_to: Subject(List(cbr_types.ScoredCase)),
  )
  /// Look up a single case by ID.
  QueryCaseById(
    case_id: String,
    reply_to: Subject(Result(cbr_types.CbrCase, Nil)),
  )
  /// Get all CBR cases.
  QueryAllCases(reply_to: Subject(List(cbr_types.CbrCase)))

  // --- CBR mutation (Phase 3) ---
  /// Update a case's fields (correct misclassified data).
  UpdateCase(
    case_id: String,
    updated_case: cbr_types.CbrCase,
    reply_to: Subject(Result(Nil, String)),
  )
  /// Append an annotation to a case's pitfalls.
  AnnotateCase(
    case_id: String,
    annotation: String,
    reply_to: Subject(Result(Nil, String)),
  )
  /// Suppress a case — mark as suppressed, remove from retrieval.
  SuppressCase(case_id: String, reply_to: Subject(Result(Nil, String)))
  /// Unsuppress a previously suppressed case — restore to retrieval.
  UnsuppressCase(case_id: String, reply_to: Subject(Result(Nil, String)))
  /// Boost/adjust a case's confidence score.
  BoostCase(
    case_id: String,
    new_confidence: Float,
    reply_to: Subject(Result(Nil, String)),
  )

  /// Update usage stats on a retrieved case (fire-and-forget).
  UpdateCaseUsage(case_id: String, success: Bool)

  // --- Facts ingestion ---
  /// Index a new fact (after it's been written to JSONL).
  IndexFact(fact: facts_types.MemoryFact)

  // --- Facts queries ---
  /// Get current fact by key.
  QueryFactByKey(
    key: String,
    reply_to: Subject(Result(facts_types.MemoryFact, Nil)),
  )
  /// Get all facts for a cycle.
  QueryFactsByCycle(
    cycle_id: String,
    reply_to: Subject(List(facts_types.MemoryFact)),
  )
  /// Get all current (non-superseded, non-cleared) facts.
  QueryAllFacts(reply_to: Subject(List(facts_types.MemoryFact)))
  /// Search facts by keyword in key or value.
  QueryFactsByKeyword(
    keyword: String,
    reply_to: Subject(List(facts_types.MemoryFact)),
  )

  // --- Housekeeping ---
  /// Remove a CBR case from all indices (after dedup/pruning).
  RemoveCase(case_id: String)
  /// Supersede a fact: remove old key from facts_by_key, index the superseded record.
  SupersedeFact(fact: facts_types.MemoryFact)

  // --- Scratchpad (agent results per cycle) ---
  /// Write an agent result to the cycle scratchpad.
  WriteAgentResult(cycle_id: String, result: agent_types.AgentResult)
  /// Read all agent results for a cycle.
  ReadCycleResults(
    cycle_id: String,
    reply_to: Subject(List(agent_types.AgentResult)),
  )
  /// Clear the scratchpad for a cycle.
  ClearCycleScratchpad(cycle_id: String)

  // --- Count queries ---
  /// Get the number of active threads.
  QueryThreadCount(reply_to: Subject(Int))
  /// Get the number of persistent facts (by key count).
  QueryPersistentFactCount(reply_to: Subject(Int))
  /// Get the number of CBR cases.
  QueryCaseCount(reply_to: Subject(Int))

  // --- DAG ingestion ---
  /// Index a new DAG node (cycle start or update).
  IndexNode(node: dag_types.CycleNode)
  /// Update an existing DAG node (cycle complete).
  UpdateNode(node: dag_types.CycleNode)

  // --- DAG queries ---
  /// Look up a single CycleNode by cycle_id.
  QueryNode(
    cycle_id: String,
    reply_to: Subject(Result(dag_types.CycleNode, Nil)),
  )
  /// Get all child nodes for a parent cycle_id.
  QueryChildren(parent_id: String, reply_to: Subject(List(dag_types.CycleNode)))
  /// Get root cognitive cycles for a date ("YYYY-MM-DD").
  QueryDayRoots(date: String, reply_to: Subject(List(dag_types.CycleNode)))
  /// Get all cycles (roots + agents) for a date.
  QueryDayAll(date: String, reply_to: Subject(List(dag_types.CycleNode)))
  /// Get full subtree rooted at a cycle_id.
  QueryNodeWithDescendants(
    cycle_id: String,
    reply_to: Subject(Result(dag_types.DagSubtree, Nil)),
  )
  /// Get aggregated stats for a date.
  QueryDayStats(date: String, reply_to: Subject(dag_types.DayStats))
  /// Get per-tool usage stats for a date.
  QueryToolActivity(
    date: String,
    reply_to: Subject(List(dag_types.ToolActivityRecord)),
  )

  // --- Artifact operations ---
  /// Index a new artifact after it has been written to disk.
  IndexArtifact(meta: artifacts_types.ArtifactMeta)
  /// Query all artifact metadata for a given cycle.
  QueryArtifactsByCycle(
    cycle_id: String,
    reply_to: Subject(List(artifacts_types.ArtifactMeta)),
  )
  /// Read full artifact content from disk (targeted file read).
  RetrieveArtifactContent(
    artifact_id: String,
    stored_at: String,
    reply_to: Subject(Result(String, Nil)),
  )
  /// Look up artifact metadata by ID.
  QueryArtifactById(
    artifact_id: String,
    reply_to: Subject(Result(artifacts_types.ArtifactMeta, Nil)),
  )

  // --- Scheduler cycle queries ---
  /// Get DAG nodes with node_type == SchedulerCycle for a date.
  QuerySchedulerCycles(
    date: String,
    reply_to: Subject(List(dag_types.CycleNode)),
  )

  // --- Planner operations ---
  /// Notify of a new task operation (after writing to JSONL).
  NotifyTaskOp(op: planner_types.TaskOp)
  /// Notify of a new endeavour operation (after writing to JSONL).
  NotifyEndeavourOp(op: planner_types.EndeavourOp)
  /// Query active tasks (Pending + Active).
  QueryActiveTasks(reply_to: Subject(List(planner_types.PlannerTask)))
  /// Query a single task by ID.
  QueryTaskById(
    task_id: String,
    reply_to: Subject(Result(planner_types.PlannerTask, Nil)),
  )
  /// Query a single endeavour by ID.
  QueryEndeavourById(
    endeavour_id: String,
    reply_to: Subject(Result(planner_types.Endeavour, Nil)),
  )
  /// Query all endeavours.
  QueryAllEndeavours(reply_to: Subject(List(planner_types.Endeavour)))
  /// Load narrative entries by cycle_ids (for Forecaster).
  LoadByCycleIds(
    cycle_ids: List(String),
    reply_to: Subject(List(NarrativeEntry)),
  )

  // --- Trim operations (Housekeeper) ---
  /// Evict narrative entries older than cutoff_date from all narrative ETS tables.
  TrimNarrativeWindow(cutoff_date: String, reply_to: Subject(Int))
  /// Evict DAG nodes older than cutoff_date from all DAG ETS tables.
  TrimDagWindow(cutoff_date: String, reply_to: Subject(Int))
  /// Evict artifact metadata older than cutoff_date from artifact ETS tables.
  TrimArtifactWindow(cutoff_date: String, reply_to: Subject(Int))

  // --- Captures (MVP commitment tracker) ---
  /// Populate the captures pending-list from disk. Called once after start
  /// by the main process. Safe to call again to refresh.
  InitCaptures(captures_dir: String)
  /// Index a newly-created pending capture (fire-and-forget).
  IndexCapture(capture: captures_types.Capture)
  /// Remove a capture from the pending list (after clarify/dismiss/expire).
  RemoveCapture(id: String)
  /// Count of pending captures — cheap, used by the sensorium every cycle.
  QueryPendingCaptureCount(reply_to: Subject(Int))
  /// Full list of pending captures — used by list_captures tool.
  QueryPendingCaptures(reply_to: Subject(List(captures_types.Capture)))

  // --- Deputies (MVP Phase 1) ---
  /// Register an active deputy (spawned, briefing in flight).
  IndexActiveDeputy(meta: ActiveDeputyMeta)
  /// Remove an active deputy when it completes, fails, or is killed.
  RemoveActiveDeputy(id: String)
  /// Append a completed deputy to the recent-deputies ring buffer.
  AppendRecentDeputy(record: RecentDeputyRecord)
  /// Query active deputies — used by introspect and kill_deputy.
  QueryActiveDeputies(reply_to: Subject(List(ActiveDeputyMeta)))
  /// Query a single active deputy by id — for kill_deputy lookup.
  QueryActiveDeputyById(
    id: String,
    reply_to: Subject(Result(ActiveDeputyMeta, Nil)),
  )
  /// Query the recent-deputies ring — used by the sensorium block.
  QueryRecentDeputies(reply_to: Subject(List(RecentDeputyRecord)))
  /// Count of active deputies — cheap sensorium signal.
  QueryActiveDeputyCount(reply_to: Subject(Int))

  /// Shutdown
  Shutdown
}

// ---------------------------------------------------------------------------
// Deputy metadata shared between the Librarian and call sites
// ---------------------------------------------------------------------------

/// In-flight deputy metadata. Used by introspect + kill_deputy.
pub type ActiveDeputyMeta {
  ActiveDeputyMeta(
    id: String,
    cycle_id: String,
    hierarchy_cycle_id: String,
    root_agent: String,
    spawned_at: String,
    subject: Subject(deputy_types.DeputyMessage),
  )
}

/// Completed deputy record retained in the ring buffer.
pub type RecentDeputyRecord {
  RecentDeputyRecord(
    id: String,
    cycle_id: String,
    root_agent: String,
    signal: String,
    cases_count: Int,
    facts_count: Int,
    elapsed_ms: Int,
    completed_at: String,
    outcome: RecentDeputyOutcome,
  )
}

pub type RecentDeputyOutcome {
  BriefingOk
  BriefingFailed(reason: String)
  BriefingKilled(reason: String)
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

type LibrarianState {
  LibrarianState(
    self: Subject(LibrarianMessage),
    narrative_dir: String,
    cbr_dir: String,
    // Narrative ETS tables
    entries: narrative_index.Table,
    by_thread: narrative_index.Table,
    by_date: narrative_index.Table,
    by_keyword: narrative_index.Table,
    by_recency: narrative_index.Table,
    thread_index: ThreadIndex,
    // CBR — metadata ETS + CaseBase (inverted index + embeddings) + config
    cbr_cases: cbr_index.Table,
    case_base: bridge.CaseBase,
    cbr_config: CbrConfig,
    // Facts
    facts_dir: String,
    facts_by_key: facts_index.Table,
    facts_by_cycle: facts_index.Table,
    // Scratchpad — agent results per cycle (ephemeral, bag)
    cycle_scratchpad: scratchpad_index.Table,
    // DAG ETS tables
    dag_nodes: dag_index.Table,
    dag_by_parent: dag_index.Table,
    dag_by_date: dag_index.Table,
    // Artifact ETS tables
    artifacts_dir: String,
    artifacts: artifacts_index.Table,
    artifacts_by_cycle: artifacts_index.Table,
    // Planner ETS tables
    planner_dir: String,
    planner_tasks: planner_index.Table,
    planner_endeavours: planner_index.Table,
    // Captures (MVP commitment tracker) — pure list, populated on InitCaptures
    captures_dir: String,
    pending_captures: List(captures_types.Capture),
    // Deputies (MVP) — active deputies (in-flight) and recent completions
    active_deputies: List(ActiveDeputyMeta),
    recent_deputies: List(RecentDeputyRecord),
  )
}

/// Cap on retained recent-deputy records.
const recent_deputies_cap: Int = 20

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start the Librarian actor. Replays JSONL files to populate ETS indexes.
/// `max_files` limits startup loading (0 = all files).
/// Returns a Subject for sending queries and index notifications.
pub fn start(
  narrative_dir: String,
  cbr_dir: String,
  facts_dir: String,
  artifacts_dir: String,
  planner_dir: String,
  max_files: Int,
  cbr_config: CbrConfig,
) -> Subject(LibrarianMessage) {
  let #(subj, _pid) =
    start_with_pid(
      narrative_dir,
      cbr_dir,
      facts_dir,
      artifacts_dir,
      planner_dir,
      max_files,
      cbr_config,
    )
  subj
}

/// Start the Librarian actor, returning both the Subject and the Pid.
/// Used by the supervisor to set up a process monitor.
fn start_with_pid(
  narrative_dir: String,
  cbr_dir: String,
  facts_dir: String,
  artifacts_dir: String,
  planner_dir: String,
  max_files: Int,
  cbr_config: CbrConfig,
) -> #(Subject(LibrarianMessage), Pid) {
  let setup: Subject(Subject(LibrarianMessage)) = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let self: Subject(LibrarianMessage) = process.new_subject()
      process.send(setup, self)

      // Create narrative ETS tables
      let entries_table = narrative_index.new_table("narrative_entries", "set")
      let by_thread_table =
        narrative_index.new_table("narrative_by_thread", "bag")
      let by_date_table = narrative_index.new_table("narrative_by_date", "bag")
      let by_keyword_table =
        narrative_index.new_table("narrative_by_keyword", "bag")
      let by_recency_table =
        narrative_index.new_table("narrative_by_recency", "ordered_set")

      // Create CBR metadata ETS table + CaseBase
      let cbr_cases_table = cbr_index.new_table("cbr_cases", "set")
      let case_base = case cbr_config.embed_fn {
        option.Some(embed_fn) -> bridge.new_with_embeddings(embed_fn)
        option.None -> bridge.new()
      }

      // Create Facts ETS tables
      let facts_key_table = facts_index.new_table("facts_by_key", "set")
      let facts_cycle_table = facts_index.new_table("facts_by_cycle", "bag")

      // Create scratchpad table (bag — multiple results per cycle)
      let scratchpad_table =
        scratchpad_index.new_table("cycle_scratchpad", "bag")

      // Create DAG ETS tables
      let dag_nodes_table = dag_index.new_table("dag_nodes", "set")
      let dag_parent_table = dag_index.new_table("dag_by_parent", "bag")
      let dag_date_table = dag_index.new_table("dag_by_date", "bag")

      // Create Artifact ETS tables
      let artifacts_table = artifacts_index.new_table("artifacts", "set")
      let artifacts_cycle_table =
        artifacts_index.new_table("artifacts_by_cycle", "bag")

      // Create Planner ETS tables
      let planner_tasks_table = planner_index.new_table("planner_tasks", "set")
      let planner_endeavours_table =
        planner_index.new_table("planner_endeavours", "set")

      let state =
        LibrarianState(
          self:,
          narrative_dir:,
          cbr_dir:,
          entries: entries_table,
          by_thread: by_thread_table,
          by_date: by_date_table,
          by_keyword: by_keyword_table,
          by_recency: by_recency_table,
          thread_index: ThreadIndex(threads: []),
          cbr_cases: cbr_cases_table,
          case_base:,
          cbr_config:,
          facts_dir:,
          facts_by_key: facts_key_table,
          facts_by_cycle: facts_cycle_table,
          cycle_scratchpad: scratchpad_table,
          dag_nodes: dag_nodes_table,
          dag_by_parent: dag_parent_table,
          dag_by_date: dag_date_table,
          artifacts_dir:,
          artifacts: artifacts_table,
          artifacts_by_cycle: artifacts_cycle_table,
          planner_dir:,
          planner_tasks: planner_tasks_table,
          planner_endeavours: planner_endeavours_table,
          captures_dir: "",
          pending_captures: [],
          active_deputies: [],
          recent_deputies: [],
        )

      // Replay narrative JSONL files
      narrative_index.replay_from_disk(
        entries_table,
        by_thread_table,
        by_date_table,
        by_keyword_table,
        by_recency_table,
        narrative_dir,
        max_files,
      )

      // Load thread index
      let thread_index = narrative_log.load_thread_index(narrative_dir)
      let state = LibrarianState(..state, thread_index:)

      // Replay CBR JSONL files (into metadata ETS + CaseBase)
      let case_base =
        cbr_index.replay_from_disk(
          cbr_cases_table,
          state.case_base,
          cbr_dir,
          max_files,
        )
      let state = LibrarianState(..state, case_base:)

      // Replay facts from disk
      facts_index.replay_from_disk(
        facts_key_table,
        facts_cycle_table,
        facts_dir,
      )

      // Replay DAG from cycle log
      dag_index.replay_from_cycle_log(
        dag_nodes_table,
        dag_parent_table,
        dag_date_table,
        max_files,
      )

      // Replay artifacts from disk
      artifacts_index.replay_from_disk(
        artifacts_table,
        artifacts_cycle_table,
        artifacts_dir,
        max_files,
      )

      // Replay planner from disk
      planner_index.replay_from_disk(
        planner_tasks_table,
        planner_endeavours_table,
        planner_dir,
        max_files,
      )

      let narrative_count = narrative_index.table_size(entries_table)
      let cbr_count = cbr_index.table_size(cbr_cases_table)
      let facts_count = facts_index.table_size(facts_key_table)
      let tasks_count = planner_index.table_size(planner_tasks_table)
      slog.info(
        "narrative/librarian",
        "start",
        "Librarian ready — "
          <> string.inspect(narrative_count)
          <> " narrative entries, "
          <> string.inspect(cbr_count)
          <> " CBR cases, "
          <> string.inspect(facts_count)
          <> " facts, "
          <> string.inspect(tasks_count)
          <> " tasks",
        None,
      )

      // Enter message loop
      loop(state)
    })

  // Wait for the actor to send back its Subject
  case process.receive(setup, 30_000) {
    Ok(subj) -> #(subj, pid)
    Error(_) -> {
      slog.log_error(
        "librarian",
        "start",
        "Librarian failed to start within 30s",
        None,
      )
      panic as "Librarian startup timeout"
    }
  }
}

/// Start a supervised Librarian. If the Librarian crashes, it is automatically
/// restarted (up to `max_restarts` times). Returns a Subject that always points
/// to the current Librarian instance via an indirection process.
pub fn start_supervised(
  narrative_dir: String,
  cbr_dir: String,
  facts_dir: String,
  artifacts_dir: String,
  planner_dir: String,
  max_files: Int,
  max_restarts: Int,
  cbr_config: CbrConfig,
) -> Result(Subject(LibrarianMessage), Nil) {
  // The proxy subject must be created inside the spawned process (owner rule),
  // then sent back to the caller via a setup channel.
  let setup: Subject(Subject(LibrarianMessage)) = process.new_subject()
  process.spawn_unlinked(fn() {
    let proxy_subj: Subject(LibrarianMessage) = process.new_subject()
    process.send(setup, proxy_subj)
    librarian_supervisor_loop(
      narrative_dir,
      cbr_dir,
      facts_dir,
      artifacts_dir,
      planner_dir,
      max_files,
      max_restarts,
      0,
      proxy_subj,
      cbr_config,
    )
  })
  case process.receive(setup, 30_000) {
    Ok(proxy_subj) -> Ok(proxy_subj)
    Error(_) -> {
      slog.log_error(
        "librarian",
        "start_supervised",
        "Supervised Librarian failed to start within 30s",
        None,
      )
      Error(Nil)
    }
  }
}

/// Internal message type for the supervisor selector.
type SupervisorEvent {
  ForwardMsg(LibrarianMessage)
  LibrarianDown
}

fn librarian_supervisor_loop(
  narrative_dir: String,
  cbr_dir: String,
  facts_dir: String,
  artifacts_dir: String,
  planner_dir: String,
  max_files: Int,
  max_restarts: Int,
  restart_count: Int,
  proxy: Subject(LibrarianMessage),
  cbr_config: CbrConfig,
) -> Nil {
  // Start a fresh librarian, getting both Subject and Pid
  let #(librarian, pid) =
    start_with_pid(
      narrative_dir,
      cbr_dir,
      facts_dir,
      artifacts_dir,
      planner_dir,
      max_files,
      cbr_config,
    )

  // Set up OTP monitor — fires immediately when the process exits
  let monitor = process.monitor(pid)

  // Build a selector that handles both forwarded messages and DOWN signals
  let sel =
    process.new_selector()
    |> process.select_map(proxy, fn(msg) { ForwardMsg(msg) })
    |> process.select_specific_monitor(monitor, fn(_down) { LibrarianDown })

  // Forward messages until the librarian dies
  forward_loop(
    librarian,
    sel,
    narrative_dir,
    cbr_dir,
    facts_dir,
    artifacts_dir,
    planner_dir,
    max_files,
    max_restarts,
    restart_count,
    proxy,
    cbr_config,
  )
}

fn forward_loop(
  librarian: Subject(LibrarianMessage),
  sel: process.Selector(SupervisorEvent),
  narrative_dir: String,
  cbr_dir: String,
  facts_dir: String,
  artifacts_dir: String,
  planner_dir: String,
  max_files: Int,
  max_restarts: Int,
  restart_count: Int,
  proxy: Subject(LibrarianMessage),
  cbr_config: CbrConfig,
) -> Nil {
  case process.selector_receive_forever(sel) {
    ForwardMsg(msg) -> {
      process.send(librarian, msg)
      forward_loop(
        librarian,
        sel,
        narrative_dir,
        cbr_dir,
        facts_dir,
        artifacts_dir,
        planner_dir,
        max_files,
        max_restarts,
        restart_count,
        proxy,
        cbr_config,
      )
    }
    LibrarianDown -> {
      case restart_count < max_restarts {
        True -> {
          slog.warn(
            "librarian",
            "supervisor",
            "Librarian process exited, restarting (attempt "
              <> string.inspect(restart_count + 1)
              <> ")",
            None,
          )
          librarian_supervisor_loop(
            narrative_dir,
            cbr_dir,
            facts_dir,
            artifacts_dir,
            planner_dir,
            max_files,
            max_restarts,
            restart_count + 1,
            proxy,
            cbr_config,
          )
        }
        False -> {
          slog.log_error(
            "librarian",
            "supervisor",
            "Librarian max restarts exceeded, giving up",
            None,
          )
          Nil
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Synchronous query helpers — Narrative
// ---------------------------------------------------------------------------

/// Query entries by date range. Blocks until reply.
pub fn load_entries(
  librarian: Subject(LibrarianMessage),
  from: String,
  to: String,
) -> List(NarrativeEntry) {
  let reply_to = process.new_subject()
  process.send(librarian, QueryDateRange(from:, to:, reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(entries) -> entries
    Error(_) -> {
      slog.warn("librarian", "load_entries", "Timeout waiting for reply", None)
      []
    }
  }
}

/// Search by keyword. Blocks until reply.
pub fn search(
  librarian: Subject(LibrarianMessage),
  keyword: String,
) -> List(NarrativeEntry) {
  let reply_to = process.new_subject()
  process.send(librarian, QuerySearch(keyword:, reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(entries) -> entries
    Error(_) -> {
      slog.warn("librarian", "search", "Timeout waiting for reply", None)
      []
    }
  }
}

/// Get thread index. Blocks until reply.
pub fn load_thread_index(librarian: Subject(LibrarianMessage)) -> ThreadIndex {
  let reply_to = process.new_subject()
  process.send(librarian, QueryThreadIndex(reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(idx) -> idx
    Error(_) -> {
      slog.warn(
        "librarian",
        "load_thread_index",
        "Timeout waiting for reply",
        None,
      )
      ThreadIndex(threads: [])
    }
  }
}

/// Get all entries. Blocks until reply.
pub fn load_all(librarian: Subject(LibrarianMessage)) -> List(NarrativeEntry) {
  let reply_to = process.new_subject()
  process.send(librarian, QueryAll(reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(entries) -> entries
    Error(_) -> {
      slog.warn("librarian", "load_all", "Timeout waiting for reply", None)
      []
    }
  }
}

/// Get entries for a thread. Blocks until reply.
pub fn load_thread(
  librarian: Subject(LibrarianMessage),
  thread_id: String,
) -> List(NarrativeEntry) {
  let reply_to = process.new_subject()
  process.send(librarian, QueryThread(thread_id:, reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(entries) -> entries
    Error(_) -> {
      slog.warn("librarian", "load_thread", "Timeout waiting for reply", None)
      []
    }
  }
}

/// Get N most recent entries. Blocks until reply.
pub fn get_recent(
  librarian: Subject(LibrarianMessage),
  n: Int,
) -> List(NarrativeEntry) {
  let reply_to = process.new_subject()
  process.send(librarian, QueryRecent(n:, reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(entries) -> entries
    Error(_) -> {
      slog.warn("librarian", "get_recent", "Timeout waiting for reply", None)
      []
    }
  }
}

/// Get thread heads. Blocks until reply.
pub fn thread_heads(
  librarian: Subject(LibrarianMessage),
) -> List(NarrativeEntry) {
  let reply_to = process.new_subject()
  process.send(librarian, QueryThreadHeads(reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(entries) -> entries
    Error(_) -> {
      slog.warn("librarian", "thread_heads", "Timeout waiting for reply", None)
      []
    }
  }
}

/// Notify the Librarian to index a new entry (fire-and-forget).
pub fn notify_new_entry(
  librarian: Subject(LibrarianMessage),
  entry: NarrativeEntry,
) -> Nil {
  process.send(librarian, IndexEntry(entry:))
}

/// Notify the Librarian of an updated thread index (fire-and-forget).
pub fn notify_thread_index(
  librarian: Subject(LibrarianMessage),
  index: ThreadIndex,
) -> Nil {
  process.send(librarian, UpdateThreadIndex(index:))
}

// ---------------------------------------------------------------------------
// Synchronous query helpers — CBR
// ---------------------------------------------------------------------------

/// Notify the Librarian to index a new CBR case (fire-and-forget).
pub fn notify_new_case(
  librarian: Subject(LibrarianMessage),
  cbr_case: cbr_types.CbrCase,
) -> Nil {
  process.send(librarian, IndexCase(cbr_case:))
}

/// Update usage stats on a retrieved CBR case (fire-and-forget).
/// Increments retrieval_count, and conditionally retrieval_success_count.
pub fn update_case_usage(
  librarian: Subject(LibrarianMessage),
  case_id: String,
  success: Bool,
) -> Nil {
  process.send(librarian, UpdateCaseUsage(case_id:, success:))
}

/// Retrieve scored cases matching a query. Blocks until reply.
pub fn retrieve_cases(
  librarian: Subject(LibrarianMessage),
  query: cbr_types.CbrQuery,
) -> List(cbr_types.ScoredCase) {
  let reply_to = process.new_subject()
  process.send(librarian, RetrieveCases(query:, reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(results) -> results
    Error(_) -> {
      slog.warn(
        "librarian",
        "retrieve_cases",
        "Timeout waiting for reply",
        None,
      )
      []
    }
  }
}

/// Get all CBR cases. Blocks until reply.
pub fn load_all_cases(
  librarian: Subject(LibrarianMessage),
) -> List(cbr_types.CbrCase) {
  let reply_to = process.new_subject()
  process.send(librarian, QueryAllCases(reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(cases) -> cases
    Error(_) -> {
      slog.warn(
        "librarian",
        "load_all_cases",
        "Timeout waiting for reply",
        None,
      )
      []
    }
  }
}

// ---------------------------------------------------------------------------
// Synchronous mutation helpers — CBR
// ---------------------------------------------------------------------------

/// Update a case's fields. Blocks until reply.
pub fn update_case(
  librarian: Subject(LibrarianMessage),
  case_id: String,
  updated_case: cbr_types.CbrCase,
) -> Result(Nil, String) {
  let reply_to = process.new_subject()
  process.send(librarian, UpdateCase(case_id:, updated_case:, reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(result) -> result
    Error(_) -> Error("Timeout waiting for update_case reply")
  }
}

/// Append an annotation to a case's pitfalls. Blocks until reply.
pub fn annotate_case(
  librarian: Subject(LibrarianMessage),
  case_id: String,
  annotation: String,
) -> Result(Nil, String) {
  let reply_to = process.new_subject()
  process.send(librarian, AnnotateCase(case_id:, annotation:, reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(result) -> result
    Error(_) -> Error("Timeout waiting for annotate_case reply")
  }
}

/// Suppress a case — remove from retrieval. Blocks until reply.
pub fn suppress_case(
  librarian: Subject(LibrarianMessage),
  case_id: String,
) -> Result(Nil, String) {
  let reply_to = process.new_subject()
  process.send(librarian, SuppressCase(case_id:, reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(result) -> result
    Error(_) -> Error("Timeout waiting for suppress_case reply")
  }
}

/// Unsuppress a previously suppressed case. Blocks until reply.
pub fn unsuppress_case(
  librarian: Subject(LibrarianMessage),
  case_id: String,
) -> Result(Nil, String) {
  let reply_to = process.new_subject()
  process.send(librarian, UnsuppressCase(case_id:, reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(result) -> result
    Error(_) -> Error("Timeout waiting for unsuppress_case reply")
  }
}

/// Boost/adjust a case's confidence. Blocks until reply.
pub fn boost_case(
  librarian: Subject(LibrarianMessage),
  case_id: String,
  new_confidence: Float,
) -> Result(Nil, String) {
  let reply_to = process.new_subject()
  process.send(librarian, BoostCase(case_id:, new_confidence:, reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(result) -> result
    Error(_) -> Error("Timeout waiting for boost_case reply")
  }
}

// ---------------------------------------------------------------------------
// Synchronous query helpers — Facts
// ---------------------------------------------------------------------------

/// Notify the Librarian to index a new fact (fire-and-forget).
pub fn notify_new_fact(
  librarian: Subject(LibrarianMessage),
  fact: facts_types.MemoryFact,
) -> Nil {
  process.send(librarian, IndexFact(fact:))
}

/// Get current fact by key. Blocks until reply.
pub fn get_fact(
  librarian: Subject(LibrarianMessage),
  key: String,
) -> Result(facts_types.MemoryFact, Nil) {
  let reply_to = process.new_subject()
  process.send(librarian, QueryFactByKey(key:, reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(result) -> result
    Error(_) -> {
      slog.warn("librarian", "get_fact", "Timeout waiting for reply", None)
      Error(Nil)
    }
  }
}

/// Get all facts for a cycle. Blocks until reply.
pub fn get_facts_by_cycle(
  librarian: Subject(LibrarianMessage),
  cycle_id: String,
) -> List(facts_types.MemoryFact) {
  let reply_to = process.new_subject()
  process.send(librarian, QueryFactsByCycle(cycle_id:, reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(facts) -> facts
    Error(_) -> {
      slog.warn(
        "librarian",
        "get_facts_by_cycle",
        "Timeout waiting for reply",
        None,
      )
      []
    }
  }
}

/// Get all current facts. Blocks until reply.
pub fn get_all_facts(
  librarian: Subject(LibrarianMessage),
) -> List(facts_types.MemoryFact) {
  let reply_to = process.new_subject()
  process.send(librarian, QueryAllFacts(reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(facts) -> facts
    Error(_) -> {
      slog.warn("librarian", "get_all_facts", "Timeout waiting for reply", None)
      []
    }
  }
}

/// Search facts by keyword. Blocks until reply.
pub fn search_facts(
  librarian: Subject(LibrarianMessage),
  keyword: String,
) -> List(facts_types.MemoryFact) {
  let reply_to = process.new_subject()
  process.send(librarian, QueryFactsByKeyword(keyword:, reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(facts) -> facts
    Error(_) -> {
      slog.warn("librarian", "search_facts", "Timeout waiting for reply", None)
      []
    }
  }
}

// ---------------------------------------------------------------------------
// Synchronous query helpers — Scratchpad
// ---------------------------------------------------------------------------

/// Write an agent result to the cycle scratchpad (fire-and-forget).
pub fn write_agent_result(
  librarian: Subject(LibrarianMessage),
  cycle_id: String,
  result: agent_types.AgentResult,
) -> Nil {
  process.send(librarian, WriteAgentResult(cycle_id:, result:))
}

/// Read all agent results for a cycle. Blocks until reply.
pub fn read_cycle_results(
  librarian: Subject(LibrarianMessage),
  cycle_id: String,
) -> List(agent_types.AgentResult) {
  let reply_to = process.new_subject()
  process.send(librarian, ReadCycleResults(cycle_id:, reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(results) -> results
    Error(_) -> {
      slog.warn(
        "librarian",
        "read_cycle_results",
        "Timeout waiting for reply",
        None,
      )
      []
    }
  }
}

/// Remove a CBR case from all indices (fire-and-forget).
pub fn remove_case(librarian: Subject(LibrarianMessage), case_id: String) -> Nil {
  process.send(librarian, RemoveCase(case_id:))
}

/// Supersede a fact in indices (fire-and-forget).
pub fn supersede_fact(
  librarian: Subject(LibrarianMessage),
  fact: facts_types.MemoryFact,
) -> Nil {
  process.send(librarian, SupersedeFact(fact:))
}

/// Clear the scratchpad for a cycle (fire-and-forget).
/// Get the number of active threads. Blocks until reply.
pub fn get_thread_count(librarian: Subject(LibrarianMessage)) -> Int {
  let reply_to = process.new_subject()
  process.send(librarian, QueryThreadCount(reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(count) -> count
    Error(_) -> {
      slog.warn(
        "librarian",
        "get_thread_count",
        "Timeout waiting for reply",
        None,
      )
      0
    }
  }
}

/// Get the number of persistent facts. Blocks until reply.
pub fn get_persistent_fact_count(librarian: Subject(LibrarianMessage)) -> Int {
  let reply_to = process.new_subject()
  process.send(librarian, QueryPersistentFactCount(reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(count) -> count
    Error(_) -> {
      slog.warn(
        "librarian",
        "get_persistent_fact_count",
        "Timeout waiting for reply",
        None,
      )
      0
    }
  }
}

/// Get the number of CBR cases. Blocks until reply.
pub fn get_case_count(librarian: Subject(LibrarianMessage)) -> Int {
  let reply_to = process.new_subject()
  process.send(librarian, QueryCaseCount(reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(count) -> count
    Error(_) -> {
      slog.warn(
        "librarian",
        "get_case_count",
        "Timeout waiting for reply",
        None,
      )
      0
    }
  }
}

pub fn clear_cycle_scratchpad(
  librarian: Subject(LibrarianMessage),
  cycle_id: String,
) -> Nil {
  process.send(librarian, ClearCycleScratchpad(cycle_id:))
}

/// Trim narrative entries older than cutoff_date. Blocks until reply.
pub fn trim_narrative_window(
  librarian: Subject(LibrarianMessage),
  cutoff_date: String,
) -> Int {
  let reply_to = process.new_subject()
  process.send(librarian, TrimNarrativeWindow(cutoff_date:, reply_to:))
  case process.receive(reply_to, 30_000) {
    Ok(count) -> count
    Error(_) -> 0
  }
}

/// Trim DAG nodes older than cutoff_date. Blocks until reply.
pub fn trim_dag_window(
  librarian: Subject(LibrarianMessage),
  cutoff_date: String,
) -> Int {
  let reply_to = process.new_subject()
  process.send(librarian, TrimDagWindow(cutoff_date:, reply_to:))
  case process.receive(reply_to, 30_000) {
    Ok(count) -> count
    Error(_) -> 0
  }
}

/// Trim artifact metadata older than cutoff_date. Blocks until reply.
pub fn trim_artifact_window(
  librarian: Subject(LibrarianMessage),
  cutoff_date: String,
) -> Int {
  let reply_to = process.new_subject()
  process.send(librarian, TrimArtifactWindow(cutoff_date:, reply_to:))
  case process.receive(reply_to, 30_000) {
    Ok(count) -> count
    Error(_) -> 0
  }
}

pub fn query_tool_activity(
  librarian: Subject(LibrarianMessage),
  date: String,
) -> List(dag_types.ToolActivityRecord) {
  let reply_to = process.new_subject()
  process.send(librarian, QueryToolActivity(date:, reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(records) -> records
    Error(_) -> []
  }
}

// ---------------------------------------------------------------------------
// Synchronous query helpers — Artifacts
// ---------------------------------------------------------------------------

/// Notify the Librarian to index a new artifact (fire-and-forget).
pub fn index_artifact(
  librarian: Subject(LibrarianMessage),
  meta: artifacts_types.ArtifactMeta,
) -> Nil {
  process.send(librarian, IndexArtifact(meta:))
}

/// Query all artifact metadata for a cycle. Blocks until reply.
pub fn query_artifacts_by_cycle(
  librarian: Subject(LibrarianMessage),
  cycle_id: String,
) -> List(artifacts_types.ArtifactMeta) {
  let reply_to = process.new_subject()
  process.send(librarian, QueryArtifactsByCycle(cycle_id:, reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(metas) -> metas
    Error(_) -> {
      slog.warn(
        "librarian",
        "query_artifacts_by_cycle",
        "Timeout waiting for reply",
        None,
      )
      []
    }
  }
}

/// Retrieve full artifact content by ID. Blocks until reply.
pub fn retrieve_artifact_content(
  librarian: Subject(LibrarianMessage),
  artifact_id: String,
  stored_at: String,
) -> Result(String, Nil) {
  let reply_to = process.new_subject()
  process.send(
    librarian,
    RetrieveArtifactContent(artifact_id:, stored_at:, reply_to:),
  )
  case process.receive(reply_to, 5000) {
    Ok(result) -> result
    Error(_) -> {
      slog.warn(
        "librarian",
        "retrieve_artifact_content",
        "Timeout waiting for reply",
        None,
      )
      Error(Nil)
    }
  }
}

/// Look up artifact metadata by ID. Blocks until reply.
pub fn lookup_artifact(
  librarian: Subject(LibrarianMessage),
  artifact_id: String,
) -> Result(artifacts_types.ArtifactMeta, Nil) {
  let reply_to = process.new_subject()
  process.send(librarian, QueryArtifactById(artifact_id:, reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(result) -> result
    Error(_) -> {
      slog.warn(
        "librarian",
        "lookup_artifact",
        "Timeout waiting for reply",
        None,
      )
      Error(Nil)
    }
  }
}

// ---------------------------------------------------------------------------
// Message loop
// ---------------------------------------------------------------------------

fn loop(state: LibrarianState) -> Nil {
  // Periodic mailbox backpressure check
  let mbox_size = get_mailbox_size()
  let threshold = 50
  case mbox_size > threshold {
    True ->
      slog.warn(
        "librarian",
        "loop",
        "Mailbox backpressure: "
          <> int.to_string(mbox_size)
          <> " messages queued (threshold="
          <> int.to_string(threshold)
          <> ")",
        None,
      )
    False -> Nil
  }
  case process.receive(state.self, 60_000) {
    Error(_) -> {
      // Timeout — run periodic ETS-vs-disk reconciliation
      let state = reconcile_ets_with_disk(state)
      loop(state)
    }
    Ok(msg) ->
      case msg {
        Shutdown -> {
          // Delete narrative tables
          narrative_index.delete_table(state.entries)
          narrative_index.delete_table(state.by_thread)
          narrative_index.delete_table(state.by_date)
          narrative_index.delete_table(state.by_keyword)
          narrative_index.delete_table(state.by_recency)
          // Delete CBR metadata table
          cbr_index.delete_table(state.cbr_cases)
          // Delete Facts tables
          facts_index.delete_table(state.facts_by_key)
          facts_index.delete_table(state.facts_by_cycle)
          // Delete scratchpad
          scratchpad_index.delete_table(state.cycle_scratchpad)
          // Delete DAG tables
          dag_index.delete_table(state.dag_nodes)
          dag_index.delete_table(state.dag_by_parent)
          dag_index.delete_table(state.dag_by_date)
          // Delete Artifact tables
          artifacts_index.delete_table(state.artifacts)
          artifacts_index.delete_table(state.artifacts_by_cycle)
          // Delete Planner tables
          planner_index.delete_table(state.planner_tasks)
          planner_index.delete_table(state.planner_endeavours)
          slog.info(
            "narrative/librarian",
            "shutdown",
            "Librarian stopped",
            None,
          )
          Nil
        }

        // --- Narrative messages ---
        IndexEntry(entry:) -> {
          narrative_index.index_entry(
            state.entries,
            state.by_thread,
            state.by_date,
            state.by_keyword,
            state.by_recency,
            entry,
          )
          loop(state)
        }

        UpdateThreadIndex(index:) -> {
          loop(LibrarianState(..state, thread_index: index))
        }

        QueryDateRange(from:, to:, reply_to:) -> {
          let results =
            narrative_index.query_date_range(
              state.by_date,
              from,
              to,
              generate_date_range,
            )
          process.send(reply_to, results)
          loop(state)
        }

        QuerySearch(keyword:, reply_to:) -> {
          let results =
            narrative_index.search(state.entries, state.by_keyword, keyword)
          process.send(reply_to, results)
          loop(state)
        }

        QueryThread(thread_id:, reply_to:) -> {
          let results = narrative_index.lookup_bag(state.by_thread, thread_id)
          process.send(reply_to, results)
          loop(state)
        }

        QueryRecent(n:, reply_to:) -> {
          let results = narrative_index.last_n(state.by_recency, n)
          process.send(reply_to, results)
          loop(state)
        }

        QueryAll(reply_to:) -> {
          let all = narrative_index.all_values(state.entries)
          let sorted =
            list.sort(all, fn(a, b) { string.compare(a.timestamp, b.timestamp) })
          process.send(reply_to, sorted)
          loop(state)
        }

        QueryThreadIndex(reply_to:) -> {
          process.send(reply_to, state.thread_index)
          loop(state)
        }

        QueryThreadHeads(reply_to:) -> {
          let heads =
            list.filter_map(state.thread_index.threads, fn(ts: ThreadState) {
              narrative_index.lookup(state.entries, ts.last_cycle_id)
            })
          process.send(reply_to, heads)
          loop(state)
        }

        QueryByCycleId(cycle_id:, reply_to:) -> {
          let result = narrative_index.lookup(state.entries, cycle_id)
          process.send(reply_to, result)
          loop(state)
        }

        // --- CBR messages ---
        IndexCase(cbr_case:) -> {
          // Index in metadata ETS
          cbr_index.insert(state.cbr_cases, cbr_case.case_id, cbr_case)
          // Add to CaseBase (inverted index + optional embedding)
          let case_base = bridge.retain_case(state.case_base, cbr_case)
          loop(LibrarianState(..state, case_base:))
        }

        RetrieveCases(query:, reply_to:) -> {
          let metadata = cbr_index.build_metadata(state.cbr_cases)
          let today = get_date()
          let results =
            bridge.retrieve_cases_with_decay(
              state.case_base,
              query,
              metadata,
              state.cbr_config.weights,
              state.cbr_config.min_score,
              state.cbr_config.cbr_decay_half_life_days,
              today,
            )
          process.send(reply_to, results)
          loop(state)
        }

        QueryCaseById(case_id:, reply_to:) -> {
          let result = cbr_index.lookup(state.cbr_cases, case_id)
          process.send(reply_to, result)
          loop(state)
        }

        QueryAllCases(reply_to:) -> {
          let all = cbr_index.all_values(state.cbr_cases)
          process.send(reply_to, all)
          loop(state)
        }

        // --- CBR mutation messages ---
        UpdateCase(case_id:, updated_case:, reply_to:) -> {
          case cbr_index.lookup(state.cbr_cases, case_id) {
            Error(_) -> {
              process.send(reply_to, Error("Case not found: " <> case_id))
              loop(state)
            }
            Ok(_) -> {
              // Update metadata ETS
              cbr_index.insert(state.cbr_cases, case_id, updated_case)
              // Update CaseBase (remove old, retain new)
              let case_base = bridge.remove_case(state.case_base, case_id)
              let case_base = bridge.retain_case(case_base, updated_case)
              // Persist update to disk
              cbr_log.append(state.cbr_dir, updated_case)
              process.send(reply_to, Ok(Nil))
              loop(LibrarianState(..state, case_base:))
            }
          }
        }

        AnnotateCase(case_id:, annotation:, reply_to:) -> {
          case cbr_index.lookup(state.cbr_cases, case_id) {
            Error(_) -> {
              process.send(reply_to, Error("Case not found: " <> case_id))
              loop(state)
            }
            Ok(existing) -> {
              let updated =
                cbr_types.CbrCase(
                  ..existing,
                  outcome: cbr_types.CbrOutcome(
                    ..existing.outcome,
                    pitfalls: list.append(existing.outcome.pitfalls, [
                      annotation,
                    ]),
                  ),
                )
              cbr_index.insert(state.cbr_cases, case_id, updated)
              // Pitfalls don't affect field scoring — no CaseBase update needed.
              cbr_log.append(state.cbr_dir, updated)
              process.send(reply_to, Ok(Nil))
              loop(state)
            }
          }
        }

        SuppressCase(case_id:, reply_to:) -> {
          case cbr_index.lookup(state.cbr_cases, case_id) {
            Error(_) -> {
              process.send(reply_to, Error("Case not found: " <> case_id))
              loop(state)
            }
            Ok(existing) -> {
              // Mark as suppressed in metadata
              let suppressed =
                cbr_types.CbrCase(
                  ..existing,
                  outcome: cbr_types.CbrOutcome(
                    ..existing.outcome,
                    status: "suppressed",
                  ),
                )
              cbr_index.insert(state.cbr_cases, case_id, suppressed)
              // Remove from CaseBase (no longer retrievable)
              let case_base = bridge.remove_case(state.case_base, case_id)
              cbr_log.append(state.cbr_dir, suppressed)
              process.send(reply_to, Ok(Nil))
              loop(LibrarianState(..state, case_base:))
            }
          }
        }

        UnsuppressCase(case_id:, reply_to:) -> {
          case cbr_index.lookup(state.cbr_cases, case_id) {
            Error(_) -> {
              process.send(reply_to, Error("Case not found: " <> case_id))
              loop(state)
            }
            Ok(existing) -> {
              case existing.outcome.status == "suppressed" {
                False -> {
                  process.send(
                    reply_to,
                    Error("Case " <> case_id <> " is not suppressed"),
                  )
                  loop(state)
                }
                True -> {
                  // Restore status to the outcome's original (best guess: "success" or "failure")
                  let restored =
                    cbr_types.CbrCase(
                      ..existing,
                      outcome: cbr_types.CbrOutcome(
                        ..existing.outcome,
                        status: "restored",
                      ),
                    )
                  cbr_index.insert(state.cbr_cases, case_id, restored)
                  // Re-add to CaseBase for retrieval
                  let case_base = bridge.retain_case(state.case_base, restored)
                  cbr_log.append(state.cbr_dir, restored)
                  process.send(reply_to, Ok(Nil))
                  loop(LibrarianState(..state, case_base:))
                }
              }
            }
          }
        }

        BoostCase(case_id:, new_confidence:, reply_to:) -> {
          case cbr_index.lookup(state.cbr_cases, case_id) {
            Error(_) -> {
              process.send(reply_to, Error("Case not found: " <> case_id))
              loop(state)
            }
            Ok(existing) -> {
              // Clamp confidence to [0.0, 1.0]
              let clamped = float.min(1.0, float.max(0.0, new_confidence))
              let updated =
                cbr_types.CbrCase(
                  ..existing,
                  outcome: cbr_types.CbrOutcome(
                    ..existing.outcome,
                    confidence: clamped,
                  ),
                )
              cbr_index.insert(state.cbr_cases, case_id, updated)
              // Confidence doesn't affect field scoring — no CaseBase update needed.
              cbr_log.append(state.cbr_dir, updated)
              process.send(reply_to, Ok(Nil))
              loop(state)
            }
          }
        }

        UpdateCaseUsage(case_id:, success:) -> {
          case cbr_index.lookup(state.cbr_cases, case_id) {
            Error(_) -> loop(state)
            Ok(existing) -> {
              let old_stats =
                option.unwrap(
                  existing.usage_stats,
                  cbr_types.empty_usage_stats(),
                )
              let new_stats =
                cbr_types.CbrUsageStats(
                  retrieval_count: old_stats.retrieval_count + 1,
                  retrieval_success_count: case success {
                    True -> old_stats.retrieval_success_count + 1
                    False -> old_stats.retrieval_success_count
                  },
                  helpful_count: old_stats.helpful_count,
                  harmful_count: old_stats.harmful_count,
                )
              let updated =
                cbr_types.CbrCase(
                  ..existing,
                  usage_stats: option.Some(new_stats),
                )
              cbr_index.insert(state.cbr_cases, case_id, updated)
              cbr_log.append(state.cbr_dir, updated)
              loop(state)
            }
          }
        }

        // --- Facts messages ---
        IndexFact(fact:) -> {
          facts_index.index_fact(state.facts_by_key, state.facts_by_cycle, fact)
          loop(state)
        }

        QueryFactByKey(key:, reply_to:) -> {
          let result = facts_index.lookup(state.facts_by_key, key)
          process.send(reply_to, result)
          loop(state)
        }

        QueryFactsByCycle(cycle_id:, reply_to:) -> {
          let results = facts_index.lookup_bag(state.facts_by_cycle, cycle_id)
          process.send(reply_to, results)
          loop(state)
        }

        QueryAllFacts(reply_to:) -> {
          let all = facts_index.all_values(state.facts_by_key)
          process.send(reply_to, all)
          loop(state)
        }

        QueryFactsByKeyword(keyword:, reply_to:) -> {
          let results = facts_index.search(state.facts_by_key, keyword)
          process.send(reply_to, results)
          loop(state)
        }

        // --- Housekeeping messages ---
        RemoveCase(case_id:) -> {
          cbr_index.delete_key(state.cbr_cases, case_id)
          let case_base = bridge.remove_case(state.case_base, case_id)
          loop(LibrarianState(..state, case_base:))
        }

        SupersedeFact(fact:) -> {
          facts_index.index_fact(state.facts_by_key, state.facts_by_cycle, fact)
          loop(state)
        }

        // --- Scratchpad messages ---
        WriteAgentResult(cycle_id:, result:) -> {
          scratchpad_index.insert(state.cycle_scratchpad, cycle_id, result)
          loop(state)
        }

        ReadCycleResults(cycle_id:, reply_to:) -> {
          let results =
            scratchpad_index.lookup_bag(state.cycle_scratchpad, cycle_id)
          process.send(reply_to, results)
          loop(state)
        }

        ClearCycleScratchpad(cycle_id:) -> {
          scratchpad_index.delete_key(state.cycle_scratchpad, cycle_id)
          loop(state)
        }

        QueryThreadCount(reply_to:) -> {
          process.send(reply_to, list.length(state.thread_index.threads))
          loop(state)
        }

        QueryPersistentFactCount(reply_to:) -> {
          let all = facts_index.all_values(state.facts_by_key)
          let persistent =
            list.filter(all, fn(f) { f.scope == facts_types.Persistent })
          process.send(reply_to, list.length(persistent))
          loop(state)
        }

        QueryCaseCount(reply_to:) -> {
          let all = cbr_index.all_values(state.cbr_cases)
          process.send(reply_to, list.length(all))
          loop(state)
        }

        // --- DAG messages ---
        IndexNode(node:) -> {
          dag_index.index_node(
            state.dag_nodes,
            state.dag_by_parent,
            state.dag_by_date,
            node,
          )
          loop(state)
        }

        UpdateNode(node:) -> {
          dag_index.apply_update(
            state.dag_nodes,
            state.dag_by_parent,
            state.dag_by_date,
            node,
          )
          loop(state)
        }

        QueryNode(cycle_id:, reply_to:) -> {
          let result = dag_index.lookup(state.dag_nodes, cycle_id)
          process.send(reply_to, result)
          loop(state)
        }

        QueryChildren(parent_id:, reply_to:) -> {
          let results = dag_index.lookup_bag(state.dag_by_parent, parent_id)
          process.send(reply_to, results)
          loop(state)
        }

        QueryDayRoots(date:, reply_to:) -> {
          let all =
            dag_index.query_day(
              state.dag_nodes,
              state.dag_by_parent,
              state.dag_by_date,
              date,
            )
          let roots = list.filter(all, fn(n) { option.is_none(n.parent_id) })
          process.send(reply_to, roots)
          loop(state)
        }

        QueryDayAll(date:, reply_to:) -> {
          let all =
            dag_index.query_day(
              state.dag_nodes,
              state.dag_by_parent,
              state.dag_by_date,
              date,
            )
          process.send(reply_to, all)
          loop(state)
        }

        QueryNodeWithDescendants(cycle_id:, reply_to:) -> {
          let result = case dag_index.lookup(state.dag_nodes, cycle_id) {
            Error(_) -> Error(Nil)
            Ok(root) -> Ok(dag_index.build_subtree(state.dag_by_parent, root))
          }
          process.send(reply_to, result)
          loop(state)
        }

        QueryDayStats(date:, reply_to:) -> {
          let stats =
            dag_index.day_stats(
              state.dag_nodes,
              state.dag_by_parent,
              state.dag_by_date,
              date,
            )
          process.send(reply_to, stats)
          loop(state)
        }

        QueryToolActivity(date:, reply_to:) -> {
          let records =
            dag_index.tool_activity(
              state.dag_nodes,
              state.dag_by_parent,
              state.dag_by_date,
              date,
            )
          process.send(reply_to, records)
          loop(state)
        }

        // --- Scheduler cycle queries ---
        QuerySchedulerCycles(date:, reply_to:) -> {
          let all =
            dag_index.query_day(
              state.dag_nodes,
              state.dag_by_parent,
              state.dag_by_date,
              date,
            )
          let scheduler_only =
            list.filter(all, fn(n) { n.node_type == dag_types.SchedulerCycle })
          process.send(reply_to, scheduler_only)
          loop(state)
        }

        // --- Artifact operations ---
        IndexArtifact(meta:) -> {
          artifacts_index.index_meta(
            state.artifacts,
            state.artifacts_by_cycle,
            meta,
          )
          loop(state)
        }

        QueryArtifactsByCycle(cycle_id:, reply_to:) -> {
          let metas =
            artifacts_index.lookup_bag(state.artifacts_by_cycle, cycle_id)
          process.send(reply_to, metas)
          loop(state)
        }

        RetrieveArtifactContent(artifact_id:, stored_at:, reply_to:) -> {
          let date = string.slice(stored_at, 0, 10)
          let result =
            artifacts_log.read_content(state.artifacts_dir, artifact_id, date)
          process.send(reply_to, result)
          loop(state)
        }

        QueryArtifactById(artifact_id:, reply_to:) -> {
          let result = artifacts_index.lookup_one(state.artifacts, artifact_id)
          process.send(reply_to, result)
          loop(state)
        }

        // --- Trim operations (Housekeeper) ---
        TrimNarrativeWindow(cutoff_date:, reply_to:) -> {
          let count =
            narrative_index.trim(
              state.entries,
              state.by_thread,
              state.by_date,
              state.by_keyword,
              state.by_recency,
              cutoff_date,
            )
          process.send(reply_to, count)
          loop(state)
        }

        TrimDagWindow(cutoff_date:, reply_to:) -> {
          let count = dag_index.trim(state.dag_nodes, cutoff_date)
          process.send(reply_to, count)
          loop(state)
        }

        TrimArtifactWindow(cutoff_date:, reply_to:) -> {
          let count = artifacts_index.trim(state.artifacts, cutoff_date)
          process.send(reply_to, count)
          loop(state)
        }

        // --- Captures messages (MVP commitment tracker) ---
        InitCaptures(captures_dir:) -> {
          let pending = captures_log.pending_from_disk(captures_dir)
          slog.info(
            "librarian",
            "init_captures",
            "Loaded "
              <> int.to_string(list.length(pending))
              <> " pending capture(s) from disk",
            None,
          )
          loop(
            LibrarianState(
              ..state,
              captures_dir: captures_dir,
              pending_captures: pending,
            ),
          )
        }

        IndexCapture(capture:) -> {
          let updated =
            list.filter(state.pending_captures, fn(c) { c.id != capture.id })
          loop(LibrarianState(..state, pending_captures: [capture, ..updated]))
        }

        RemoveCapture(id:) -> {
          let updated =
            list.filter(state.pending_captures, fn(c) { c.id != id })
          loop(LibrarianState(..state, pending_captures: updated))
        }

        QueryPendingCaptureCount(reply_to:) -> {
          process.send(reply_to, list.length(state.pending_captures))
          loop(state)
        }

        QueryPendingCaptures(reply_to:) -> {
          process.send(reply_to, state.pending_captures)
          loop(state)
        }

        // --- Deputies messages ---
        IndexActiveDeputy(meta:) -> {
          let updated =
            list.filter(state.active_deputies, fn(d) { d.id != meta.id })
          loop(LibrarianState(..state, active_deputies: [meta, ..updated]))
        }

        RemoveActiveDeputy(id:) -> {
          let updated = list.filter(state.active_deputies, fn(d) { d.id != id })
          loop(LibrarianState(..state, active_deputies: updated))
        }

        AppendRecentDeputy(record:) -> {
          let updated = [record, ..state.recent_deputies]
          let capped = list.take(updated, recent_deputies_cap)
          loop(LibrarianState(..state, recent_deputies: capped))
        }

        QueryActiveDeputies(reply_to:) -> {
          process.send(reply_to, state.active_deputies)
          loop(state)
        }

        QueryActiveDeputyById(id:, reply_to:) -> {
          let result = list.find(state.active_deputies, fn(d) { d.id == id })
          process.send(reply_to, result)
          loop(state)
        }

        QueryRecentDeputies(reply_to:) -> {
          process.send(reply_to, state.recent_deputies)
          loop(state)
        }

        QueryActiveDeputyCount(reply_to:) -> {
          process.send(reply_to, list.length(state.active_deputies))
          loop(state)
        }

        // --- Planner messages ---
        NotifyTaskOp(op:) -> {
          planner_index.apply_task_op(state.planner_tasks, op)
          loop(state)
        }

        NotifyEndeavourOp(op:) -> {
          planner_index.apply_endeavour_op(state.planner_endeavours, op)
          loop(state)
        }

        QueryActiveTasks(reply_to:) -> {
          let all = planner_index.task_all_values(state.planner_tasks)
          let active =
            list.filter(all, fn(t) {
              t.status == planner_types.Pending
              || t.status == planner_types.Active
            })
          process.send(reply_to, active)
          loop(state)
        }

        QueryTaskById(task_id:, reply_to:) -> {
          let result = planner_index.task_lookup(state.planner_tasks, task_id)
          process.send(reply_to, result)
          loop(state)
        }

        QueryEndeavourById(endeavour_id:, reply_to:) -> {
          let result =
            planner_index.endeavour_lookup(
              state.planner_endeavours,
              endeavour_id,
            )
          process.send(reply_to, result)
          loop(state)
        }

        QueryAllEndeavours(reply_to:) -> {
          let all = planner_index.endeavour_all_values(state.planner_endeavours)
          process.send(reply_to, all)
          loop(state)
        }

        LoadByCycleIds(cycle_ids:, reply_to:) -> {
          let entries =
            list.filter_map(cycle_ids, fn(cid) {
              narrative_index.lookup(state.entries, cid)
            })
          process.send(reply_to, entries)
          loop(state)
        }
      }
  }
}

// ---------------------------------------------------------------------------
// Narrative date-range helper — passed into narrative_index.query_date_range
// as a callback so the sub-module stays free of the date-math FFI.
// ---------------------------------------------------------------------------

/// Generate a list of "YYYY-MM-DD" strings from `from` to `to` inclusive.
fn generate_date_range(from: String, to: String) -> List(String) {
  case string.compare(from, to) {
    order.Gt -> []
    _ -> {
      let days = days_between(from, to)
      generate_offsets(0, days)
      |> list.map(fn(offset) { add_days_to_date(from, offset) })
    }
  }
}

// ---------------------------------------------------------------------------
// CBR query helpers live in `narrative/librarian/cbr_index`.
// ---------------------------------------------------------------------------

/// Generate a list [from..to] inclusive.
fn generate_offsets(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..generate_offsets(from + 1, to)]
  }
}

// ---------------------------------------------------------------------------
// ETS-vs-disk reconciliation (runs on idle timeout, every ~60s)
// ---------------------------------------------------------------------------
// JSONL on disk is the source of truth; ETS is a cache populated by
// fire-and-forget notifications from the Archivist. If a notification is
// lost (mailbox full, race condition), the entry exists on disk but not in
// ETS. This periodic check detects and repairs such gaps by delegating to
// each per-store sub-module.

fn reconcile_ets_with_disk(state: LibrarianState) -> LibrarianState {
  let today = get_date()
  narrative_index.reconcile(
    state.entries,
    state.by_thread,
    state.by_date,
    state.by_keyword,
    state.by_recency,
    state.narrative_dir,
    today,
    count_lines,
  )
  let case_base =
    cbr_index.reconcile(
      state.cbr_cases,
      state.case_base,
      state.cbr_dir,
      today,
      count_lines,
    )
  let state = LibrarianState(..state, case_base:)
  facts_index.reconcile(
    state.facts_by_key,
    state.facts_by_cycle,
    state.facts_dir,
    today,
    count_lines,
  )
  artifacts_index.reconcile(
    state.artifacts,
    state.artifacts_by_cycle,
    state.artifacts_dir,
    today,
    count_lines,
  )
  state
}

// ---------------------------------------------------------------------------
// Synchronous query helpers — Planner
// ---------------------------------------------------------------------------

/// Query active tasks (Pending + Active). Blocks until reply.
pub fn get_active_tasks(
  librarian: Subject(LibrarianMessage),
) -> List(planner_types.PlannerTask) {
  let reply_to = process.new_subject()
  process.send(librarian, QueryActiveTasks(reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(tasks) -> tasks
    Error(_) -> {
      slog.warn(
        "librarian",
        "get_active_tasks",
        "Timeout waiting for reply",
        None,
      )
      []
    }
  }
}

/// Query a single task by ID. Blocks until reply.
pub fn get_task_by_id(
  librarian: Subject(LibrarianMessage),
  task_id: String,
) -> Result(planner_types.PlannerTask, Nil) {
  let reply_to = process.new_subject()
  process.send(librarian, QueryTaskById(task_id:, reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(result) -> result
    Error(_) -> {
      slog.warn(
        "librarian",
        "get_task_by_id",
        "Timeout waiting for reply",
        None,
      )
      Error(Nil)
    }
  }
}

/// Query a single endeavour by ID. Blocks until reply.
/// Short alias for get_endeavour_by_id.
pub fn get_endeavour(
  librarian: Subject(LibrarianMessage),
  endeavour_id: String,
) -> Result(planner_types.Endeavour, Nil) {
  get_endeavour_by_id(librarian, endeavour_id)
}

pub fn get_endeavour_by_id(
  librarian: Subject(LibrarianMessage),
  endeavour_id: String,
) -> Result(planner_types.Endeavour, Nil) {
  let reply_to = process.new_subject()
  process.send(librarian, QueryEndeavourById(endeavour_id:, reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(result) -> result
    Error(_) -> {
      slog.warn(
        "librarian",
        "get_endeavour_by_id",
        "Timeout waiting for reply",
        None,
      )
      Error(Nil)
    }
  }
}

/// Query all endeavours. Blocks until reply.
pub fn get_all_endeavours(
  librarian: Subject(LibrarianMessage),
) -> List(planner_types.Endeavour) {
  let reply_to = process.new_subject()
  process.send(librarian, QueryAllEndeavours(reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(endeavours) -> endeavours
    Error(_) -> {
      slog.warn(
        "librarian",
        "get_all_endeavours",
        "Timeout waiting for reply",
        None,
      )
      []
    }
  }
}

/// Notify the Librarian of a task operation (fire-and-forget).
pub fn notify_task_op(
  librarian: Subject(LibrarianMessage),
  op: planner_types.TaskOp,
) -> Nil {
  process.send(librarian, NotifyTaskOp(op:))
}

/// Notify the Librarian of an endeavour operation (fire-and-forget).
pub fn notify_endeavour_op(
  librarian: Subject(LibrarianMessage),
  op: planner_types.EndeavourOp,
) -> Nil {
  process.send(librarian, NotifyEndeavourOp(op:))
}

/// Load narrative entries by cycle IDs. Blocks until reply.
pub fn load_by_cycle_ids(
  librarian: Subject(LibrarianMessage),
  cycle_ids: List(String),
) -> List(NarrativeEntry) {
  let reply_to = process.new_subject()
  process.send(librarian, LoadByCycleIds(cycle_ids:, reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(entries) -> entries
    Error(_) -> {
      slog.warn(
        "librarian",
        "load_by_cycle_ids",
        "Timeout waiting for reply",
        None,
      )
      []
    }
  }
}

// ---------------------------------------------------------------------------
// Synchronous query helpers — Captures (MVP commitment tracker)
// ---------------------------------------------------------------------------

/// Populate the pending-captures list from disk. Call once after start.
pub fn init_captures(
  librarian: Subject(LibrarianMessage),
  captures_dir: String,
) -> Nil {
  process.send(librarian, InitCaptures(captures_dir:))
}

/// Notify the Librarian to index a newly-created pending capture
/// (fire-and-forget).
pub fn notify_new_capture(
  librarian: Subject(LibrarianMessage),
  capture: captures_types.Capture,
) -> Nil {
  process.send(librarian, IndexCapture(capture:))
}

/// Notify the Librarian to drop a capture from the pending list
/// (fire-and-forget). Called after clarify/dismiss/expire.
pub fn notify_remove_capture(
  librarian: Subject(LibrarianMessage),
  id: String,
) -> Nil {
  process.send(librarian, RemoveCapture(id:))
}

/// Count of pending captures. Blocks until reply. Returns 0 on timeout.
pub fn get_pending_capture_count(librarian: Subject(LibrarianMessage)) -> Int {
  let reply_to = process.new_subject()
  process.send(librarian, QueryPendingCaptureCount(reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(n) -> n
    Error(_) -> {
      slog.warn(
        "librarian",
        "get_pending_capture_count",
        "Timeout waiting for reply",
        None,
      )
      0
    }
  }
}

/// Full list of pending captures. Blocks until reply. Returns [] on timeout.
pub fn get_pending_captures(
  librarian: Subject(LibrarianMessage),
) -> List(captures_types.Capture) {
  let reply_to = process.new_subject()
  process.send(librarian, QueryPendingCaptures(reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(captures) -> captures
    Error(_) -> {
      slog.warn(
        "librarian",
        "get_pending_captures",
        "Timeout waiting for reply",
        None,
      )
      []
    }
  }
}

// ---------------------------------------------------------------------------
// Synchronous query helpers — Deputies (MVP Phase 1)
// ---------------------------------------------------------------------------

/// Register a newly-spawned deputy (fire-and-forget).
pub fn notify_active_deputy(
  librarian: Subject(LibrarianMessage),
  meta: ActiveDeputyMeta,
) -> Nil {
  process.send(librarian, IndexActiveDeputy(meta:))
}

/// Deregister an active deputy — called on completion/failure/kill.
pub fn notify_remove_active_deputy(
  librarian: Subject(LibrarianMessage),
  id: String,
) -> Nil {
  process.send(librarian, RemoveActiveDeputy(id:))
}

/// Append a completed deputy record to the recent-deputies ring.
pub fn notify_recent_deputy(
  librarian: Subject(LibrarianMessage),
  record: RecentDeputyRecord,
) -> Nil {
  process.send(librarian, AppendRecentDeputy(record:))
}

/// Count of currently in-flight deputies. Timeout returns 0.
pub fn get_active_deputy_count(librarian: Subject(LibrarianMessage)) -> Int {
  let reply_to = process.new_subject()
  process.send(librarian, QueryActiveDeputyCount(reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(n) -> n
    Error(_) -> 0
  }
}

/// Full list of active deputies. Timeout returns [].
pub fn get_active_deputies(
  librarian: Subject(LibrarianMessage),
) -> List(ActiveDeputyMeta) {
  let reply_to = process.new_subject()
  process.send(librarian, QueryActiveDeputies(reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(list) -> list
    Error(_) -> []
  }
}

/// Recently-completed deputies (ring buffer). Timeout returns [].
pub fn get_recent_deputies(
  librarian: Subject(LibrarianMessage),
) -> List(RecentDeputyRecord) {
  let reply_to = process.new_subject()
  process.send(librarian, QueryRecentDeputies(reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(list) -> list
    Error(_) -> []
  }
}

/// Look up an active deputy by id. Error when no match or timeout.
pub fn get_active_deputy_by_id(
  librarian: Subject(LibrarianMessage),
  id: String,
) -> Result(ActiveDeputyMeta, Nil) {
  let reply_to = process.new_subject()
  process.send(librarian, QueryActiveDeputyById(id:, reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(result) -> result
    Error(_) -> Error(Nil)
  }
}
