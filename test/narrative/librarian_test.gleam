import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import narrative/librarian
import narrative/log as narrative_log
import narrative/types.{
  type NarrativeEntry, Conversation, Entities, Intent, Metrics, Narrative,
  NarrativeEntry, Outcome, Success, Thread, ThreadIndex, ThreadState,
}
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/librarian_test_" <> suffix
  let _ = simplifile.create_directory_all(dir)
  // Clean any existing files
  case simplifile.read_directory(dir) {
    Ok(files) ->
      list.each(files, fn(f) {
        let _ = simplifile.delete(dir <> "/" <> f)
        Nil
      })
    Error(_) -> Nil
  }
  dir
}

fn make_entry(cycle_id: String, summary: String) -> NarrativeEntry {
  NarrativeEntry(
    schema_version: 1,
    cycle_id:,
    parent_cycle_id: None,
    timestamp: "2026-03-08T10:00:00",
    entry_type: Narrative,
    summary:,
    intent: Intent(
      classification: Conversation,
      description: "test",
      domain: "testing",
    ),
    outcome: Outcome(status: Success, confidence: 0.9, assessment: "ok"),
    delegation_chain: [],
    decisions: [],
    keywords: ["test", "memory"],
    topics: [],
    entities: Entities(
      locations: ["Dublin"],
      organisations: [],
      data_points: [],
      temporal_references: [],
    ),
    sources: [],
    thread: None,
    metrics: Metrics(
      total_duration_ms: 0,
      input_tokens: 100,
      output_tokens: 50,
      thinking_tokens: 0,
      tool_calls: 0,
      agent_delegations: 0,
      dprime_evaluations: 0,
      model_used: "mock",
    ),
    observations: [],
  )
}

