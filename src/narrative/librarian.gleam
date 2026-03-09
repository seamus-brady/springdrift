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
import cbr/log as cbr_log
import cbr/types as cbr_types
import facts/log as facts_log
import facts/types as facts_types
import gleam/erlang/process.{type Subject}
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

pub type EtsTable

@external(erlang, "store_ffi", "new_unique_table")
fn new_table(name: String, table_type: String) -> EtsTable

// Narrative-typed operations
@external(erlang, "store_ffi", "insert")
fn ets_insert(table: EtsTable, key: String, value: NarrativeEntry) -> Nil

@external(erlang, "store_ffi", "lookup")
fn ets_lookup(table: EtsTable, key: String) -> Result(NarrativeEntry, Nil)

@external(erlang, "store_ffi", "lookup_bag")
fn ets_lookup_bag(table: EtsTable, key: String) -> List(NarrativeEntry)

@external(erlang, "store_ffi", "all_values")
fn ets_all_values(table: EtsTable) -> List(NarrativeEntry)

@external(erlang, "store_ffi", "last_n")
fn ets_last_n(table: EtsTable, n: Int) -> List(NarrativeEntry)

@external(erlang, "store_ffi", "delete_table")
fn ets_delete_table(table: EtsTable) -> Nil

@external(erlang, "store_ffi", "table_size")
fn ets_table_size(table: EtsTable) -> Int

// CBR-typed operations (same Erlang functions, different Gleam types)
@external(erlang, "store_ffi", "insert")
fn cbr_insert(table: EtsTable, key: String, value: cbr_types.CbrCase) -> Nil

@external(erlang, "store_ffi", "lookup")
fn cbr_lookup(table: EtsTable, key: String) -> Result(cbr_types.CbrCase, Nil)

@external(erlang, "store_ffi", "lookup_bag")
fn cbr_lookup_bag(table: EtsTable, key: String) -> List(cbr_types.CbrCase)

@external(erlang, "store_ffi", "all_values")
fn cbr_all_values(table: EtsTable) -> List(cbr_types.CbrCase)

@external(erlang, "store_ffi", "table_size")
fn cbr_table_size(table: EtsTable) -> Int

// Facts-typed operations
@external(erlang, "store_ffi", "insert")
fn fact_insert(
  table: EtsTable,
  key: String,
  value: facts_types.MemoryFact,
) -> Nil

@external(erlang, "store_ffi", "lookup")
fn fact_lookup(
  table: EtsTable,
  key: String,
) -> Result(facts_types.MemoryFact, Nil)

@external(erlang, "store_ffi", "lookup_bag")
fn fact_lookup_bag(table: EtsTable, key: String) -> List(facts_types.MemoryFact)

@external(erlang, "store_ffi", "all_values")
fn fact_all_values(table: EtsTable) -> List(facts_types.MemoryFact)

@external(erlang, "store_ffi", "table_size")
fn fact_table_size(table: EtsTable) -> Int

@external(erlang, "store_ffi", "delete_key")
fn fact_delete_key(table: EtsTable, key: String) -> Nil

// AgentResult-typed operations (scratchpad)
@external(erlang, "store_ffi", "insert")
fn result_insert(
  table: EtsTable,
  key: String,
  value: agent_types.AgentResult,
) -> Nil

@external(erlang, "store_ffi", "lookup_bag")
fn result_lookup_bag(
  table: EtsTable,
  key: String,
) -> List(agent_types.AgentResult)

@external(erlang, "store_ffi", "delete_key")
fn result_delete_key(table: EtsTable, key: String) -> Nil

// CBR delete
@external(erlang, "store_ffi", "delete_key")
fn cbr_delete_key(table: EtsTable, key: String) -> Nil

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
    entries: EtsTable,
    by_thread: EtsTable,
    by_date: EtsTable,
    by_keyword: EtsTable,
    by_recency: EtsTable,
    thread_index: ThreadIndex,
    // CBR ETS tables
    cbr_cases: EtsTable,
    cbr_by_intent: EtsTable,
    cbr_by_keyword: EtsTable,
    cbr_by_domain: EtsTable,
    // Facts
    facts_dir: String,
    facts_by_key: EtsTable,
    facts_by_cycle: EtsTable,
    // Scratchpad — agent results per cycle (ephemeral, bag)
    cycle_scratchpad: EtsTable,
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
  max_files: Int,
) -> Subject(LibrarianMessage) {
  let setup: Subject(Subject(LibrarianMessage)) = process.new_subject()
  process.spawn_unlinked(fn() {
    let self: Subject(LibrarianMessage) = process.new_subject()
    process.send(setup, self)

    // Create narrative ETS tables
    let entries_table = new_table("narrative_entries", "set")
    let by_thread_table = new_table("narrative_by_thread", "bag")
    let by_date_table = new_table("narrative_by_date", "bag")
    let by_keyword_table = new_table("narrative_by_keyword", "bag")
    let by_recency_table = new_table("narrative_by_recency", "ordered_set")

    // Create CBR ETS tables
    let cbr_cases_table = new_table("cbr_cases", "set")
    let cbr_intent_table = new_table("cbr_by_intent", "bag")
    let cbr_keyword_table = new_table("cbr_by_keyword", "bag")
    let cbr_domain_table = new_table("cbr_by_domain", "bag")

    // Create Facts ETS tables
    let facts_key_table = new_table("facts_by_key", "set")
    let facts_cycle_table = new_table("facts_by_cycle", "bag")

    // Create scratchpad table (bag — multiple results per cycle)
    let scratchpad_table = new_table("cycle_scratchpad", "bag")

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
  let assert Ok(subj) = process.receive(setup, 30_000)
  subj
}

/// Start a supervised Librarian. If the Librarian crashes, it is automatically
/// restarted (up to `max_restarts` times). Returns a Subject that always points
/// to the current Librarian instance via an indirection process.
pub fn start_supervised(
  narrative_dir: String,
  cbr_dir: String,
  facts_dir: String,
  max_files: Int,
  max_restarts: Int,
) -> Subject(LibrarianMessage) {
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
      max_files,
      max_restarts,
      0,
      proxy_subj,
    )
  })
  let assert Ok(proxy_subj) = process.receive(setup, 30_000)
  proxy_subj
}

