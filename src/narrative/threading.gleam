//// Thread assignment — overlap scoring and thread index management.
////
//// Each NarrativeEntry is scored against existing threads. If the best
//// match exceeds the threshold, the entry joins that thread; otherwise
//// a new thread is created. Overlap weights: location=3, domain=2, keyword=1.

import cycle_log
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import narrative/librarian.{type LibrarianMessage}
import narrative/log as narrative_log
import narrative/types.{
  type NarrativeEntry, type ThreadIndex, type ThreadState, NarrativeEntry,
  Thread, ThreadIndex, ThreadState,
}

// ---------------------------------------------------------------------------
// Overlap scoring config
// ---------------------------------------------------------------------------

/// Configurable overlap scoring weights for thread assignment.
pub type ThreadingConfig {
  ThreadingConfig(
    location_weight: Int,
    domain_weight: Int,
    keyword_weight: Int,
    threshold: Int,
  )
}

/// Default threading configuration.
pub fn default_config() -> ThreadingConfig {
  ThreadingConfig(
    location_weight: 3,
    domain_weight: 2,
    keyword_weight: 1,
    threshold: 4,
  )
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Assign a thread to an entry, update the thread index, and persist it.
/// Uses the Librarian for the thread index if available.
/// Returns the entry with its thread field populated.
pub fn assign_thread(
  entry: NarrativeEntry,
  dir: String,
  lib: Option(Subject(LibrarianMessage)),
  cfg: ThreadingConfig,
) -> NarrativeEntry {
  let index = case lib {
    Some(l) -> librarian.load_thread_index(l)
    None -> narrative_log.load_thread_index(dir)
  }
  let #(updated_entry, updated_index) = do_assign(entry, index, cfg)
  narrative_log.save_thread_index(dir, updated_index)
  updated_entry
}

/// Pure thread assignment — no I/O. Testable.
pub fn do_assign(
  entry: NarrativeEntry,
  index: ThreadIndex,
  cfg: ThreadingConfig,
) -> #(NarrativeEntry, ThreadIndex) {
  let scores =
    list.map(index.threads, fn(ts) {
      #(ts, score_overlap_with_config(entry, ts, cfg))
    })

  let best =
    list.fold(scores, #(None, 0), fn(acc, pair) {
      let #(_best_ts, best_score) = acc
      let #(ts, s) = pair
      case s > best_score {
        True -> #(Some(ts), s)
        False -> acc
      }
    })

  case best {
    #(Some(ts), s) if s >= cfg.threshold -> {
      // Join existing thread
      let thread =
        Thread(
          thread_id: ts.thread_id,
          thread_name: ts.thread_name,
          position: ts.cycle_count + 1,
          previous_cycle_id: Some(ts.last_cycle_id),
          continuity_note: build_continuity_note(entry, ts),
        )
      let updated_entry = NarrativeEntry(..entry, thread: Some(thread))
      let updated_ts = update_thread_state(ts, entry)
      let updated_index = replace_thread(index, updated_ts)
      #(updated_entry, updated_index)
    }
    _ -> {
      // Create new thread
      let thread_id = cycle_log.generate_uuid()
      let thread_name = derive_thread_name(entry)
      let thread =
        Thread(
          thread_id:,
          thread_name:,
          position: 1,
          previous_cycle_id: None,
          continuity_note: "New thread started.",
        )
      let updated_entry = NarrativeEntry(..entry, thread: Some(thread))
      let new_ts =
        ThreadState(
          thread_id:,
          thread_name:,
          created_at: entry.timestamp,
          last_cycle_id: entry.cycle_id,
          last_cycle_at: entry.timestamp,
          cycle_count: 1,
          locations: entry.entities.locations,
          domains: case entry.intent.domain {
            "" -> []
            d -> [d]
          },
          keywords: entry.keywords,
          last_data_points: entry.entities.data_points,
        )
      let updated_index = ThreadIndex(threads: [new_ts, ..index.threads])
      #(updated_entry, updated_index)
    }
  }
}

