// Embedding tests — CaseBase lifecycle, cosine similarity, and Ollama integration.

import cbr/bridge
import cbr/types.{
  type CbrCase, CbrCase, CbrOutcome, CbrProblem, CbrQuery, CbrSolution,
}
import embedding
import gleam/dict
import gleam/list
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
    redacted: False,
  )
}

// ---------------------------------------------------------------------------
// CaseBase lifecycle
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Cosine similarity
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Mock embed_fn wired through CaseBase
// ---------------------------------------------------------------------------

pub fn bridge_with_embed_fn_stores_embeddings_test() {
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
  let c2 = make_test_case("case-2", "coding", "software")
  let c2 = CbrCase(..c2, problem: CbrProblem(..c2.problem, keywords: ["rust"]))
  let base = bridge.retain_case(base, c1)
  let base = bridge.retain_case(base, c2)
  bridge.case_count(base) |> should.equal(2)
}

pub fn embedding_improves_retrieval_test() {
  // Mock: research texts get [1,0,0], coding texts get [0,1,0]
  let embed_fn = fn(text: String) -> Result(List(Float), String) {
    case text {
      t if t == "research property market" -> Ok([1.0, 0.0, 0.0])
      t if t == "coding software rust" -> Ok([0.0, 1.0, 0.0])
      // Query text "research property market" also maps to [1,0,0]
      _ -> Ok([0.5, 0.5, 0.0])
    }
  }
  let base = bridge.new_with_embeddings(embed_fn)

  let c1 = make_test_case("research-case", "research", "property")
  let c1 =
    CbrCase(..c1, problem: CbrProblem(..c1.problem, keywords: ["market"]))
  let c2 = make_test_case("coding-case", "coding", "software")
  let c2 = CbrCase(..c2, problem: CbrProblem(..c2.problem, keywords: ["rust"]))

  let base = bridge.retain_case(base, c1)
  let base = bridge.retain_case(base, c2)

  let metadata = dict.from_list([#("research-case", c1), #("coding-case", c2)])

  let query =
    CbrQuery(
      intent: "research",
      domain: "property",
      keywords: ["market"],
      entities: [],
      max_results: 10,
      query_complexity: None,
    )
  let results =
    bridge.retrieve_cases(base, query, metadata, bridge.default_weights(), 0.0)

  should.be_true(list.length(results) == 2)
  let assert [top, ..] = results
  // research-case should rank first — matches on all signals including embedding
  top.cbr_case.case_id |> should.equal("research-case")
}

// ---------------------------------------------------------------------------
// Ollama start_serving fails when Ollama is not running
// ---------------------------------------------------------------------------

pub fn start_serving_fails_when_ollama_down_test() {
  // Use a port that's definitely not running Ollama
  let result = embedding.start_serving("http://localhost:1", "nomic-embed-text")
  result |> should.be_error
}

pub fn embed_fails_with_bad_url_test() {
  let result = embedding.embed("not-a-url", "model", "hello")
  result |> should.be_error
}
