import facts/log as facts_log
import facts/types.{type MemoryFact, Clear, MemoryFact, Session, Write}
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None}
import gleeunit/should
import narrative/librarian
import simplifile

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/librarian_facts_test_" <> suffix
  let _ = simplifile.create_directory_all(dir)
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

fn make_fact(fact_id: String, key: String, value: String) -> MemoryFact {
  MemoryFact(
    schema_version: 1,
    fact_id:,
    timestamp: "2026-03-08T10:00:00",
    cycle_id: "cycle-001",
    agent_id: None,
    key:,
    value:,
    scope: Session,
    operation: Write,
    supersedes: None,
    confidence: 0.9,
    source: "cognitive_loop",
  )
}

fn start_lib(suffix: String) {
  let dir = test_dir(suffix)
  let cbr_dir = dir <> "/cbr"
  let facts_dir = dir <> "/facts"
  let _ = simplifile.create_directory_all(cbr_dir)
  let _ = simplifile.create_directory_all(facts_dir)
  let lib = librarian.start(dir, cbr_dir, facts_dir, 0)
  #(lib, dir, facts_dir)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

pub fn librarian_starts_with_no_facts_test() {
  let #(lib, _, _) = start_lib("no_facts")
  let facts = librarian.get_all_facts(lib)
  facts |> should.equal([])
  process.send(lib, librarian.Shutdown)
}

pub fn librarian_index_and_query_fact_test() {
  let #(lib, _, _) = start_lib("index_fact")
  let fact = make_fact("fact-001", "rent", "€2,340")
  librarian.notify_new_fact(lib, fact)
  process.sleep(50)

  let result = librarian.get_fact(lib, "rent")
  case result {
    Ok(f) -> f.value |> should.equal("€2,340")
    Error(_) -> should.fail()
  }

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_fact_overwrite_test() {
  let #(lib, _, _) = start_lib("overwrite")
  let f1 = make_fact("fact-ow1", "rent", "€2,340")
  let f2 = make_fact("fact-ow2", "rent", "€2,500")
  librarian.notify_new_fact(lib, f1)
  librarian.notify_new_fact(lib, f2)
  process.sleep(50)

  let result = librarian.get_fact(lib, "rent")
  case result {
    Ok(f) -> f.value |> should.equal("€2,500")
    Error(_) -> should.fail()
  }

  // Should only have one fact for key "rent"
  let all = librarian.get_all_facts(lib)
  list.length(all) |> should.equal(1)

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_fact_clear_test() {
  let #(lib, _, _) = start_lib("clear")
  let f1 = make_fact("fact-cl1", "rent", "€2,340")
  let f2 = MemoryFact(..make_fact("fact-cl2", "rent", ""), operation: Clear)
  librarian.notify_new_fact(lib, f1)
  librarian.notify_new_fact(lib, f2)
  process.sleep(50)

  let result = librarian.get_fact(lib, "rent")
  case result {
    Ok(_) -> should.fail()
    Error(Nil) -> Nil
  }

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_facts_by_cycle_test() {
  let #(lib, _, _) = start_lib("by_cycle")
  let f1 = make_fact("fact-bc1", "rent", "€2,340")
  let f2 =
    MemoryFact(..make_fact("fact-bc2", "pop", "1.4M"), cycle_id: "cycle-002")
  librarian.notify_new_fact(lib, f1)
  librarian.notify_new_fact(lib, f2)
  process.sleep(50)

  let cycle1 = librarian.get_facts_by_cycle(lib, "cycle-001")
  list.length(cycle1) |> should.equal(1)

  let cycle2 = librarian.get_facts_by_cycle(lib, "cycle-002")
  list.length(cycle2) |> should.equal(1)

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_search_facts_test() {
  let #(lib, _, _) = start_lib("search")
  let f1 = make_fact("fact-s1", "dublin_rent", "€2,340")
  let f2 = make_fact("fact-s2", "cork_population", "220K")
  librarian.notify_new_fact(lib, f1)
  librarian.notify_new_fact(lib, f2)
  process.sleep(50)

  // Search by key substring
  let results = librarian.search_facts(lib, "dublin")
  list.length(results) |> should.equal(1)
  let assert [r] = results
  r.key |> should.equal("dublin_rent")

  // Search by value substring
  let results2 = librarian.search_facts(lib, "220K")
  list.length(results2) |> should.equal(1)

  // Case insensitive
  let results3 = librarian.search_facts(lib, "DUBLIN")
  list.length(results3) |> should.equal(1)

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_replay_facts_from_disk_test() {
  let dir = test_dir("replay_facts")
  let cbr_dir = dir <> "/cbr"
  let facts_dir = dir <> "/facts"
  let _ = simplifile.create_directory_all(cbr_dir)
  let _ = simplifile.create_directory_all(facts_dir)

  // Write facts to JSONL before starting Librarian
  let f1 = make_fact("fact-rp1", "rent", "€2,340")
  let f2 = make_fact("fact-rp2", "population", "1.4M")
  let json1 = json.to_string(facts_log.encode_fact(f1))
  let json2 = json.to_string(facts_log.encode_fact(f2))
  let _ =
    simplifile.write(
      facts_dir <> "/facts.jsonl",
      json1 <> "\n" <> json2 <> "\n",
    )

  let lib = librarian.start(dir, cbr_dir, facts_dir, 0)
  let facts = librarian.get_all_facts(lib)
  list.length(facts) |> should.equal(2)

  process.send(lib, librarian.Shutdown)
}
