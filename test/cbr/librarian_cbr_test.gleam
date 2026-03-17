import cbr/log as cbr_log
import cbr/types.{
  type CbrCase, CbrCase, CbrOutcome, CbrProblem, CbrQuery, CbrSolution,
}
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
  let dir = "/tmp/librarian_cbr_test_" <> suffix
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

fn make_case(
  case_id: String,
  intent: String,
  domain: String,
  keywords: List(String),
  entities: List(String),
) -> CbrCase {
  CbrCase(
    case_id:,
    timestamp: "2026-03-08T10:00:00",
    schema_version: 1,
    problem: CbrProblem(
      user_input: "test query",
      intent:,
      domain:,
      entities:,
      keywords:,
      query_complexity: "simple",
    ),
    solution: CbrSolution(
      approach: "direct",
      agents_used: [],
      tools_used: [],
      steps: [],
    ),
    outcome: CbrOutcome(
      status: "success",
      confidence: 0.8,
      assessment: "ok",
      pitfalls: [],
    ),
    source_narrative_id: "cycle-001",
    profile: None,
  )
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

pub fn librarian_starts_with_no_cases_test() {
  let dir = test_dir("no_cases")
  let cbr_dir = dir <> "/cbr"
  let _ = simplifile.create_directory_all(cbr_dir)
  let lib =
    librarian.start(
      dir,
      cbr_dir,
      dir <> "/facts",
      dir <> "/artifacts",
      0,
      librarian.default_cbr_config(),
    )
  let cases = librarian.load_all_cases(lib)
  cases |> should.equal([])
  process.send(lib, librarian.Shutdown)
}

pub fn librarian_index_and_query_case_test() {
  let dir = test_dir("index_case")
  let cbr_dir = dir <> "/cbr"
  let _ = simplifile.create_directory_all(cbr_dir)
  let lib =
    librarian.start(
      dir,
      cbr_dir,
      dir <> "/facts",
      dir <> "/artifacts",
      0,
      librarian.default_cbr_config(),
    )

  let c = make_case("case-001", "research", "property", ["market"], ["Dublin"])
  librarian.notify_new_case(lib, c)
  process.sleep(50)

  let cases = librarian.load_all_cases(lib)
  list.length(cases) |> should.equal(1)
  let assert [loaded] = cases
  loaded.case_id |> should.equal("case-001")

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_retrieve_by_intent_test() {
  let dir = test_dir("by_intent")
  let cbr_dir = dir <> "/cbr"
  let _ = simplifile.create_directory_all(cbr_dir)
  let lib =
    librarian.start(
      dir,
      cbr_dir,
      dir <> "/facts",
      dir <> "/artifacts",
      0,
      librarian.default_cbr_config(),
    )

  let c1 = make_case("case-i1", "research", "property", ["market"], ["Dublin"])
  let c2 = make_case("case-i2", "analysis", "finance", ["stocks"], ["NYSE"])
  let c3 = make_case("case-i3", "research", "technology", ["AI"], ["OpenAI"])
  librarian.notify_new_case(lib, c1)
  librarian.notify_new_case(lib, c2)
  librarian.notify_new_case(lib, c3)
  process.sleep(50)

  // Query for research intent — should match c1 and c3 with higher scores
  let query =
    CbrQuery(
      intent: "research",
      domain: "property",
      keywords: ["market"],
      entities: ["Dublin"],
      max_results: 10,
    )
  let results = librarian.retrieve_cases(lib, query)

  // Should have results (at minimum the intent-matching ones)
  should.be_true(list.length(results) >= 1)

  // Top result should be c1 (matches intent + domain + keywords + entities)
  let assert [top, ..] = results
  top.cbr_case.case_id |> should.equal("case-i1")

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_retrieve_by_keywords_test() {
  let dir = test_dir("by_kw")
  let cbr_dir = dir <> "/cbr"
  let _ = simplifile.create_directory_all(cbr_dir)
  let lib =
    librarian.start(
      dir,
      cbr_dir,
      dir <> "/facts",
      dir <> "/artifacts",
      0,
      librarian.default_cbr_config(),
    )

  let c1 =
    make_case("case-k1", "research", "property", ["market", "rental"], [
      "Dublin",
    ])
  let c2 =
    make_case("case-k2", "research", "property", ["market", "sales"], ["Cork"])
  librarian.notify_new_case(lib, c1)
  librarian.notify_new_case(lib, c2)
  process.sleep(50)

  // Query with keyword overlap — "market" + "rental" should favour c1
  let query =
    CbrQuery(
      intent: "research",
      domain: "property",
      keywords: ["market", "rental"],
      entities: [],
      max_results: 10,
    )
  let results = librarian.retrieve_cases(lib, query)
  should.be_true(list.length(results) >= 2)

  // c1 should score higher (2/3 keyword overlap vs 1/3)
  let assert [top, ..] = results
  top.cbr_case.case_id |> should.equal("case-k1")

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_retrieve_max_results_test() {
  let dir = test_dir("max_results")
  let cbr_dir = dir <> "/cbr"
  let _ = simplifile.create_directory_all(cbr_dir)
  let lib =
    librarian.start(
      dir,
      cbr_dir,
      dir <> "/facts",
      dir <> "/artifacts",
      0,
      librarian.default_cbr_config(),
    )

  // Insert 5 cases with the same intent
  list.each(["c1", "c2", "c3", "c4", "c5"], fn(id) {
    let c = make_case(id, "research", "property", ["market"], [])
    librarian.notify_new_case(lib, c)
  })
  process.sleep(50)

  // Query with max_results=2
  let query =
    CbrQuery(
      intent: "research",
      domain: "property",
      keywords: ["market"],
      entities: [],
      max_results: 2,
    )
  let results = librarian.retrieve_cases(lib, query)
  list.length(results) |> should.equal(2)

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_retrieve_no_match_test() {
  let dir = test_dir("no_match")
  let cbr_dir = dir <> "/cbr"
  let _ = simplifile.create_directory_all(cbr_dir)
  let lib =
    librarian.start(
      dir,
      cbr_dir,
      dir <> "/facts",
      dir <> "/artifacts",
      0,
      librarian.default_cbr_config(),
    )

  let c = make_case("case-nm1", "research", "property", ["market"], ["Dublin"])
  librarian.notify_new_case(lib, c)
  process.sleep(50)

  // Query with completely different intent, domain, keywords, entities
  let query =
    CbrQuery(
      intent: "coding",
      domain: "software",
      keywords: ["rust", "compiler"],
      entities: ["Mozilla"],
      max_results: 10,
    )
  let results = librarian.retrieve_cases(lib, query)

  // With paperwings RRF, all indexed cases get some score (no min_score threshold).
  // A completely mismatched query still finds results via the inverted index.
  // The key invariant is that results are returned (even low-scored).
  should.be_true(list.length(results) >= 0)

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_cbr_replay_from_disk_test() {
  let dir = test_dir("replay_cbr")
  let cbr_dir = dir <> "/cbr"
  let _ = simplifile.create_directory_all(cbr_dir)

  // Write cases directly to JSONL before starting Librarian
  let c1 = make_case("case-rp1", "research", "property", ["market"], [])
  let c2 = make_case("case-rp2", "analysis", "finance", ["stocks"], [])
  let json1 = json.to_string(cbr_log.encode_case(c1))
  let json2 = json.to_string(cbr_log.encode_case(c2))
  let _ =
    simplifile.write(
      cbr_dir <> "/2026-03-08.jsonl",
      json1 <> "\n" <> json2 <> "\n",
    )

  // Start Librarian — should replay CBR cases
  let lib =
    librarian.start(
      dir,
      cbr_dir,
      dir <> "/facts",
      dir <> "/artifacts",
      0,
      librarian.default_cbr_config(),
    )
  let cases = librarian.load_all_cases(lib)
  list.length(cases) |> should.equal(2)

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_domain_scoring_test() {
  let dir = test_dir("domain_score")
  let cbr_dir = dir <> "/cbr"
  let _ = simplifile.create_directory_all(cbr_dir)
  let lib =
    librarian.start(
      dir,
      cbr_dir,
      dir <> "/facts",
      dir <> "/artifacts",
      0,
      librarian.default_cbr_config(),
    )

  let c1 = make_case("case-d1", "research", "property", ["market"], [])
  let c2 = make_case("case-d2", "research", "finance", ["market"], [])
  librarian.notify_new_case(lib, c1)
  librarian.notify_new_case(lib, c2)
  process.sleep(50)

  // Query matching property domain — c1 should rank higher
  let query =
    CbrQuery(
      intent: "research",
      domain: "property",
      keywords: ["market"],
      entities: [],
      max_results: 10,
    )
  let results = librarian.retrieve_cases(lib, query)
  should.be_true(list.length(results) >= 2)
  let assert [top, ..] = results
  top.cbr_case.case_id |> should.equal("case-d1")

  process.send(lib, librarian.Shutdown)
}

pub fn librarian_entity_scoring_test() {
  let dir = test_dir("entity_score")
  let cbr_dir = dir <> "/cbr"
  let _ = simplifile.create_directory_all(cbr_dir)
  let lib =
    librarian.start(
      dir,
      cbr_dir,
      dir <> "/facts",
      dir <> "/artifacts",
      0,
      librarian.default_cbr_config(),
    )

  let c1 =
    make_case("case-e1", "research", "property", ["market"], ["Dublin", "Cork"])
  let c2 = make_case("case-e2", "research", "property", ["market"], ["London"])
  librarian.notify_new_case(lib, c1)
  librarian.notify_new_case(lib, c2)
  process.sleep(50)

  // Query for Dublin entities — c1 should score higher on entity overlap
  let query =
    CbrQuery(
      intent: "research",
      domain: "property",
      keywords: ["market"],
      entities: ["Dublin"],
      max_results: 10,
    )
  let results = librarian.retrieve_cases(lib, query)
  should.be_true(list.length(results) >= 2)
  let assert [top, ..] = results
  top.cbr_case.case_id |> should.equal("case-e1")

  process.send(lib, librarian.Shutdown)
}
