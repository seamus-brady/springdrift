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
//// CBR ETS tables:
////   - cbr_cases (set)         — case_id → CbrCase
////   - cbr_by_intent (bag)     — intent → CbrCase
////   - cbr_by_keyword (bag)    — keyword (lowercased) → CbrCase
////   - cbr_by_domain (bag)     — domain → CbrCase
////
//// Facts ETS tables:
////   - facts_by_key (set)      — key → MemoryFact (current value)
////   - facts_by_cycle (bag)    — cycle_id → MemoryFact

import agent/types as agent_types
import artifacts/log as artifacts_log
import artifacts/types as artifacts_types
import cbr/log as cbr_log
import cbr/types as cbr_types
import cycle_log
import dag/types as dag_types
import embedding/client as embedding_client
import facts/log as facts_log
import facts/types as facts_types
import gleam/dict
import gleam/erlang/process.{type Pid, type Subject}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/string
import narrative/log as narrative_log
import narrative/types.{
  type NarrativeEntry, type ThreadIndex, type ThreadState, ThreadIndex,
}
import simplifile
import slog

// ---------------------------------------------------------------------------
// FFI — ETS operations (typed per value type)
// ---------------------------------------------------------------------------

// Domain-specific opaque ETS table types prevent cross-domain misuse.
// Each domain has its own type so the compiler catches table/value mismatches.
pub type NarrativeTable

pub type CbrTable

pub type FactTable

pub type ScratchpadTable

pub type DagTable

pub type ArtifactTable

@external(erlang, "springdrift_ffi", "days_between")
fn days_between(date_a: String, date_b: String) -> Int

@external(erlang, "springdrift_ffi", "mailbox_size")
fn get_mailbox_size() -> Int

@external(erlang, "springdrift_ffi", "add_days")
fn add_days_to_date(date: String, days: Int) -> String

// Table constructors — one per domain
@external(erlang, "store_ffi", "new_unique_table")
fn new_narrative_table(name: String, table_type: String) -> NarrativeTable

@external(erlang, "store_ffi", "new_unique_table")
fn new_cbr_table(name: String, table_type: String) -> CbrTable

@external(erlang, "store_ffi", "new_unique_table")
fn new_fact_table(name: String, table_type: String) -> FactTable

@external(erlang, "store_ffi", "new_unique_table")
fn new_scratchpad_table(name: String, table_type: String) -> ScratchpadTable

@external(erlang, "store_ffi", "new_unique_table")
fn new_dag_table(name: String, table_type: String) -> DagTable

@external(erlang, "store_ffi", "new_unique_table")
fn new_artifact_table(name: String, table_type: String) -> ArtifactTable

// Narrative-typed operations
@external(erlang, "store_ffi", "insert")
fn ets_insert(table: NarrativeTable, key: String, value: NarrativeEntry) -> Nil

@external(erlang, "store_ffi", "lookup")
fn ets_lookup(table: NarrativeTable, key: String) -> Result(NarrativeEntry, Nil)

@external(erlang, "store_ffi", "lookup_bag")
fn ets_lookup_bag(table: NarrativeTable, key: String) -> List(NarrativeEntry)

@external(erlang, "store_ffi", "all_values")
fn ets_all_values(table: NarrativeTable) -> List(NarrativeEntry)

@external(erlang, "store_ffi", "last_n")
fn ets_last_n(table: NarrativeTable, n: Int) -> List(NarrativeEntry)

@external(erlang, "store_ffi", "delete_table")
fn ets_delete_table(table: NarrativeTable) -> Nil

@external(erlang, "store_ffi", "table_size")
fn ets_table_size(table: NarrativeTable) -> Int

// Generic delete/size for other domains
@external(erlang, "store_ffi", "delete_table")
fn cbr_delete_table(table: CbrTable) -> Nil

@external(erlang, "store_ffi", "delete_table")
fn fact_delete_table(table: FactTable) -> Nil

@external(erlang, "store_ffi", "delete_table")
fn scratchpad_delete_table(table: ScratchpadTable) -> Nil

@external(erlang, "store_ffi", "delete_table")
fn dag_delete_table(table: DagTable) -> Nil

@external(erlang, "store_ffi", "delete_table")
fn artifact_delete_table(table: ArtifactTable) -> Nil

// CBR-typed operations
@external(erlang, "store_ffi", "insert")
fn cbr_insert(table: CbrTable, key: String, value: cbr_types.CbrCase) -> Nil

@external(erlang, "store_ffi", "lookup")
fn cbr_lookup(table: CbrTable, key: String) -> Result(cbr_types.CbrCase, Nil)

@external(erlang, "store_ffi", "lookup_bag")
fn cbr_lookup_bag(table: CbrTable, key: String) -> List(cbr_types.CbrCase)

@external(erlang, "store_ffi", "all_values")
fn cbr_all_values(table: CbrTable) -> List(cbr_types.CbrCase)

@external(erlang, "store_ffi", "table_size")
fn cbr_table_size(table: CbrTable) -> Int

@external(erlang, "store_ffi", "delete_key")
fn cbr_delete_key(table: CbrTable, key: String) -> Nil