fn make_threaded_entry(
  cycle_id: String,
  thread_id: String,
  thread_name: String,
) -> NarrativeEntry {
  NarrativeEntry(
    ..make_entry(cycle_id, "Threaded entry " <> cycle_id),
    thread: Some(Thread(
      thread_id:,
      thread_name:,
      position: 1,
      previous_cycle_id: None,
      continuity_note: "New thread.",
    )),
  )
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

pub fn librarian_starts_with_empty_dir_test() {
  let dir = test_dir("empty")
  let lib =
    librarian.start(
      dir,
      dir <> "/cbr",
      dir <> "/facts",
      dir <> "/artifacts",
      0,
      librarian.default_cbr_config(),
    )
  let entries = librarian.load_all(lib)
  entries |> should.equal([])
  process.send(lib, librarian.Shutdown)
}

pub fn librarian_replays_from_jsonl_test() {
  let dir = test_dir("replay")
  // Write entries directly to JSONL
  let entry1 = make_entry("cycle-001", "First entry")
  let entry2 = make_entry("cycle-002", "Second entry")
  narrative_log.append(dir, entry1)
  narrative_log.append(dir, entry2)

  // Start Librarian — should replay those entries
  let lib =
    librarian.start(
      dir,
      dir <> "/cbr",
      dir <> "/facts",
      dir <> "/artifacts",
      0,
      librarian.default_cbr_config(),
    )
  let entries = librarian.load_all(lib)
  list.length(entries) |> should.equal(2)
  process.send(lib, librarian.Shutdown)
}

pub fn librarian_index_entry_test() {
  let dir = test_dir("index")
  let lib =
    librarian.start(
      dir,
      dir <> "/cbr",
      dir <> "/facts",
      dir <> "/artifacts",
      0,
      librarian.default_cbr_config(),
    )

  // Notify Librarian of a new entry
  let entry = make_entry("cycle-100", "Indexed entry")
  librarian.notify_new_entry(lib, entry)

  // Give the actor time to process the message
  process.sleep(50)

  let entries = librarian.load_all(lib)
  list.length(entries) |> should.equal(1)
  let assert [e] = entries
  e.cycle_id |> should.equal("cycle-100")
  process.send(lib, librarian.Shutdown)
}

pub fn librarian_search_by_keyword_test() {
  let dir = test_dir("search")
  let lib =
    librarian.start(
      dir,
      dir <> "/cbr",
      dir <> "/facts",
      dir <> "/artifacts",
      0,
      librarian.default_cbr_config(),
    )

  let entry1 =
    NarrativeEntry(
      ..make_entry("cycle-s1", "Researched property market"),
      keywords: ["property", "market"],
    )
  let entry2 =
    NarrativeEntry(
      ..make_entry("cycle-s2", "Explored quantum computing"),
      keywords: ["quantum", "computing"],
    )
  librarian.notify_new_entry(lib, entry1)
  librarian.notify_new_entry(lib, entry2)
  process.sleep(50)

  let results = librarian.search(lib, "property")
  list.length(results) |> should.equal(1)
  let assert [r] = results
  r.cycle_id |> should.equal("cycle-s1")

  let results2 = librarian.search(lib, "quantum")
  list.length(results2) |> should.equal(1)

  // Search by summary text
  let results3 = librarian.search(lib, "market")
  list.length(results3) |> should.equal(1)

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_search_case_insensitive_test() {
  let dir = test_dir("search_case")
  let lib =
    librarian.start(
      dir,
      dir <> "/cbr",
      dir <> "/facts",
      dir <> "/artifacts",
      0,
      librarian.default_cbr_config(),
    )

  let entry =
    NarrativeEntry(
      ..make_entry("cycle-ci", "Dublin property analysis"),
      keywords: ["Dublin", "Property"],
    )
  librarian.notify_new_entry(lib, entry)
  process.sleep(50)

  let results = librarian.search(lib, "dublin")
  list.length(results) |> should.equal(1)

  let results2 = librarian.search(lib, "PROPERTY")
  list.length(results2) |> should.equal(1)

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_thread_query_test() {
  let dir = test_dir("thread")
  let lib =
    librarian.start(
      dir,
      dir <> "/cbr",
      dir <> "/facts",
      dir <> "/artifacts",
      0,
      librarian.default_cbr_config(),
    )

  let entry1 = make_threaded_entry("cycle-t1", "thread-A", "Property Research")
  let entry2 = make_threaded_entry("cycle-t2", "thread-B", "Quantum Computing")
  let entry3 =
    NarrativeEntry(
      ..make_threaded_entry("cycle-t3", "thread-A", "Property Research"),
      timestamp: "2026-03-08T11:00:00",
    )
  librarian.notify_new_entry(lib, entry1)
  librarian.notify_new_entry(lib, entry2)
  librarian.notify_new_entry(lib, entry3)
  process.sleep(50)

  let thread_a = librarian.load_thread(lib, "thread-A")
  list.length(thread_a) |> should.equal(2)

  let thread_b = librarian.load_thread(lib, "thread-B")
  list.length(thread_b) |> should.equal(1)

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_date_range_query_test() {
  let dir = test_dir("daterange")
  let lib =
    librarian.start(
      dir,
      dir <> "/cbr",
      dir <> "/facts",
      dir <> "/artifacts",
      0,
      librarian.default_cbr_config(),
    )

  let entry1 =
    NarrativeEntry(
      ..make_entry("cycle-d1", "March 7 entry"),
      timestamp: "2026-03-07T10:00:00",
    )
  let entry2 =
    NarrativeEntry(
      ..make_entry("cycle-d2", "March 8 entry"),
      timestamp: "2026-03-08T10:00:00",
    )
  let entry3 =
    NarrativeEntry(
      ..make_entry("cycle-d3", "March 9 entry"),
      timestamp: "2026-03-09T10:00:00",
    )
  librarian.notify_new_entry(lib, entry1)
  librarian.notify_new_entry(lib, entry2)
  librarian.notify_new_entry(lib, entry3)
  process.sleep(50)

  // Range that includes only March 8
  let results = librarian.load_entries(lib, "2026-03-08", "2026-03-08")
  list.length(results) |> should.equal(1)
  let assert [r] = results
  r.cycle_id |> should.equal("cycle-d2")

  // Range that includes March 7-8
  let results2 = librarian.load_entries(lib, "2026-03-07", "2026-03-08")
  list.length(results2) |> should.equal(2)

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_recent_entries_test() {
  let dir = test_dir("recent")
  let lib =
    librarian.start(
      dir,
      dir <> "/cbr",
      dir <> "/facts",
      dir <> "/artifacts",
      0,
      librarian.default_cbr_config(),
    )

  let entry1 =
    NarrativeEntry(
      ..make_entry("cycle-r1", "Old entry"),
      timestamp: "2026-03-07T10:00:00",
    )
  let entry2 =
    NarrativeEntry(
      ..make_entry("cycle-r2", "Recent entry"),
      timestamp: "2026-03-08T10:00:00",
    )
  let entry3 =
    NarrativeEntry(
      ..make_entry("cycle-r3", "Latest entry"),
      timestamp: "2026-03-08T11:00:00",
    )
  librarian.notify_new_entry(lib, entry1)
  librarian.notify_new_entry(lib, entry2)
  librarian.notify_new_entry(lib, entry3)
  process.sleep(50)

  // Get last 2
  let results = librarian.get_recent(lib, 2)
  list.length(results) |> should.equal(2)
  let assert [a, b] = results
  a.cycle_id |> should.equal("cycle-r2")
  b.cycle_id |> should.equal("cycle-r3")

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_thread_index_test() {
  let dir = test_dir("threadidx")
  let lib =
    librarian.start(
      dir,
      dir <> "/cbr",
      dir <> "/facts",
      dir <> "/artifacts",
      0,
      librarian.default_cbr_config(),
    )

  // Initially empty
  let idx = librarian.load_thread_index(lib)
  idx.threads |> should.equal([])

  // Update thread index
  let ts =
    ThreadState(
      thread_id: "t1",
      thread_name: "Test Thread",
      created_at: "2026-03-08T10:00:00",
      last_cycle_id: "cycle-001",
      last_cycle_at: "2026-03-08T10:00:00",
      cycle_count: 1,
      locations: [],
      domains: [],
      keywords: [],
      topics: [],
      last_data_points: [],
    )
  librarian.notify_thread_index(lib, ThreadIndex(threads: [ts]))
  process.sleep(50)

  let idx2 = librarian.load_thread_index(lib)
  list.length(idx2.threads) |> should.equal(1)

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_max_files_limit_test() {
  let dir = test_dir("maxfiles")
  let _ = simplifile.create_directory_all(dir)
  let entry1 = make_entry("cycle-mf1", "Day one entry")
  let entry2 = make_entry("cycle-mf2", "Day two entry")
  let json1 = json.to_string(narrative_log.encode_entry(entry1))
  let json2 = json.to_string(narrative_log.encode_entry(entry2))
  let _ = simplifile.write(dir <> "/2026-03-07.jsonl", json1 <> "\n")
  let _ = simplifile.write(dir <> "/2026-03-08.jsonl", json2 <> "\n")

  // Load with max_files=1 — should only load the most recent file
  let lib =
    librarian.start(
      dir,
      dir <> "/cbr",
      dir <> "/facts",
      dir <> "/artifacts",
      1,
      librarian.default_cbr_config(),
    )
  let entries = librarian.load_all(lib)
  list.length(entries) |> should.equal(1)
  let assert [e] = entries
  e.cycle_id |> should.equal("cycle-mf2")

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_thread_heads_test() {
  let dir = test_dir("heads")
  let lib =
    librarian.start(
      dir,
      dir <> "/cbr",
      dir <> "/facts",
      dir <> "/artifacts",
      0,
      librarian.default_cbr_config(),
    )

  let entry1 = make_threaded_entry("cycle-h1", "thread-X", "Thread X")
  let entry2 =
    NarrativeEntry(
      ..make_threaded_entry("cycle-h2", "thread-X", "Thread X"),
      timestamp: "2026-03-08T11:00:00",
    )

  librarian.notify_new_entry(lib, entry1)
  librarian.notify_new_entry(lib, entry2)

  // Set up thread index pointing to the latest entry
  let ts =
    ThreadState(
      thread_id: "thread-X",
      thread_name: "Thread X",
      created_at: "2026-03-08T10:00:00",
      last_cycle_id: "cycle-h2",
      last_cycle_at: "2026-03-08T11:00:00",
      cycle_count: 2,
      locations: [],
      domains: [],
      keywords: [],
      topics: [],
      last_data_points: [],
    )
  librarian.notify_thread_index(lib, ThreadIndex(threads: [ts]))
  process.sleep(50)

  let heads = librarian.thread_heads(lib)
  list.length(heads) |> should.equal(1)
  let assert [h] = heads
  h.cycle_id |> should.equal("cycle-h2")

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_no_results_for_unknown_keyword_test() {
  let dir = test_dir("noresults")
  let lib =
    librarian.start(
      dir,
      dir <> "/cbr",
      dir <> "/facts",
      dir <> "/artifacts",
      0,
      librarian.default_cbr_config(),
    )
  let results = librarian.search(lib, "nonexistent_topic_xyz")
  results |> should.equal([])
  process.send(lib, librarian.Shutdown)
}
