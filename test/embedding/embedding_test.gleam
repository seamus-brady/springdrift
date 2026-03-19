// Embedding tests — tests for bridge CaseBase lifecycle and cosine similarity.

import cbr/bridge
import cbr/types.{type CbrCase, CbrCase, CbrOutcome, CbrProblem, CbrSolution}
import gleam/option.{None}
import gleeunit/should

fn make_test_case(id: String, intent: String, domain: String) -> CbrCase {
  CbrCase(
    case_id: id,
    timestamp: "2026-03-17T10:00:00",
    schema_version: 1,
    problem: CbrProblem(
      user_input: "test query",
      intent:,
      domain:,
      entities: [],
      keywords: ["test"],
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

pub fn bridge_new_creates_empty_casebase_test() {
  let base = bridge.new()
  bridge.case_count(base) |> should.equal(0)
}

pub fn bridge_retain_increases_count_test() {
  let base = bridge.new()
  let c = make_test_case("case-001", "research", "property")
  let base = bridge.retain_case(base, c)
  bridge.case_count(base) |> should.equal(1)
}

pub fn bridge_remove_decreases_count_test() {
  let base = bridge.new()
  let c = make_test_case("case-rm1", "research", "property")
  let base = bridge.retain_case(base, c)
  bridge.case_count(base) |> should.equal(1)
  let base = bridge.remove_case(base, "case-rm1")
  bridge.case_count(base) |> should.equal(0)
}

pub fn cosine_similarity_parallel_vectors_test() {
  let sim = bridge.cosine_similarity([3.0, 4.0], [6.0, 8.0])
  should.be_true(sim >. 0.99)
}

pub fn cosine_similarity_opposite_vectors_test() {
  let sim = bridge.cosine_similarity([1.0, 0.0], [-1.0, 0.0])
  should.be_true(sim <. -0.99)
}

pub fn cosine_similarity_different_lengths_test() {
  let sim = bridge.cosine_similarity([1.0, 2.0], [1.0])
  should.equal(sim, 0.0)
}

pub fn bridge_with_embed_fn_test() {
  // Mock embed function that returns fixed vectors based on intent
  let embed_fn = fn(text: String) -> Result(List(Float), String) {
    case text {
      "research property market" -> Ok([1.0, 0.0, 0.0])
      "coding software rust" -> Ok([0.0, 1.0, 0.0])
      _ -> Ok([0.0, 0.0, 1.0])
    }
  }
  let base = bridge.new_with_embeddings(embed_fn)
  let c1 = make_test_case("case-1", "research", "property")
  let c1 =
    CbrCase(..c1, problem: CbrProblem(..c1.problem, keywords: ["market"]))
  let base = bridge.retain_case(base, c1)
  // Embedding should be stored
  bridge.case_count(base) |> should.equal(1)
}