// Facts-typed operations
@external(erlang, "store_ffi", "insert")
fn fact_insert(
  table: FactTable,
  key: String,
  value: facts_types.MemoryFact,
) -> Nil

@external(erlang, "store_ffi", "lookup")
fn fact_lookup(
  table: FactTable,
  key: String,
) -> Result(facts_types.MemoryFact, Nil)

@external(erlang, "store_ffi", "lookup_bag")
fn fact_lookup_bag(
  table: FactTable,
  key: String,
) -> List(facts_types.MemoryFact)

@external(erlang, "store_ffi", "all_values")
fn fact_all_values(table: FactTable) -> List(facts_types.MemoryFact)

@external(erlang, "store_ffi", "table_size")
fn fact_table_size(table: FactTable) -> Int

@external(erlang, "store_ffi", "delete_key")
fn fact_delete_key(table: FactTable, key: String) -> Nil

// AgentResult-typed operations (scratchpad)
@external(erlang, "store_ffi", "insert")
fn result_insert(
  table: ScratchpadTable,
  key: String,
  value: agent_types.AgentResult,
) -> Nil

@external(erlang, "store_ffi", "lookup_bag")
fn result_lookup_bag(
  table: ScratchpadTable,
  key: String,
) -> List(agent_types.AgentResult)

@external(erlang, "store_ffi", "delete_key")
fn result_delete_key(table: ScratchpadTable, key: String) -> Nil

// DAG-typed operations (CycleNode)
@external(erlang, "store_ffi", "insert")
fn dag_insert(table: DagTable, key: String, value: dag_types.CycleNode) -> Nil

@external(erlang, "store_ffi", "lookup")
fn dag_lookup(table: DagTable, key: String) -> Result(dag_types.CycleNode, Nil)

@external(erlang, "store_ffi", "lookup_bag")
fn dag_lookup_bag(table: DagTable, key: String) -> List(dag_types.CycleNode)

// Artifact-typed operations
@external(erlang, "store_ffi", "insert")
fn artifact_insert(
  table: ArtifactTable,
  key: String,
  value: artifacts_types.ArtifactMeta,
) -> Nil

@external(erlang, "store_ffi", "lookup")
fn artifact_lookup_one(
  table: ArtifactTable,
  key: String,
) -> Result(artifacts_types.ArtifactMeta, Nil)

@external(erlang, "store_ffi", "lookup_bag")
fn artifact_lookup_bag(
  table: ArtifactTable,
  key: String,
) -> List(artifacts_types.ArtifactMeta)

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

  /// Shutdown
  Shutdown
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
    entries: NarrativeTable,
    by_thread: NarrativeTable,
    by_date: NarrativeTable,
    by_keyword: NarrativeTable,
    by_recency: NarrativeTable,
    thread_index: ThreadIndex,
    // CBR ETS tables
    cbr_cases: CbrTable,
    cbr_by_intent: CbrTable,
    cbr_by_keyword: CbrTable,
    cbr_by_domain: CbrTable,
    // Facts
    facts_dir: String,
    facts_by_key: FactTable,
    facts_by_cycle: FactTable,
    // Scratchpad — agent results per cycle (ephemeral, bag)
    cycle_scratchpad: ScratchpadTable,
    // DAG ETS tables
    dag_nodes: DagTable,
    dag_by_parent: DagTable,
    dag_by_date: DagTable,
    // Artifact ETS tables
    artifacts_dir: String,
    artifacts: ArtifactTable,
    artifacts_by_cycle: ArtifactTable,
  )
}

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
  max_files: Int,
) -> Subject(LibrarianMessage) {
  let #(subj, _pid) =
    start_with_pid(narrative_dir, cbr_dir, facts_dir, artifacts_dir, max_files)
  subj
}