fn librarian_supervisor_loop(
  narrative_dir: String,
  cbr_dir: String,
  facts_dir: String,
  max_files: Int,
  max_restarts: Int,
  restart_count: Int,
  proxy: Subject(LibrarianMessage),
) -> Nil {
  // Start a fresh librarian
  let librarian = start(narrative_dir, cbr_dir, facts_dir, max_files)

  // Forward messages and monitor the librarian process
  forward_loop(
    librarian,
    proxy,
    narrative_dir,
    cbr_dir,
    facts_dir,
    max_files,
    max_restarts,
    restart_count,
  )
}

fn forward_loop(
  librarian: Subject(LibrarianMessage),
  proxy: Subject(LibrarianMessage),
  narrative_dir: String,
  cbr_dir: String,
  facts_dir: String,
  max_files: Int,
  max_restarts: Int,
  restart_count: Int,
) -> Nil {
  // Select on proxy messages to forward, with a periodic liveness check
  case process.receive(proxy, 5000) {
    Ok(msg) -> {
      process.send(librarian, msg)
      forward_loop(
        librarian,
        proxy,
        narrative_dir,
        cbr_dir,
        facts_dir,
        max_files,
        max_restarts,
        restart_count,
      )
    }
    Error(_) -> {
      // Timeout — check if librarian is still alive by sending a ping-like query
      let test_subj: Subject(List(NarrativeEntry)) = process.new_subject()
      process.send(librarian, QueryRecent(n: 0, reply_to: test_subj))
      case process.receive(test_subj, 2000) {
        Ok(_) ->
          forward_loop(
            librarian,
            proxy,
            narrative_dir,
            cbr_dir,
            facts_dir,
            max_files,
            max_restarts,
            restart_count,
          )
        Error(_) -> {
          // Librarian is dead
          case restart_count < max_restarts {
            True -> {
              slog.warn(
                "librarian",
                "supervisor",
                "Librarian unresponsive, restarting (attempt "
                  <> string.inspect(restart_count + 1)
                  <> ")",
                None,
              )
              librarian_supervisor_loop(
                narrative_dir,
                cbr_dir,
                facts_dir,
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

// ---------------------------------------------------------------------------
// Message loop
// ---------------------------------------------------------------------------

fn loop(state: LibrarianState) -> Nil {
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
          ets_delete_table(state.cbr_cases)
          ets_delete_table(state.cbr_by_intent)
          ets_delete_table(state.cbr_by_keyword)
          ets_delete_table(state.cbr_by_domain)
          // Delete Facts tables
          ets_delete_table(state.facts_by_key)
          ets_delete_table(state.facts_by_cycle)
          // Delete scratchpad
          ets_delete_table(state.cycle_scratchpad)
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
  let all = ets_all_values(state.entries)
  list.filter(all, fn(entry) {
    let date = extract_date(entry.timestamp)
    case string.compare(date, from), string.compare(date, to) {
      order.Lt, _ -> False
      _, order.Gt -> False
      _, _ -> True
    }
  })
  |> list.sort(fn(a, b) { string.compare(a.timestamp, b.timestamp) })
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

  // Stage 2: Score each candidate
  let scored =
    list.map(candidates, fn(c) {
      let score = score_case_symbolic(c, query)
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

/// Rough age estimate in days by comparing YYYY-MM-DD date strings.
fn estimate_age_days(case_date: String, today: String) -> Int {
  // Parse year, month, day from both dates
  let cy = parse_int_slice(case_date, 0, 4)
  let cm = parse_int_slice(case_date, 5, 7)
  let cd = parse_int_slice(case_date, 8, 10)
  let ty = parse_int_slice(today, 0, 4)
  let tm = parse_int_slice(today, 5, 7)
  let td = parse_int_slice(today, 8, 10)
  // Approximate: (year_diff * 365) + (month_diff * 30) + day_diff
  { ty - cy } * 365 + { tm - cm } * 30 + { td - cd }
}

fn parse_int_slice(s: String, from: Int, to: Int) -> Int {
  let slice = string.slice(s, from, to - from)
  case int.parse(slice) {
    Ok(n) -> n
    Error(_) -> 0
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
  let facts = facts_log.load_all(state.facts_dir)
  list.each(facts, fn(f) { index_fact(state, f) })
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
  let ids = list.map(a, fn(e) { e.cycle_id })
  let unique_b = list.filter(b, fn(e) { !list.contains(ids, e.cycle_id) })
  list.append(a, unique_b)
}

fn merge_unique_cases(
  a: List(cbr_types.CbrCase),
  b: List(cbr_types.CbrCase),
) -> List(cbr_types.CbrCase) {
  let ids = list.map(a, fn(c) { c.case_id })
  let unique_b = list.filter(b, fn(c) { !list.contains(ids, c.case_id) })
  list.append(a, unique_b)
}
