import cbr/types as cbr_types
import facts/types as facts_types
import gleam/float
import gleam/list
import gleam/option.{None}
import gleeunit/should
import narrative/housekeeping

// ---------------------------------------------------------------------------
// Cosine similarity
// ---------------------------------------------------------------------------

pub fn cosine_similarity_identical_vectors_test() {
  let a = [1.0, 0.0, 0.0]
  let b = [1.0, 0.0, 0.0]
  let sim = housekeeping.cosine_similarity(a, b)
  should.be_true(sim >. 0.99)
}

pub fn cosine_similarity_orthogonal_vectors_test() {
  let a = [1.0, 0.0, 0.0]
  let b = [0.0, 1.0, 0.0]
  let sim = housekeeping.cosine_similarity(a, b)
  should.be_true(float.absolute_value(sim) <. 0.01)
}

pub fn cosine_similarity_similar_vectors_test() {
  let a = [1.0, 1.0, 0.0]
  let b = [1.0, 1.0, 0.1]
  let sim = housekeeping.cosine_similarity(a, b)
  should.be_true(sim >. 0.95)
}

pub fn cosine_similarity_empty_vectors_test() {
  let sim = housekeeping.cosine_similarity([], [1.0, 2.0])
  should.be_true(float.absolute_value(sim) <. 0.01)
}

// ---------------------------------------------------------------------------
// CBR deduplication
// ---------------------------------------------------------------------------

fn make_case(
  id: String,
  timestamp: String,
  embedding: List(Float),
  status: String,
  confidence: Float,
  pitfalls: List(String),
) -> cbr_types.CbrCase {
  cbr_types.CbrCase(
    case_id: id,
    timestamp: timestamp,
    schema_version: 1,
    problem: cbr_types.CbrProblem(
      user_input: "test",
      intent: "research",
      domain: "test",
      entities: [],
      keywords: [],
      query_complexity: "simple",
    ),
    solution: cbr_types.CbrSolution(
      approach: "test",
      agents_used: [],
      tools_used: [],
      steps: [],
    ),
    outcome: cbr_types.CbrOutcome(
      status: status,
      confidence: confidence,
      assessment: "test",
      pitfalls: pitfalls,
    ),
    embedding: embedding,
    source_narrative_id: "n-" <> id,
  )
}

pub fn dedup_finds_similar_cases_test() {
  let case_a =
    make_case("a", "2026-03-01T10:00:00Z", [1.0, 0.0, 0.0], "success", 0.9, [])
  let case_b =
    make_case("b", "2026-03-02T10:00:00Z", [1.0, 0.0, 0.0], "success", 0.9, [])
  let results = housekeeping.find_duplicate_cases([case_a, case_b], 0.92)
  list.length(results) |> should.equal(1)
  let assert [r] = results
  // b is newer, so it should be kept
  r.keep_id |> should.equal("b")
  r.supersede_id |> should.equal("a")
}

pub fn dedup_ignores_dissimilar_cases_test() {
  let case_a =
    make_case("a", "2026-03-01T10:00:00Z", [1.0, 0.0, 0.0], "success", 0.9, [])
  let case_b =
    make_case("b", "2026-03-02T10:00:00Z", [0.0, 1.0, 0.0], "success", 0.9, [])
  let results = housekeeping.find_duplicate_cases([case_a, case_b], 0.92)
  results |> should.equal([])
}

pub fn dedup_handles_empty_embeddings_test() {
  let case_a = make_case("a", "2026-03-01T10:00:00Z", [], "success", 0.9, [])
  let case_b = make_case("b", "2026-03-02T10:00:00Z", [], "success", 0.9, [])
  let results = housekeeping.find_duplicate_cases([case_a, case_b], 0.92)
  results |> should.equal([])
}

pub fn dedup_empty_list_test() {
  let results = housekeeping.find_duplicate_cases([], 0.92)
  results |> should.equal([])
}

// ---------------------------------------------------------------------------
// CBR pruning
// ---------------------------------------------------------------------------

pub fn prune_finds_old_failures_test() {
  let old_failure =
    make_case("old-fail", "2025-01-01T10:00:00Z", [], "failure", 0.2, [])
  let results = housekeeping.find_prunable_cases([old_failure], "2025-12-01")
  list.length(results) |> should.equal(1)
  let assert [r] = results
  r.case_id |> should.equal("old-fail")
}