/// Start the Librarian actor, returning both the Subject and the Pid.
/// Used by the supervisor to set up a process monitor.
fn start_with_pid(
  narrative_dir: String,
  cbr_dir: String,
  facts_dir: String,
  artifacts_dir: String,
  max_files: Int,
) -> #(Subject(LibrarianMessage), Pid) {
  let setup: Subject(Subject(LibrarianMessage)) = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let self: Subject(LibrarianMessage) = process.new_subject()
      process.send(setup, self)

      // Create narrative ETS tables
      let entries_table = new_narrative_table("narrative_entries", "set")
      let by_thread_table = new_narrative_table("narrative_by_thread", "bag")
      let by_date_table = new_narrative_table("narrative_by_date", "bag")
      let by_keyword_table = new_narrative_table("narrative_by_keyword", "bag")
      let by_recency_table =
        new_narrative_table("narrative_by_recency", "ordered_set")

      // Create CBR ETS tables
      let cbr_cases_table = new_cbr_table("cbr_cases", "set")
      let cbr_intent_table = new_cbr_table("cbr_by_intent", "bag")
      let cbr_keyword_table = new_cbr_table("cbr_by_keyword", "bag")
      let cbr_domain_table = new_cbr_table("cbr_by_domain", "bag")

      // Create Facts ETS tables
      let facts_key_table = new_fact_table("facts_by_key", "set")
      let facts_cycle_table = new_fact_table("facts_by_cycle", "bag")

      // Create scratchpad table (bag — multiple results per cycle)
      let scratchpad_table = new_scratchpad_table("cycle_scratchpad", "bag")

      // Create DAG ETS tables
      let dag_nodes_table = new_dag_table("dag_nodes", "set")
      let dag_parent_table = new_dag_table("dag_by_parent", "bag")
      let dag_date_table = new_dag_table("dag_by_date", "bag")

      // Create Artifact ETS tables
      let artifacts_table = new_artifact_table("artifacts", "set")
      let artifacts_cycle_table =
        new_artifact_table("artifacts_by_cycle", "bag")

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
          cbr_by_intent: cbr_intent_table,
          cbr_by_keyword: cbr_keyword_table,
          cbr_by_domain: cbr_domain_table,
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
        )

      // Replay narrative JSONL files
      let state = replay_narrative_from_disk(state, max_files)

      // Load thread index
      let thread_index = narrative_log.load_thread_index(narrative_dir)
      let state = LibrarianState(..state, thread_index:)

      // Replay CBR JSONL files
      replay_cbr_from_disk(state, max_files)

      // Replay facts from disk
      replay_facts_from_disk(state)

      // Replay DAG from cycle log
      replay_dag_from_cycle_log(state, max_files)

      // Replay artifacts from disk
      replay_artifacts_from_disk(state, max_files)

      let narrative_count = ets_table_size(entries_table)
      let cbr_count = cbr_table_size(cbr_cases_table)
      let facts_count = fact_table_size(facts_key_table)
      slog.info(
        "narrative/librarian",
        "start",
        "Librarian ready — "
          <> string.inspect(narrative_count)
          <> " narrative entries, "
          <> string.inspect(cbr_count)
          <> " CBR cases, "
          <> string.inspect(facts_count)
          <> " facts",
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
  max_files: Int,
  max_restarts: Int,
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
      max_files,
      max_restarts,
      0,
      proxy_subj,
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
  max_files: Int,
  max_restarts: Int,
  restart_count: Int,
  proxy: Subject(LibrarianMessage),
) -> Nil {
  // Start a fresh librarian, getting both Subject and Pid
  let #(librarian, pid) =
    start_with_pid(narrative_dir, cbr_dir, facts_dir, artifacts_dir, max_files)

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
    max_files,
    max_restarts,
    restart_count,
    proxy,
  )
}

