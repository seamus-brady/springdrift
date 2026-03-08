//// Librarian — supervised actor that owns the ETS-backed narrative query layer.
////
//// The Librarian retrieves, ranks, and surfaces relevant memories from the
//// narrative log. It owns ETS tables that serve as a fast query cache over
//// the immutable JSONL files on disk. On startup it replays JSONL files to
//// populate the indexes. The Archivist notifies the Librarian when new
//// entries are written so the cache stays current.
////
//// ETS tables:
////   - entries (set)           — cycle_id → NarrativeEntry
////   - by_thread (bag)         — thread_id → NarrativeEntry
////   - by_date (bag)           — "YYYY-MM-DD" → NarrativeEntry
////   - by_keyword (bag)        — keyword (lowercased) → NarrativeEntry
////   - by_recency (ordered)    — timestamp → NarrativeEntry

import gleam/erlang/process.{type Subject}
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
// FFI — ETS operations
// ---------------------------------------------------------------------------

pub type EtsTable

@external(erlang, "store_ffi", "new_table")
fn new_table(name: String, table_type: String) -> EtsTable

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

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

pub type LibrarianMessage {
  /// Notify the Librarian that a new entry was written to JSONL.
  /// The Librarian indexes it in ETS.
  IndexEntry(entry: NarrativeEntry)
  /// Update the in-memory thread index.
  UpdateThreadIndex(index: ThreadIndex)
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
  /// Shutdown
  Shutdown
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

type LibrarianState {
  LibrarianState(
    self: Subject(LibrarianMessage),
    dir: String,
    entries: EtsTable,
    by_thread: EtsTable,
    by_date: EtsTable,
    by_keyword: EtsTable,
    by_recency: EtsTable,
    thread_index: ThreadIndex,
  )
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start the Librarian actor. Replays JSONL files to populate ETS indexes.
/// `max_files` limits startup loading (0 = all files).
/// Returns a Subject for sending queries and index notifications.
pub fn start(dir: String, max_files: Int) -> Subject(LibrarianMessage) {
  let setup: Subject(Subject(LibrarianMessage)) = process.new_subject()
  process.spawn_unlinked(fn() {
    let self: Subject(LibrarianMessage) = process.new_subject()
    process.send(setup, self)

    // Create ETS tables (owned by this process)
    let entries_table = new_table("narrative_entries", "set")
    let by_thread_table = new_table("narrative_by_thread", "bag")
    let by_date_table = new_table("narrative_by_date", "bag")
    let by_keyword_table = new_table("narrative_by_keyword", "bag")
    let by_recency_table = new_table("narrative_by_recency", "ordered_set")

    let state =
      LibrarianState(
        self:,
        dir:,
        entries: entries_table,
        by_thread: by_thread_table,
        by_date: by_date_table,
        by_keyword: by_keyword_table,
        by_recency: by_recency_table,
        thread_index: ThreadIndex(threads: []),
      )

    // Replay JSONL files
    let state = replay_from_disk(state, max_files)

    // Load thread index
    let thread_index = narrative_log.load_thread_index(dir)
    let state = LibrarianState(..state, thread_index:)

    let count = ets_table_size(entries_table)
    slog.info(
      "narrative/librarian",
      "start",
      "Librarian ready — "
        <> string.inspect(count)
        <> " entries indexed from "
        <> dir,
      None,
    )

    // Enter message loop
    loop(state)
  })

  // Wait for the actor to send back its Subject
  let assert Ok(subj) = process.receive(setup, 30_000)
  subj
}

// ---------------------------------------------------------------------------
// Synchronous query helpers (for callers)
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
    Error(_) -> []
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
    Error(_) -> []
  }
}

/// Get thread index. Blocks until reply.
pub fn load_thread_index(librarian: Subject(LibrarianMessage)) -> ThreadIndex {
  let reply_to = process.new_subject()
  process.send(librarian, QueryThreadIndex(reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(idx) -> idx
    Error(_) -> ThreadIndex(threads: [])
  }
}

/// Get all entries. Blocks until reply.
pub fn load_all(librarian: Subject(LibrarianMessage)) -> List(NarrativeEntry) {
  let reply_to = process.new_subject()
  process.send(librarian, QueryAll(reply_to:))
  case process.receive(reply_to, 5000) {
    Ok(entries) -> entries
    Error(_) -> []
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
    Error(_) -> []
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
    Error(_) -> []
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
    Error(_) -> []
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
          ets_delete_table(state.entries)
          ets_delete_table(state.by_thread)
          ets_delete_table(state.by_date)
          ets_delete_table(state.by_keyword)
          ets_delete_table(state.by_recency)
          slog.info(
            "narrative/librarian",
            "shutdown",
            "Librarian stopped",
            None,
          )
          Nil
        }

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
      }
  }
}

// ---------------------------------------------------------------------------
// Query implementations
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
// Indexing
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

fn extract_date(timestamp: String) -> String {
  case string.split(timestamp, "T") {
    [date, ..] -> date
    _ -> timestamp
  }
}

// ---------------------------------------------------------------------------
// Replay from disk
// ---------------------------------------------------------------------------

fn replay_from_disk(state: LibrarianState, max_files: Int) -> LibrarianState {
  case simplifile.read_directory(state.dir) {
    Error(_) -> state
    Ok(files) -> {
      let jsonl_files =
        files
        |> list.filter(fn(f) { string.ends_with(f, ".jsonl") })
        |> list.sort(string.compare)

      let limited = case max_files > 0 {
        True -> {
          let len = list.length(jsonl_files)
          case len > max_files {
            True -> list.drop(jsonl_files, len - max_files)
            False -> jsonl_files
          }
        }
        False -> jsonl_files
      }

      list.each(limited, fn(f) {
        let date = string.drop_end(f, 6)
        let entries = narrative_log.load_date(state.dir, date)
        list.each(entries, fn(entry) { index_entry(state, entry) })
      })

      state
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn merge_unique_entries(
  a: List(NarrativeEntry),
  b: List(NarrativeEntry),
) -> List(NarrativeEntry) {
  let ids = list.map(a, fn(e) { e.cycle_id })
  let unique_b = list.filter(b, fn(e) { !list.contains(ids, e.cycle_id) })
  list.append(a, unique_b)
}
