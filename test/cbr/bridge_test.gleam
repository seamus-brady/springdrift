import cbr/bridge
import cbr/types.{
  type CbrCase, CbrCase, CbrOutcome, CbrProblem, CbrQuery, CbrSolution,
}
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import simplifile

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/bridge_test_" <> suffix
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
      approach: "direct search",
      agents_used: ["researcher"],
      tools_used: ["web_search"],
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

fn make_case_with_timestamp(
  case_id: String,
  intent: String,
  domain: String,
  keywords: List(String),
  timestamp: String,
) -> CbrCase {
  CbrCase(..make_case(case_id, intent, domain, keywords, []), timestamp:)
}

// ---------------------------------------------------------------------------
// Tests: retain + retrieve round-trip
// ---------------------------------------------------------------------------

pub fn retain_and_retrieve_roundtrip_test() {
  let dir = test_dir("roundtrip")
  let base =
    bridge.new(dir, 1000)
    |> bridge.ensure_roles

  let c1 = make_case("case-1", "research", "property", ["market"], ["Dublin"])
  let base = bridge.retain_case(base, c1)

  bridge.case_count(base) |> should.equal(1)

  let metadata = dict.from_list([#("case-1", c1)])
  let query =
    CbrQuery(
      intent: "research",
      domain: "property",
      keywords: ["market"],
      entities: ["Dublin"],
      max_results: 10,
      query_complexity: None,
    )
  let results = bridge.retrieve_cases(base, query, metadata, 60, 0.0)
  list.length(results) |> should.equal(1)
  let assert [top] = results
  top.cbr_case.case_id |> should.equal("case-1")

  bridge.destroy(base)
}

// ---------------------------------------------------------------------------
// Tests: min_score filtering
// ---------------------------------------------------------------------------

pub fn min_score_filters_low_matches_test() {
  let dir = test_dir("min_score")
  let base =
    bridge.new(dir, 1000)
    |> bridge.ensure_roles

  let c1 = make_case("case-1", "research", "property", ["market"], ["Dublin"])
  let base = bridge.retain_case(base, c1)

  let metadata = dict.from_list([#("case-1", c1)])

  // Query with completely unrelated terms + high min_score
  let query =
    CbrQuery(
      intent: "coding",
      domain: "software",
      keywords: ["rust", "compiler"],
      entities: ["Mozilla"],
      max_results: 10,
      query_complexity: None,
    )
  // With high min_score, unrelated results should be filtered out
  let results = bridge.retrieve_cases(base, query, metadata, 60, 1.0)
  list.length(results) |> should.equal(0)

  bridge.destroy(base)
}

// ---------------------------------------------------------------------------
// Tests: approach tokens in inverted index
// ---------------------------------------------------------------------------

pub fn approach_tokens_in_index_test() {
  let dir = test_dir("approach")
  let base =
    bridge.new(dir, 1000)
    |> bridge.ensure_roles

  let c1 =
    CbrCase(
      ..make_case("case-1", "research", "property", ["market"], []),
      solution: CbrSolution(
        approach: "direct web search",
        agents_used: [],
        tools_used: [],
        steps: [],
      ),
    )
  let c2 =
    CbrCase(
      ..make_case("case-2", "research", "property", ["market"], []),
      solution: CbrSolution(
        approach: "deep analysis with experts",
        agents_used: [],
        tools_used: [],
        steps: [],
      ),
    )
  let base = bridge.retain_case(base, c1)
  let base = bridge.retain_case(base, c2)

  let metadata = dict.from_list([#("case-1", c1), #("case-2", c2)])

  // Query with "search" as keyword — should match c1's approach tokens
  let query =
    CbrQuery(
      intent: "research",
      domain: "property",
      keywords: ["market", "search"],
      entities: [],
      max_results: 10,
      query_complexity: None,
    )
  let results = bridge.retrieve_cases(base, query, metadata, 60, 0.0)
  should.be_true(list.length(results) >= 1)
  // c1 should rank higher (has "search" in approach)
  let assert [top, ..] = results
  top.cbr_case.case_id |> should.equal("case-1")

  bridge.destroy(base)
}

// ---------------------------------------------------------------------------
// Tests: recency ranking
// ---------------------------------------------------------------------------

pub fn recency_ranking_test() {
  let dir = test_dir("recency")
  let base =
    bridge.new(dir, 1000)
    |> bridge.ensure_roles

  // c1 is older, c2 is newer — both have identical features
  let c1 =
    make_case_with_timestamp(
      "case-old",
      "research",
      "property",
      ["market"],
      "2026-03-01T10:00:00",
    )
  let c2 =
    make_case_with_timestamp(
      "case-new",
      "research",
      "property",
      ["market"],
      "2026-03-15T10:00:00",
    )
  let base = bridge.retain_case(base, c1)
  let base = bridge.retain_case(base, c2)

  let metadata = dict.from_list([#("case-old", c1), #("case-new", c2)])
  let query =
    CbrQuery(
      intent: "research",
      domain: "property",
      keywords: ["market"],
      entities: [],
      max_results: 10,
      query_complexity: None,
    )
  let results = bridge.retrieve_cases(base, query, metadata, 60, 0.0)
  should.be_true(list.length(results) == 2)
  // Newer case should rank first due to recency signal
  let assert [top, ..] = results
  top.cbr_case.case_id |> should.equal("case-new")

  bridge.destroy(base)
}

// ---------------------------------------------------------------------------
// Tests: remove_case cleans empty posting lists
// ---------------------------------------------------------------------------

pub fn remove_case_cleans_empty_postings_test() {
  let dir = test_dir("remove_clean")
  let base =
    bridge.new(dir, 1000)
    |> bridge.ensure_roles

  // Use a unique keyword only in c1
  let c1 = make_case("case-rm1", "research", "property", ["uniquetoken"], [])
  let c2 = make_case("case-rm2", "research", "property", ["market"], [])
  let base = bridge.retain_case(base, c1)
  let base = bridge.retain_case(base, c2)

  bridge.case_count(base) |> should.equal(2)

  // Remove c1 — "uniquetoken" posting list should be cleaned up
  let base = bridge.remove_case(base, "case-rm1")
  bridge.case_count(base) |> should.equal(1)

  // Query for the removed unique token — should not match anything via index
  let metadata = dict.from_list([#("case-rm2", c2)])
  let query =
    CbrQuery(
      intent: "",
      domain: "",
      keywords: ["uniquetoken"],
      entities: [],
      max_results: 10,
      query_complexity: None,
    )
  let results = bridge.retrieve_cases(base, query, metadata, 60, 0.0)
  // The removed case_id must not appear in results
  let case_ids = list.map(results, fn(r) { r.cbr_case.case_id })
  list.contains(case_ids, "case-rm1") |> should.be_false

  bridge.destroy(base)
}

// ---------------------------------------------------------------------------
// Tests: query_complexity in case_tokens
// ---------------------------------------------------------------------------

pub fn query_complexity_in_tokens_test() {
  let dir = test_dir("complexity")
  let base =
    bridge.new(dir, 1000)
    |> bridge.ensure_roles

  let c_simple =
    CbrCase(
      ..make_case("case-simple", "research", "property", ["market"], []),
      problem: CbrProblem(
        user_input: "test",
        intent: "research",
        domain: "property",
        entities: [],
        keywords: ["market"],
        query_complexity: "simple",
      ),
    )
  let c_complex =
    CbrCase(
      ..make_case("case-complex", "research", "property", ["market"], []),
      problem: CbrProblem(
        user_input: "test",
        intent: "research",
        domain: "property",
        entities: [],
        keywords: ["market"],
        query_complexity: "complex",
      ),
    )
  let base = bridge.retain_case(base, c_simple)
  let base = bridge.retain_case(base, c_complex)

  let metadata =
    dict.from_list([#("case-simple", c_simple), #("case-complex", c_complex)])

  // Query specifying complex — should favour c_complex
  let query =
    CbrQuery(
      intent: "research",
      domain: "property",
      keywords: ["market"],
      entities: [],
      max_results: 10,
      query_complexity: Some("complex"),
    )
  let results = bridge.retrieve_cases(base, query, metadata, 60, 0.0)
  should.be_true(list.length(results) == 2)
  let assert [top, ..] = results
  top.cbr_case.case_id |> should.equal("case-complex")

  bridge.destroy(base)
}