fn forward_loop(
  librarian: Subject(LibrarianMessage),
  sel: process.Selector(SupervisorEvent),
  narrative_dir: String,
  cbr_dir: String,
  facts_dir: String,
  artifacts_dir: String,
  max_files: Int,
  max_restarts: Int,
  restart_count: Int,
  proxy: Subject(LibrarianMessage),
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
        max_files,
        max_restarts,
        restart_count,
        proxy,
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
            max_files,
            max_restarts,
            restart_count + 1,
            proxy,
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

const mailbox_warn_threshold = 50

fn loop(state: LibrarianState) -> Nil {
  // Periodic mailbox backpressure check
  let mbox_size = get_mailbox_size()
  case mbox_size > mailbox_warn_threshold {
    True ->
      slog.warn(
        "librarian",
        "loop",
        "Mailbox backpressure: "
          <> int.to_string(mbox_size)
          <> " messages queued (threshold="
          <> int.to_string(mailbox_warn_threshold)
          <> ")",
        None,
      )
    False -> Nil
  }
  case process.receive(state.self, 60_000) {
    Error(_) -> {
      // Timeout — just keep looping (idle heartbeat)
      loop(state)
    }
    Ok(msg) ->
      case msg {
        Shutdown -> {
          // Delete narrative tables
          ets_delete_table(state.entries)
          ets_delete_table(state.by_thread)
          ets_delete_table(state.by_date)
          ets_delete_table(state.by_keyword)
          ets_delete_table(state.by_recency)
          // Delete CBR tables
          cbr_delete_table(state.cbr_cases)
          cbr_delete_table(state.cbr_by_intent)
          cbr_delete_table(state.cbr_by_keyword)
          cbr_delete_table(state.cbr_by_domain)
          // Delete Facts tables
          fact_delete_table(state.facts_by_key)
          fact_delete_table(state.facts_by_cycle)
          // Delete scratchpad
          scratchpad_delete_table(state.cycle_scratchpad)
          // Delete DAG tables
          dag_delete_table(state.dag_nodes)
          dag_delete_table(state.dag_by_parent)
          dag_delete_table(state.dag_by_date)
          // Delete Artifact tables
          artifact_delete_table(state.artifacts)
          artifact_delete_table(state.artifacts_by_cycle)
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
          index_entry(state, entry)
          loop(state)
        }

        UpdateThreadIndex(index:) -> {
          loop(LibrarianState(..state, thread_index: index))
        }

        QueryDateRange(from:, to:, reply_to:) -> {
          let results = do_query_date_range(state, from, to)
          process.send(reply_to, results)
          loop(state)
        }

        QuerySearch(keyword:, reply_to:) -> {
          let results = do_search(state, keyword)
          process.send(reply_to, results)
          loop(state)
        }

        QueryThread(thread_id:, reply_to:) -> {
          let results = ets_lookup_bag(state.by_thread, thread_id)
          process.send(reply_to, results)
          loop(state)
        }

        QueryRecent(n:, reply_to:) -> {
          let results = ets_last_n(state.by_recency, n)
          process.send(reply_to, results)
          loop(state)
        }

        QueryAll(reply_to:) -> {
          let all = ets_all_values(state.entries)
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
              ets_lookup(state.entries, ts.last_cycle_id)
            })
          process.send(reply_to, heads)
          loop(state)
        }

        QueryByCycleId(cycle_id:, reply_to:) -> {
          let result = ets_lookup(state.entries, cycle_id)
          process.send(reply_to, result)
          loop(state)
        }

        // --- CBR messages ---
        IndexCase(cbr_case:) -> {
          index_case(state, cbr_case)
          loop(state)
        }

        RetrieveCases(query:, reply_to:) -> {
          let results = do_retrieve_cases(state, query)
          process.send(reply_to, results)
          loop(state)
        }

        QueryCaseById(case_id:, reply_to:) -> {
          let result = cbr_lookup(state.cbr_cases, case_id)
          process.send(reply_to, result)
          loop(state)
        }

        QueryAllCases(reply_to:) -> {
          let all = cbr_all_values(state.cbr_cases)
          process.send(reply_to, all)
          loop(state)
        }

        // --- Facts messages ---
        IndexFact(fact:) -> {
          index_fact(state, fact)
          loop(state)
        }

        QueryFactByKey(key:, reply_to:) -> {
          let result = fact_lookup(state.facts_by_key, key)
          process.send(reply_to, result)
          loop(state)
        }

        QueryFactsByCycle(cycle_id:, reply_to:) -> {
          let results = fact_lookup_bag(state.facts_by_cycle, cycle_id)
          process.send(reply_to, results)
          loop(state)
        }

        QueryAllFacts(reply_to:) -> {
          let all = fact_all_values(state.facts_by_key)
          process.send(reply_to, all)
          loop(state)
        }

        QueryFactsByKeyword(keyword:, reply_to:) -> {
          let results = do_search_facts(state, keyword)
          process.send(reply_to, results)
          loop(state)
        }

        // --- Housekeeping messages ---
        RemoveCase(case_id:) -> {
          remove_case_from_indices(state, case_id)
          loop(state)
        }

        SupersedeFact(fact:) -> {
          index_fact(state, fact)
          loop(state)
        }

        // --- Scratchpad messages ---
        WriteAgentResult(cycle_id:, result:) -> {
          result_insert(state.cycle_scratchpad, cycle_id, result)
          loop(state)
        }

        ReadCycleResults(cycle_id:, reply_to:) -> {
          let results = result_lookup_bag(state.cycle_scratchpad, cycle_id)
          process.send(reply_to, results)
          loop(state)
        }

        ClearCycleScratchpad(cycle_id:) -> {
          result_delete_key(state.cycle_scratchpad, cycle_id)
          loop(state)
        }

        QueryThreadCount(reply_to:) -> {
          process.send(reply_to, list.length(state.thread_index.threads))
          loop(state)
        }

        QueryPersistentFactCount(reply_to:) -> {
          let all = fact_all_values(state.facts_by_key)
          let persistent =
            list.filter(all, fn(f) { f.scope == facts_types.Persistent })
          process.send(reply_to, list.length(persistent))
          loop(state)
        }

        QueryCaseCount(reply_to:) -> {
          let all = cbr_all_values(state.cbr_cases)
          process.send(reply_to, list.length(all))
          loop(state)
        }

        // --- DAG messages ---
        IndexNode(node:) -> {
          index_dag_node(state, node)
          loop(state)
        }

        UpdateNode(node:) -> {
          index_dag_node(state, node)
          loop(state)
        }

        QueryNode(cycle_id:, reply_to:) -> {
          let result = dag_lookup(state.dag_nodes, cycle_id)
          process.send(reply_to, result)
          loop(state)
        }

        QueryChildren(parent_id:, reply_to:) -> {
          let results = dag_lookup_bag(state.dag_by_parent, parent_id)
          process.send(reply_to, results)
          loop(state)
        }

        QueryDayRoots(date:, reply_to:) -> {
          let all = do_query_dag_day(state, date)
          let roots = list.filter(all, fn(n) { option.is_none(n.parent_id) })
          process.send(reply_to, roots)
          loop(state)
        }

        QueryDayAll(date:, reply_to:) -> {
          let all = do_query_dag_day(state, date)
          process.send(reply_to, all)
          loop(state)
        }

        QueryNodeWithDescendants(cycle_id:, reply_to:) -> {
          let result = case dag_lookup(state.dag_nodes, cycle_id) {
            Error(_) -> Error(Nil)
            Ok(root) -> Ok(build_subtree(state, root))
          }
          process.send(reply_to, result)
          loop(state)
        }

        QueryDayStats(date:, reply_to:) -> {
          let stats = compute_day_stats(state, date)
          process.send(reply_to, stats)
          loop(state)
        }

        QueryToolActivity(date:, reply_to:) -> {
          let records = compute_tool_activity(state, date)
          process.send(reply_to, records)
          loop(state)
        }

        // --- Artifact operations ---
        IndexArtifact(meta:) -> {
          index_artifact_meta(state, meta)
          loop(state)
        }

        QueryArtifactsByCycle(cycle_id:, reply_to:) -> {
          let metas = artifact_lookup_bag(state.artifacts_by_cycle, cycle_id)
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
          let result = artifact_lookup_one(state.artifacts, artifact_id)
          process.send(reply_to, result)
          loop(state)
        }
      }
  }
}