/// Compute the overlap score between an entry and a thread state (default weights).
pub fn score_overlap(entry: NarrativeEntry, ts: ThreadState) -> Int {
  score_overlap_with_config(entry, ts, default_config())
}

/// Compute the overlap score with configurable weights.
pub fn score_overlap_with_config(
  entry: NarrativeEntry,
  ts: ThreadState,
  cfg: ThreadingConfig,
) -> Int {
  let location_score =
    count_intersections(entry.entities.locations, ts.locations)
    * cfg.location_weight
  let domain_score = case entry.intent.domain {
    "" -> 0
    d ->
      case list.contains(ts.domains, d) {
        True -> cfg.domain_weight
        False -> 0
      }
  }
  let keyword_score =
    count_intersections(entry.keywords, ts.keywords) * cfg.keyword_weight
  location_score + domain_score + keyword_score
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

fn count_intersections(a: List(String), b: List(String)) -> Int {
  let lower_b = list.map(b, string.lowercase)
  list.count(a, fn(item) { list.contains(lower_b, string.lowercase(item)) })
}

fn build_continuity_note(entry: NarrativeEntry, ts: ThreadState) -> String {
  let location_overlap =
    list.filter(entry.entities.locations, fn(loc) {
      list.contains(ts.locations, loc)
    })
  let location_note = case location_overlap {
    [] -> ""
    locs -> "Continues in " <> string.join(locs, ", ") <> ". "
  }

  let data_comparison = compare_data_points(entry, ts)

  case location_note <> data_comparison {
    "" -> "Continuing thread: " <> ts.thread_name <> "."
    note -> string.trim(note)
  }
}

fn compare_data_points(entry: NarrativeEntry, ts: ThreadState) -> String {
  // Find matching data points by label and note changes
  list.filter_map(entry.entities.data_points, fn(dp) {
    case list.find(ts.last_data_points, fn(prev) { prev.label == dp.label }) {
      Ok(prev) ->
        case prev.value == dp.value {
          True -> Error(Nil)
          False ->
            Ok(
              dp.label
              <> " changed from "
              <> prev.value
              <> " to "
              <> dp.value
              <> ". ",
            )
        }
      Error(_) -> Error(Nil)
    }
  })
  |> string.join("")
}

fn derive_thread_name(entry: NarrativeEntry) -> String {
  let domain = entry.intent.domain
  let locations = entry.entities.locations
  case domain, locations {
    "", [] -> "Thread " <> string.slice(entry.cycle_id, 0, 8)
    d, [] -> d
    "", [loc, ..] -> loc
    d, [loc, ..] -> d <> " — " <> loc
  }
}

fn update_thread_state(ts: ThreadState, entry: NarrativeEntry) -> ThreadState {
  ThreadState(
    ..ts,
    last_cycle_id: entry.cycle_id,
    last_cycle_at: entry.timestamp,
    cycle_count: ts.cycle_count + 1,
    locations: merge_unique(ts.locations, entry.entities.locations),
    domains: case entry.intent.domain {
      "" -> ts.domains
      d -> merge_unique(ts.domains, [d])
    },
    keywords: merge_unique(ts.keywords, entry.keywords)
      |> list.take(20),
    last_data_points: case entry.entities.data_points {
      [] -> ts.last_data_points
      dps -> dps
    },
  )
}

fn merge_unique(existing: List(String), new: List(String)) -> List(String) {
  list.fold(new, existing, fn(acc, item) {
    let lower_item = string.lowercase(item)
    case list.any(acc, fn(e) { string.lowercase(e) == lower_item }) {
      True -> acc
      False -> list.append(acc, [item])
    }
  })
}

fn replace_thread(index: ThreadIndex, updated: ThreadState) -> ThreadIndex {
  ThreadIndex(
    threads: list.map(index.threads, fn(ts) {
      case ts.thread_id == updated.thread_id {
        True -> updated
        False -> ts
      }
    }),
  )
}

/// Get the default overlap threshold.
pub fn threshold() -> Int {
  default_config().threshold
}

/// Format overlap score for display.
pub fn score_to_string(score: Int) -> String {
  int.to_string(score) <> "/" <> int.to_string(default_config().threshold)
}