pub fn prune_keeps_recent_failures_test() {
  let recent_failure =
    make_case("recent-fail", "2026-03-01T10:00:00Z", [], "failure", 0.2, [])
  let results = housekeeping.find_prunable_cases([recent_failure], "2026-01-01")
  results |> should.equal([])
}

pub fn prune_keeps_failures_with_pitfalls_test() {
  let old_failure_with_pitfalls =
    make_case("pitfall-fail", "2025-01-01T10:00:00Z", [], "failure", 0.2, [
      "API rate limited",
    ])
  let results =
    housekeeping.find_prunable_cases([old_failure_with_pitfalls], "2025-12-01")
  results |> should.equal([])
}

pub fn prune_keeps_high_confidence_failures_test() {
  let high_conf_failure =
    make_case("hi-fail", "2025-01-01T10:00:00Z", [], "failure", 0.5, [])
  let results =
    housekeeping.find_prunable_cases([high_conf_failure], "2025-12-01")
  results |> should.equal([])
}

pub fn prune_keeps_successes_test() {
  let old_success =
    make_case("old-success", "2025-01-01T10:00:00Z", [], "success", 0.2, [])
  let results = housekeeping.find_prunable_cases([old_success], "2025-12-01")
  results |> should.equal([])
}

// ---------------------------------------------------------------------------
// Fact conflict resolution
// ---------------------------------------------------------------------------

fn make_fact(
  id: String,
  key: String,
  value: String,
  confidence: Float,
) -> facts_types.MemoryFact {
  facts_types.MemoryFact(
    schema_version: 1,
    fact_id: id,
    timestamp: "2026-03-01T10:00:00Z",
    cycle_id: "cycle-001",
    agent_id: None,
    key: key,
    value: value,
    scope: facts_types.Session,
    operation: facts_types.Write,
    supersedes: None,
    confidence: confidence,
    source: "test",
  )
}

pub fn conflict_finds_same_key_different_value_test() {
  let f1 = make_fact("f1", "rent", "€2,340", 0.8)
  let f2 = make_fact("f2", "rent", "€2,500", 0.9)
  let results = housekeeping.find_fact_conflicts([f1, f2])
  list.length(results) |> should.equal(1)
  let assert [r] = results
  r.key |> should.equal("rent")
  // Higher confidence kept
  r.keep_fact_id |> should.equal("f2")
  r.supersede_fact_id |> should.equal("f1")
}

pub fn conflict_ignores_same_value_test() {
  let f1 = make_fact("f1", "rent", "€2,340", 0.8)
  let f2 = make_fact("f2", "rent", "€2,340", 0.9)
  let results = housekeeping.find_fact_conflicts([f1, f2])
  results |> should.equal([])
}

pub fn conflict_ignores_different_keys_test() {
  let f1 = make_fact("f1", "rent", "€2,340", 0.8)
  let f2 = make_fact("f2", "population", "1.4M", 0.9)
  let results = housekeeping.find_fact_conflicts([f1, f2])
  results |> should.equal([])
}

pub fn conflict_empty_list_test() {
  let results = housekeeping.find_fact_conflicts([])
  results |> should.equal([])
}

// ---------------------------------------------------------------------------
// Report formatting
// ---------------------------------------------------------------------------

pub fn empty_report_test() {
  let report = housekeeping.empty_report()
  report.cases_deduplicated |> should.equal(0)
  report.cases_pruned |> should.equal(0)
  report.facts_resolved |> should.equal(0)
}

pub fn format_report_test() {
  let report =
    housekeeping.HousekeepingReport(
      cases_deduplicated: 2,
      cases_pruned: 1,
      facts_resolved: 3,
    )
  let text = housekeeping.format_report(report)
  should.be_true(
    text
    == "Housekeeping: 2 cases deduplicated, 1 cases pruned, 3 fact conflicts resolved",
  )
}

// ---------------------------------------------------------------------------
// Superseded fact builder
// ---------------------------------------------------------------------------

pub fn make_superseded_fact_test() {
  let original = make_fact("f1", "rent", "€2,340", 0.8)
  let superseded =
    housekeeping.make_superseded_fact(
      original,
      "f2",
      "housekeeping",
      "2026-03-08T12:00:00Z",
    )
  superseded.operation |> should.equal(facts_types.Superseded)
  superseded.key |> should.equal("rent")
  superseded.source |> should.equal("housekeeping")
}