// ---------------------------------------------------------------------------
// Narrative query implementations
// ---------------------------------------------------------------------------

fn do_query_date_range(
  state: LibrarianState,
  from: String,
  to: String,
) -> List(NarrativeEntry) {
  // Use the by_date bag index instead of scanning all entries.
  // Generate each date in [from, to] and look up entries per date.
  let dates = generate_date_range(from, to)
  list.flat_map(dates, fn(date) { ets_lookup_bag(state.by_date, date) })
  |> list.sort(fn(a, b) { string.compare(a.timestamp, b.timestamp) })
}

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

fn do_search(state: LibrarianState, keyword: String) -> List(NarrativeEntry) {
  let lower = string.lowercase(keyword)
  let by_kw = ets_lookup_bag(state.by_keyword, lower)
  let all = ets_all_values(state.entries)
  let by_summary =
    list.filter(all, fn(entry) {
      string.contains(string.lowercase(entry.summary), lower)
    })
  merge_unique_entries(by_kw, by_summary)
}

// ---------------------------------------------------------------------------
// CBR query implementation — two-stage symbolic retrieval
// ---------------------------------------------------------------------------

fn do_retrieve_cases(
  state: LibrarianState,
  query: cbr_types.CbrQuery,
) -> List(cbr_types.ScoredCase) {
  // Stage 1: ETS pre-filter — intent match ∪ keyword overlap
  let by_intent = cbr_lookup_bag(state.cbr_by_intent, query.intent)
  let by_keywords =
    list.flat_map(query.keywords, fn(kw) {
      cbr_lookup_bag(state.cbr_by_keyword, string.lowercase(kw))
    })
  let candidates = merge_unique_cases(by_intent, by_keywords)

  // Filter out stale bag entries — only keep cases still in the primary table
  let candidates =
    list.filter(candidates, fn(c) {
      case cbr_lookup(state.cbr_cases, c.case_id) {
        Ok(_) -> True
        Error(_) -> False
      }
    })

  // If no candidates from indices, fall back to all cases
  let candidates = case candidates {
    [] -> cbr_all_values(state.cbr_cases)
    _ -> candidates
  }

  // Stage 2: Score each candidate (hybrid when embeddings available)
  let scored =
    list.map(candidates, fn(c) {
      let score = score_case(c, query)
      cbr_types.ScoredCase(score:, cbr_case: c)
    })

  // Filter by minimum score and sort descending
  scored
  |> list.filter(fn(sc) { sc.score >. 0.1 })
  |> list.sort(fn(a, b) {
    case a.score >. b.score {
      True -> order.Lt
      False ->
        case a.score <. b.score {
          True -> order.Gt
          False -> order.Eq
        }
    }
  })
  |> list.take(query.max_results)
}

/// Hybrid scoring: when both query and case have embeddings, blend
/// cosine similarity (0.40) with symbolic (0.60). Otherwise pure symbolic.
fn score_case(c: cbr_types.CbrCase, query: cbr_types.CbrQuery) -> Float {
  let symbolic = score_case_symbolic(c, query)
  case query.embedding, c.embedding {
    Some(q_emb), [_, ..] -> {
      let cosine = embedding_client.cosine_similarity(q_emb, c.embedding)
      // Clamp cosine to [0, 1] for scoring
      let clamped = float.max(0.0, float.min(1.0, cosine))
      { symbolic *. 0.6 } +. { clamped *. 0.4 }
    }
    _, _ -> symbolic
  }
}

/// Symbolic scoring fallback (no embeddings).
/// Weights: intent=0.35, keyword_jaccard=0.25, entity_jaccard=0.20,
///          domain=0.15, recency=0.05
fn score_case_symbolic(c: cbr_types.CbrCase, query: cbr_types.CbrQuery) -> Float {
  let intent_score = case c.problem.intent == query.intent {
    True -> 1.0
    False -> 0.0
  }

  let keyword_score =
    jaccard(
      list.map(c.problem.keywords, string.lowercase),
      list.map(query.keywords, string.lowercase),
    )

  let entity_score =
    jaccard(
      list.map(c.problem.entities, string.lowercase),
      list.map(query.entities, string.lowercase),
    )

  let domain_score = case
    string.lowercase(c.problem.domain) == string.lowercase(query.domain)
  {
    True -> 1.0
    False -> 0.0
  }

  // Recency score: compare case timestamp against current date.
  // Recent cases (today) score 1.0, decaying to 0.0 over 30 days.
  let recency_score = compute_recency(c.timestamp)

  { intent_score *. 0.35 }
  +. { keyword_score *. 0.25 }
  +. { entity_score *. 0.2 }
  +. { domain_score *. 0.15 }
  +. { recency_score *. 0.05 }
}

/// Jaccard similarity: |A ∩ B| / |A ∪ B|
fn jaccard(a: List(String), b: List(String)) -> Float {
  case a, b {
    [], _ -> 0.0
    _, [] -> 0.0
    _, _ -> {
      let intersection =
        list.filter(a, fn(x) { list.contains(b, x) })
        |> list.length()
      let union_size = list.length(a) + list.length(b) - intersection
      case union_size {
        0 -> 0.0
        n -> int.to_float(intersection) /. int.to_float(n)
      }
    }
  }
}

/// Compute recency score from a timestamp string (ISO 8601 or YYYY-MM-DD prefix).
/// Returns 1.0 for today, decaying linearly to 0.0 over 30 days.
fn compute_recency(timestamp: String) -> Float {
  let case_date = string.slice(timestamp, 0, 10)
  let today = get_date()
  case case_date == today {
    True -> 1.0
    False -> {
      // Compare date strings lexicographically as a rough age approximation.
      // Dates older than 30 days get 0.0; we approximate by checking a few
      // reference dates via the FFI.
      let age_days = estimate_age_days(case_date, today)
      let decay = 1.0 -. { int.to_float(age_days) /. 30.0 }
      case decay <. 0.0 {
        True -> 0.0
        False -> decay
      }
    }
  }
}

/// Exact age in days between two YYYY-MM-DD date strings using Erlang calendar.
fn estimate_age_days(case_date: String, today: String) -> Int {
  days_between(case_date, today)
}

/// Generate a list [from..to] inclusive.
fn generate_offsets(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..generate_offsets(from + 1, to)]
  }
}

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

// ---------------------------------------------------------------------------
// Narrative indexing
// ---------------------------------------------------------------------------

fn index_entry(state: LibrarianState, entry: NarrativeEntry) -> Nil {
  // Primary: cycle_id → entry
  ets_insert(state.entries, entry.cycle_id, entry)

  // Thread index
  case entry.thread {
    Some(t) -> ets_insert(state.by_thread, t.thread_id, entry)
    None -> Nil
  }

  // Date index
  let date = extract_date(entry.timestamp)
  ets_insert(state.by_date, date, entry)

  // Keyword index (lowercased)
  list.each(entry.keywords, fn(kw) {
    ets_insert(state.by_keyword, string.lowercase(kw), entry)
  })

  // Recency index
  ets_insert(state.by_recency, entry.timestamp, entry)
}

// ---------------------------------------------------------------------------
// CBR indexing
// ---------------------------------------------------------------------------

fn index_case(state: LibrarianState, c: cbr_types.CbrCase) -> Nil {
  // Primary: case_id → case
  cbr_insert(state.cbr_cases, c.case_id, c)

  // Intent index
  case c.problem.intent {
    "" -> Nil
    intent -> cbr_insert(state.cbr_by_intent, intent, c)
  }

  // Domain index
  case c.problem.domain {
    "" -> Nil
    domain -> cbr_insert(state.cbr_by_domain, domain, c)
  }

  // Keyword index (lowercased)
  list.each(c.problem.keywords, fn(kw) {
    cbr_insert(state.cbr_by_keyword, string.lowercase(kw), c)
  })
}

fn remove_case_from_indices(state: LibrarianState, case_id: String) -> Nil {
  // Remove from primary set
  cbr_delete_key(state.cbr_cases, case_id)
  // Note: bag tables don't support targeted removal by value in our FFI,
  // but since we check case_id during retrieval/scoring, stale bag entries
  // will be filtered out naturally when the primary lookup fails.
  // A full re-index could be done periodically if needed.
  slog.debug(
    "narrative/librarian",
    "remove_case",
    "Removed case " <> case_id <> " from primary index",
    None,
  )
}

// ---------------------------------------------------------------------------
// Facts indexing
// ---------------------------------------------------------------------------

fn index_fact(state: LibrarianState, fact: facts_types.MemoryFact) -> Nil {
  case fact.operation {
    facts_types.Write -> {
      // Update current value for this key (overwrites previous)
      fact_insert(state.facts_by_key, fact.key, fact)
      // Also index by cycle
      fact_insert(state.facts_by_cycle, fact.cycle_id, fact)
    }
    facts_types.Clear -> {
      // Remove from current facts
      fact_delete_key(state.facts_by_key, fact.key)
      // Still index by cycle for provenance
      fact_insert(state.facts_by_cycle, fact.cycle_id, fact)
    }
    facts_types.Superseded -> {
      // The superseded record itself doesn't change current facts —
      // the new Write that caused the supersession already updated facts_by_key
      fact_insert(state.facts_by_cycle, fact.cycle_id, fact)
    }
  }
}

fn do_search_facts(
  state: LibrarianState,
  keyword: String,
) -> List(facts_types.MemoryFact) {
  let lower = string.lowercase(keyword)
  let all = fact_all_values(state.facts_by_key)
  list.filter(all, fn(f) {
    string.contains(string.lowercase(f.key), lower)
    || string.contains(string.lowercase(f.value), lower)
  })
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn extract_date(timestamp: String) -> String {
  case string.split(timestamp, "T") {
    [date, ..] -> date
    _ -> timestamp
  }
}

// ---------------------------------------------------------------------------
// Replay from disk
// ---------------------------------------------------------------------------

fn replay_narrative_from_disk(
  state: LibrarianState,
  max_files: Int,
) -> LibrarianState {
  case simplifile.read_directory(state.narrative_dir) {
    Error(_) -> state
    Ok(files) -> {
      let jsonl_files =
        files
        |> list.filter(fn(f) { string.ends_with(f, ".jsonl") })
        |> list.sort(string.compare)

      let limited = limit_files(jsonl_files, max_files)

      list.each(limited, fn(f) {
        let date = string.drop_end(f, 6)
        let entries = narrative_log.load_date(state.narrative_dir, date)
        list.each(entries, fn(entry) { index_entry(state, entry) })
      })

      state
    }
  }
}

fn replay_cbr_from_disk(state: LibrarianState, max_files: Int) -> Nil {
  case simplifile.read_directory(state.cbr_dir) {
    Error(_) -> Nil
    Ok(files) -> {
      let jsonl_files =
        files
        |> list.filter(fn(f) { string.ends_with(f, ".jsonl") })
        |> list.sort(string.compare)

      let limited = limit_files(jsonl_files, max_files)

      list.each(limited, fn(f) {
        let date = string.drop_end(f, 6)
        let cases = cbr_log.load_date(state.cbr_dir, date)
        list.each(cases, fn(c) { index_case(state, c) })
      })
    }
  }
}

fn replay_facts_from_disk(state: LibrarianState) -> Nil {
  // Facts always load ALL files — no max_files windowing.
  // Full history is needed for memory_trace_fact, inspect_cycle, and correct
  // supersession resolution across the entire fact timeline.
  let facts = facts_log.load_all(state.facts_dir)
  list.each(facts, fn(f) { index_fact(state, f) })
}

fn index_artifact_meta(
  state: LibrarianState,
  meta: artifacts_types.ArtifactMeta,
) -> Nil {
  artifact_insert(state.artifacts, meta.artifact_id, meta)
  artifact_insert(state.artifacts_by_cycle, meta.cycle_id, meta)
}

fn replay_artifacts_from_disk(state: LibrarianState, max_files: Int) -> Nil {
  case simplifile.read_directory(state.artifacts_dir) {
    Error(_) -> Nil
    Ok(files) -> {
      let artifact_files =
        files
        |> list.filter(fn(f) { string.ends_with(f, ".jsonl") })
        |> list.sort(string.compare)

      let limited = limit_files(artifact_files, max_files)

      list.each(limited, fn(f) {
        // File format: artifacts-YYYY-MM-DD.jsonl
        let date =
          f
          |> string.drop_start(10)
          |> string.drop_end(6)
        let metas = artifacts_log.load_date_meta(state.artifacts_dir, date)
        list.each(metas, fn(m) { index_artifact_meta(state, m) })
      })
    }
  }
}

fn limit_files(files: List(String), max_files: Int) -> List(String) {
  case max_files > 0 {
    True -> {
      let len = list.length(files)
      case len > max_files {
        True -> list.drop(files, len - max_files)
        False -> files
      }
    }
    False -> files
  }
}

fn merge_unique_entries(
  a: List(NarrativeEntry),
  b: List(NarrativeEntry),
) -> List(NarrativeEntry) {
  let id_set =
    list.fold(a, dict.new(), fn(d, e) { dict.insert(d, e.cycle_id, Nil) })
  let unique_b = list.filter(b, fn(e) { !dict.has_key(id_set, e.cycle_id) })
  list.append(a, unique_b)
}

fn merge_unique_cases(
  a: List(cbr_types.CbrCase),
  b: List(cbr_types.CbrCase),
) -> List(cbr_types.CbrCase) {
  let id_set =
    list.fold(a, dict.new(), fn(d, c) { dict.insert(d, c.case_id, Nil) })
  let unique_b = list.filter(b, fn(c) { !dict.has_key(id_set, c.case_id) })
  list.append(a, unique_b)
}

// ---------------------------------------------------------------------------
// DAG — indexing, querying, replay
// ---------------------------------------------------------------------------

fn index_dag_node(state: LibrarianState, node: dag_types.CycleNode) -> Nil {
  // Primary index: cycle_id → CycleNode
  dag_insert(state.dag_nodes, node.cycle_id, node)

  // Parent edge: parent_id → CycleNode (for traversal)
  let parent_key = case node.parent_id {
    Some(pid) -> pid
    None -> "root"
  }
  dag_insert(state.dag_by_parent, parent_key, node)

  // Date index: extract YYYY-MM-DD from timestamp
  let date_key = string.slice(node.timestamp, 0, 10)
  dag_insert(state.dag_by_date, date_key, node)
  Nil
}

fn do_query_dag_day(
  state: LibrarianState,
  date: String,
) -> List(dag_types.CycleNode) {
  let results = dag_lookup_bag(state.dag_by_date, date)
  case results {
    [] -> {
      // Lazy load: try loading from cycle log file for this date
      let cycles = cycle_log.load_cycles_for_date(date)
      case cycles {
        [] -> []
        _ -> {
          let nodes = list.map(cycles, cycle_data_to_node)
          list.each(nodes, fn(n) { index_dag_node(state, n) })
          nodes
        }
      }
    }
    found -> found
  }
}

fn build_subtree(
  state: LibrarianState,
  root: dag_types.CycleNode,
) -> dag_types.DagSubtree {
  let children = dag_lookup_bag(state.dag_by_parent, root.cycle_id)
  let child_trees = list.map(children, fn(c) { build_subtree(state, c) })
  dag_types.DagSubtree(root:, children: child_trees)
}

fn compute_day_stats(state: LibrarianState, date: String) -> dag_types.DayStats {
  let all = do_query_dag_day(state, date)
  let success_count =
    list.count(all, fn(n) { n.outcome == dag_types.NodeSuccess })
  let partial_count =
    list.count(all, fn(n) { n.outcome == dag_types.NodePartial })
  let failure_count =
    list.count(all, fn(n) {
      case n.outcome {
        dag_types.NodeFailure(_) -> True
        _ -> False
      }
    })
  let total_tokens_in = list.fold(all, 0, fn(acc, n) { acc + n.tokens_in })
  let total_tokens_out = list.fold(all, 0, fn(acc, n) { acc + n.tokens_out })
  let total_duration_ms = list.fold(all, 0, fn(acc, n) { acc + n.duration_ms })

  // Tool failure rate
  let all_tools = list.flat_map(all, fn(n) { n.tool_calls })
  let total_tool_calls = list.length(all_tools)
  let failed_tool_calls = list.count(all_tools, fn(t) { !t.success })
  let tool_failure_rate = case total_tool_calls {
    0 -> 0.0
    n -> int.to_float(failed_tool_calls) /. int.to_float(n)
  }

  // Unique models
  let models_used =
    list.map(all, fn(n) { n.model })
    |> list.unique()

  // All gate decisions
  let gate_decisions = list.flat_map(all, fn(n) { n.dprime_gates })

  dag_types.DayStats(
    date:,
    total_cycles: list.length(all),
    success_count:,
    partial_count:,
    failure_count:,
    total_tokens_in:,
    total_tokens_out:,
    total_duration_ms:,
    tool_failure_rate:,
    models_used:,
    gate_decisions:,
  )
}

fn compute_tool_activity(
  state: LibrarianState,
  date: String,
) -> List(dag_types.ToolActivityRecord) {
  let all = do_query_dag_day(state, date)
  // Collect all (tool_name, success, cycle_id) triples
  let triples =
    list.flat_map(all, fn(node) {
      list.map(node.tool_calls, fn(t) { #(t.name, t.success, node.cycle_id) })
    })
  // Group by tool name using Dict for O(n) aggregation
  let records_dict =
    list.fold(triples, dict.new(), fn(acc, triple) {
      let #(name, success, cycle_id) = triple
      case dict.get(acc, name) {
        Error(_) ->
          dict.insert(
            acc,
            name,
            dag_types.ToolActivityRecord(
              name:,
              total_calls: 1,
              success_count: case success {
                True -> 1
                False -> 0
              },
              failure_count: case success {
                True -> 0
                False -> 1
              },
              cycle_ids: [cycle_id],
            ),
          )
        Ok(rec) ->
          dict.insert(
            acc,
            name,
            dag_types.ToolActivityRecord(
              ..rec,
              total_calls: rec.total_calls + 1,
              success_count: rec.success_count
                + case success {
                  True -> 1
                  False -> 0
                },
              failure_count: rec.failure_count
                + case success {
                  True -> 0
                  False -> 1
                },
              cycle_ids: case list.contains(rec.cycle_ids, cycle_id) {
                True -> rec.cycle_ids
                False -> [cycle_id, ..rec.cycle_ids]
              },
            ),
          )
      }
    })
  dict.values(records_dict)
}

fn replay_dag_from_cycle_log(state: LibrarianState, max_files: Int) -> Nil {
  let dir = cycle_log.log_directory()
  case simplifile.read_directory(dir) {
    Error(_) -> Nil
    Ok(files) -> {
      let jsonl_files =
        files
        |> list.filter(fn(f) { string.ends_with(f, ".jsonl") })
        |> list.sort(string.compare)

      let limited = limit_files(jsonl_files, max_files)

      list.each(limited, fn(f) {
        let date = string.drop_end(f, 6)
        let cycles = cycle_log.load_cycles_for_date(date)
        list.each(cycles, fn(c) {
          let node = cycle_data_to_node(c)
          index_dag_node(state, node)
        })
      })
    }
  }
}

fn cycle_data_to_node(c: cycle_log.CycleData) -> dag_types.CycleNode {
  let outcome = case c.response_text {
    "" -> dag_types.NodeFailure(reason: "no response")
    _ -> dag_types.NodeSuccess
  }
  let node_type = case c.parent_id {
    Some(_) -> dag_types.AgentCycle
    None -> dag_types.CognitiveCycle
  }
  let tool_calls =
    list.map(c.tool_names, fn(name) {
      dag_types.ToolSummary(name:, success: True, error: None)
    })
  dag_types.CycleNode(
    cycle_id: c.cycle_id,
    parent_id: c.parent_id,
    node_type:,
    timestamp: c.timestamp,
    outcome:,
    model: "",
    complexity: option.unwrap(c.complexity, ""),
    tool_calls:,
    dprime_gates: [],
    tokens_in: c.input_tokens,
    tokens_out: c.output_tokens,
    duration_ms: 0,
    agent_output: None,
  )
}
