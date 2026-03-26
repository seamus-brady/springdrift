import cbr/bridge
import cbr/types.{
  type CbrCase, type CbrQuery, CbrCase, CbrOutcome, CbrProblem, CbrQuery,
  CbrSolution,
}
import gleam/dict
import gleam/float
import gleam/list
import gleam/option.{None}
import gleeunit/should

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_case(
  id: String,
  intent: String,
  domain: String,
  keywords: List(String),
  status: String,
  confidence: Float,
) -> CbrCase {
  CbrCase(
    case_id: id,
    timestamp: "2026-03-18T10:00:00",
    schema_version: 1,
    problem: CbrProblem(
      user_input: "test query for " <> id,
      intent:,
      domain:,
      entities: [],
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
      status:,
      confidence:,
      assessment: "test assessment",
      pitfalls: [],
    ),
    source_narrative_id: "cycle-" <> id,
    profile: None,
    redacted: False,
    category: None,
    usage_stats: None,
  )
}

fn make_query(
  intent: String,
  domain: String,
  keywords: List(String),
) -> CbrQuery {
  CbrQuery(
    intent:,
    domain:,
    keywords:,
    entities: [],
    max_results: 10,
    query_complexity: None,
  )
}

fn weights() -> bridge.RetrievalWeights {
  bridge.default_weights()
}

// ---------------------------------------------------------------------------
// 1. Score Distribution Tests
// ---------------------------------------------------------------------------

pub fn exact_match_vs_random_score_spread_test() {
  let base = bridge.new()

  let c1 =
    make_case(
      "case-1",
      "research",
      "property",
      ["dublin", "price"],
      "success",
      0.9,
    )
  let base = bridge.retain_case(base, c1)
  let metadata = dict.from_list([#("case-1", c1)])

  // Exact-match query
  let exact_query = make_query("research", "property", ["dublin", "price"])
  let exact_results =
    bridge.retrieve_cases(base, exact_query, metadata, weights(), 0.0)

  // Random/unrelated query
  let random_query =
    make_query("cooking", "cuisine", ["pasta", "tomato", "basil"])
  let random_results =
    bridge.retrieve_cases(base, random_query, metadata, weights(), 0.0)

  // Both should return the case (only 1 in the base)
  list.length(exact_results) |> should.equal(1)
  let assert [exact_top] = exact_results
  case random_results {
    [random_top, ..] -> {
      should.be_true(exact_top.score >. random_top.score)
    }
    [] -> {
      should.be_true(exact_top.score >. 0.0)
    }
  }
}

pub fn score_spread_is_meaningful_test() {
  let base = bridge.new()

  let c1 =
    make_case(
      "case-1",
      "research",
      "property",
      ["dublin", "price"],
      "success",
      0.9,
    )
  let c2 =
    make_case(
      "case-2",
      "coding",
      "software",
      ["rust", "compiler"],
      "success",
      0.8,
    )
  let c3 =
    make_case(
      "case-3",
      "writing",
      "journalism",
      ["article", "draft"],
      "failure",
      0.3,
    )
  let base = bridge.retain_case(base, c1)
  let base = bridge.retain_case(base, c2)
  let base = bridge.retain_case(base, c3)

  let metadata =
    dict.from_list([#("case-1", c1), #("case-2", c2), #("case-3", c3)])

  let query = make_query("research", "property", ["dublin", "price"])
  let results = bridge.retrieve_cases(base, query, metadata, weights(), 0.0)

  should.be_true(list.length(results) >= 2)
  let assert [best, ..] = results
  let assert Ok(worst) = list.last(results)

  // Spread between best and worst should be significant
  let spread = best.score -. worst.score
  should.be_true(spread >. 0.1)
}

// ---------------------------------------------------------------------------
// 2. Domain Signal Tests
// ---------------------------------------------------------------------------

pub fn domain_match_improves_ranking_test() {
  let base = bridge.new()

  let c1 =
    make_case("prop-1", "research", "property", ["market"], "success", 0.8)
  let c2 =
    make_case("prop-2", "analysis", "property", ["trends"], "success", 0.7)
  let c3 =
    make_case(
      "phys-1",
      "experiment",
      "physics",
      ["quantum", "entanglement"],
      "success",
      0.9,
    )
  let base = bridge.retain_case(base, c1)
  let base = bridge.retain_case(base, c2)
  let base = bridge.retain_case(base, c3)

  let metadata =
    dict.from_list([#("prop-1", c1), #("prop-2", c2), #("phys-1", c3)])

  let query = make_query("research", "property", ["market"])
  let results = bridge.retrieve_cases(base, query, metadata, weights(), 0.0)

  should.be_true(list.length(results) == 3)

  let prop1_score = list.find(results, fn(r) { r.cbr_case.case_id == "prop-1" })
  let phys_score = list.find(results, fn(r) { r.cbr_case.case_id == "phys-1" })

  case prop1_score, phys_score {
    Ok(p), Ok(ph) -> {
      should.be_true(p.score >. ph.score)
    }
    _, _ -> should.be_true(False)
  }
}

pub fn nonexistent_domain_still_returns_results_test() {
  let base = bridge.new()

  let c1 =
    make_case("case-1", "research", "property", ["market"], "success", 0.8)
  let base = bridge.retain_case(base, c1)
  let metadata = dict.from_list([#("case-1", c1)])

  let query = make_query("research", "underwater_basket_weaving", ["market"])
  let results = bridge.retrieve_cases(base, query, metadata, weights(), 0.0)

  should.be_true(list.length(results) >= 1)
}

// ---------------------------------------------------------------------------
// 3. Keyword Signal Tests
// ---------------------------------------------------------------------------

pub fn keyword_overlap_improves_score_test() {
  let base = bridge.new()

  let c1 =
    make_case(
      "target",
      "research",
      "property",
      ["dublin", "price", "commercial"],
      "success",
      0.8,
    )
  let c2 =
    make_case(
      "other1",
      "coding",
      "software",
      ["rust", "compiler", "wasm"],
      "success",
      0.7,
    )
  let c3 =
    make_case(
      "other2",
      "writing",
      "journalism",
      ["article", "draft", "editor"],
      "failure",
      0.5,
    )
  let base = bridge.retain_case(base, c1)
  let base = bridge.retain_case(base, c2)
  let base = bridge.retain_case(base, c3)
  let metadata =
    dict.from_list([#("target", c1), #("other1", c2), #("other2", c3)])

  let matching_query =
    make_query("research", "property", ["dublin", "price", "commercial"])
  let matching_results =
    bridge.retrieve_cases(base, matching_query, metadata, weights(), 0.0)

  should.be_true(list.length(matching_results) >= 1)

  let assert [top, ..] = matching_results
  top.cbr_case.case_id |> should.equal("target")
}

pub fn more_keywords_higher_score_test() {
  let base = bridge.new()

  let c_target =
    make_case(
      "target",
      "research",
      "property",
      ["dublin", "price", "commercial", "lease"],
      "success",
      0.8,
    )
  let c_partial =
    make_case(
      "partial",
      "research",
      "finance",
      ["dublin", "galway"],
      "success",
      0.7,
    )
  let c_none =
    make_case(
      "none",
      "coding",
      "software",
      ["rust", "compiler", "wasm", "llvm"],
      "success",
      0.6,
    )
  let base = bridge.retain_case(base, c_target)
  let base = bridge.retain_case(base, c_partial)
  let base = bridge.retain_case(base, c_none)
  let metadata =
    dict.from_list([
      #("target", c_target),
      #("partial", c_partial),
      #("none", c_none),
    ])

  let query =
    make_query("research", "property", [
      "dublin", "price", "commercial", "lease",
    ])
  let results = bridge.retrieve_cases(base, query, metadata, weights(), 0.0)

  should.be_true(list.length(results) >= 2)

  let assert [top, ..] = results
  top.cbr_case.case_id |> should.equal("target")

  let target_score =
    list.find(results, fn(r) { r.cbr_case.case_id == "target" })
  let partial_score =
    list.find(results, fn(r) { r.cbr_case.case_id == "partial" })

  case target_score, partial_score {
    Ok(t), Ok(p) -> {
      should.be_true(t.score >. p.score)
    }
    _, _ -> should.be_true(False)
  }
}

// ---------------------------------------------------------------------------
// 4. Empty/Edge Case Tests
// ---------------------------------------------------------------------------

pub fn retrieve_from_empty_returns_empty_test() {
  let base = bridge.new()

  let query = make_query("research", "property", ["market"])
  let results = bridge.retrieve_cases(base, query, dict.new(), weights(), 0.0)

  list.length(results) |> should.equal(0)
}

pub fn retain_case_with_empty_fields_test() {
  let base = bridge.new()

  let empty_case =
    CbrCase(
      case_id: "empty-case",
      timestamp: "",
      schema_version: 1,
      problem: CbrProblem(
        user_input: "",
        intent: "",
        domain: "",
        entities: [],
        keywords: [],
        query_complexity: "",
      ),
      solution: CbrSolution(
        approach: "",
        agents_used: [],
        tools_used: [],
        steps: [],
      ),
      outcome: CbrOutcome(
        status: "",
        confidence: 0.0,
        assessment: "",
        pitfalls: [],
      ),
      source_narrative_id: "",
      profile: None,
      redacted: False,
      category: None,
      usage_stats: None,
    )

  let base = bridge.retain_case(base, empty_case)
  // case_count tracks all retained case IDs, even those with no tokens
  bridge.case_count(base) |> should.equal(1)
}

pub fn query_with_empty_fields_test() {
  let base = bridge.new()

  let c1 =
    make_case("case-1", "research", "property", ["market"], "success", 0.8)
  let base = bridge.retain_case(base, c1)
  let metadata = dict.from_list([#("case-1", c1)])

  let empty_query =
    CbrQuery(
      intent: "",
      domain: "",
      keywords: [],
      entities: [],
      max_results: 10,
      query_complexity: None,
    )

  let results =
    bridge.retrieve_cases(base, empty_query, metadata, weights(), 0.0)
  // Recency signal alone should still produce results
  should.be_true(list.length(results) >= 1)
}

pub fn max_results_one_test() {
  let base = bridge.new()

  let c1 =
    make_case("case-1", "research", "property", ["market"], "success", 0.8)
  let c2 =
    make_case("case-2", "research", "property", ["price"], "success", 0.7)
  let c3 =
    make_case("case-3", "research", "property", ["lease"], "success", 0.6)
  let base = bridge.retain_case(base, c1)
  let base = bridge.retain_case(base, c2)
  let base = bridge.retain_case(base, c3)

  let metadata =
    dict.from_list([#("case-1", c1), #("case-2", c2), #("case-3", c3)])

  let query =
    CbrQuery(
      intent: "research",
      domain: "property",
      keywords: ["market"],
      entities: [],
      max_results: 1,
      query_complexity: None,
    )
  let results = bridge.retrieve_cases(base, query, metadata, weights(), 0.0)
  list.length(results) |> should.equal(1)
}

// ---------------------------------------------------------------------------
// 5. min_score Threshold Tests
// ---------------------------------------------------------------------------

pub fn zero_min_score_always_returns_test() {
  let base = bridge.new()

  let c1 =
    make_case("case-1", "research", "property", ["market"], "success", 0.8)
  let base = bridge.retain_case(base, c1)
  let metadata = dict.from_list([#("case-1", c1)])

  let query = make_query("cooking", "cuisine", ["pasta"])
  let results = bridge.retrieve_cases(base, query, metadata, weights(), 0.0)

  should.be_true(list.length(results) >= 1)
}

pub fn max_min_score_returns_empty_test() {
  let base = bridge.new()

  let c1 =
    make_case("case-1", "research", "property", ["market"], "success", 0.8)
  let base = bridge.retain_case(base, c1)
  let metadata = dict.from_list([#("case-1", c1)])

  let query = make_query("research", "property", ["market"])
  let results = bridge.retrieve_cases(base, query, metadata, weights(), 1.0)

  list.length(results) |> should.equal(0)
}

pub fn moderate_min_score_filters_weak_test() {
  let base = bridge.new()

  let c1 =
    make_case(
      "match",
      "research",
      "property",
      ["dublin", "price"],
      "success",
      0.9,
    )
  let c2 =
    make_case("weak", "cooking", "cuisine", ["pasta", "tomato"], "success", 0.5)
  let base = bridge.retain_case(base, c1)
  let base = bridge.retain_case(base, c2)

  let metadata = dict.from_list([#("match", c1), #("weak", c2)])

  let query = make_query("research", "property", ["dublin", "price"])

  let all_results = bridge.retrieve_cases(base, query, metadata, weights(), 0.0)
  should.be_true(list.length(all_results) == 2)

  let assert [best, worst] = all_results
  let mid_score = { best.score +. worst.score } /. 2.0

  let filtered_results =
    bridge.retrieve_cases(base, query, metadata, weights(), mid_score)
  list.length(filtered_results) |> should.equal(1)
  let assert [top] = filtered_results
  top.cbr_case.case_id |> should.equal("match")
}

// ---------------------------------------------------------------------------
// 6. Weight Parameter Tests (replaces RRF k tests)
// ---------------------------------------------------------------------------

pub fn different_weights_affect_ranking_test() {
  let base = bridge.new()

  // c1 matches on field/domain, c2 is more recent
  let c1 =
    CbrCase(
      ..make_case(
        "old-match",
        "research",
        "property",
        ["dublin", "price"],
        "success",
        0.9,
      ),
      timestamp: "2025-01-01T10:00:00",
    )
  let c2 =
    CbrCase(
      ..make_case("new-other", "coding", "software", ["rust"], "success", 0.5),
      timestamp: "2026-03-18T10:00:00",
    )
  let base = bridge.retain_case(base, c1)
  let base = bridge.retain_case(base, c2)

  let metadata = dict.from_list([#("old-match", c1), #("new-other", c2)])

  let query = make_query("research", "property", ["dublin", "price"])

  // Heavy field weights — old-match should win (despite being older)
  let field_heavy =
    bridge.RetrievalWeights(
      field_weight: 0.8,
      index_weight: 0.1,
      recency_weight: 0.05,
      domain_weight: 0.05,
      embedding_weight: 0.0,
      utility_weight: 0.0,
    )
  let field_results =
    bridge.retrieve_cases(base, query, metadata, field_heavy, 0.0)
  let assert [field_top, ..] = field_results
  field_top.cbr_case.case_id |> should.equal("old-match")

  // Heavy recency weights — new-other should win
  let recency_heavy =
    bridge.RetrievalWeights(
      field_weight: 0.0,
      index_weight: 0.0,
      recency_weight: 0.9,
      domain_weight: 0.0,
      embedding_weight: 0.1,
      utility_weight: 0.0,
    )
  let recency_results =
    bridge.retrieve_cases(base, query, metadata, recency_heavy, 0.0)
  let assert [recency_top, ..] = recency_results
  recency_top.cbr_case.case_id |> should.equal("new-other")
}

// ---------------------------------------------------------------------------
// 7. Recency Tests
// ---------------------------------------------------------------------------

pub fn newer_case_ranks_higher_test() {
  let base = bridge.new()

  let old_case =
    CbrCase(
      ..make_case("old", "research", "property", ["market"], "success", 0.8),
      timestamp: "2025-01-01T10:00:00",
    )
  let new_case =
    CbrCase(
      ..make_case("new", "research", "property", ["market"], "success", 0.8),
      timestamp: "2026-03-18T10:00:00",
    )

  let base = bridge.retain_case(base, old_case)
  let base = bridge.retain_case(base, new_case)

  let metadata = dict.from_list([#("old", old_case), #("new", new_case)])

  let query = make_query("research", "property", ["market"])
  let results = bridge.retrieve_cases(base, query, metadata, weights(), 0.0)

  should.be_true(list.length(results) == 2)
  let assert [top, ..] = results
  top.cbr_case.case_id |> should.equal("new")
}

// ---------------------------------------------------------------------------
// 8. CRUD Mutation Tests
// ---------------------------------------------------------------------------

pub fn remove_case_excludes_from_retrieval_test() {
  let base = bridge.new()

  let c1 = make_case("keep", "research", "property", ["market"], "success", 0.8)
  let c2 =
    make_case("remove", "research", "property", ["price"], "success", 0.7)
  let base = bridge.retain_case(base, c1)
  let base = bridge.retain_case(base, c2)

  bridge.case_count(base) |> should.equal(2)

  let base = bridge.remove_case(base, "remove")
  bridge.case_count(base) |> should.equal(1)

  let metadata = dict.from_list([#("keep", c1)])

  let query = make_query("research", "property", ["market", "price"])
  let results = bridge.retrieve_cases(base, query, metadata, weights(), 0.0)

  let ids = list.map(results, fn(r) { r.cbr_case.case_id })
  list.contains(ids, "remove") |> should.be_false
  list.contains(ids, "keep") |> should.be_true
}

// ---------------------------------------------------------------------------
// 9. Deterministic Scoring Tests (replaces VSA distance tests)
// ---------------------------------------------------------------------------

pub fn field_scoring_is_deterministic_test() {
  let c1 =
    make_case(
      "case-a",
      "research",
      "property",
      ["dublin", "price"],
      "success",
      0.9,
    )
  let query = make_query("research", "property", ["dublin", "price"])

  // Score should be identical across multiple calls
  let s1 = bridge.weighted_field_score(query, c1)
  let s2 = bridge.weighted_field_score(query, c1)
  should.be_true(float.absolute_value(s1 -. s2) <. 0.001)
}

pub fn similar_cases_have_high_similarity_test() {
  let c1 =
    make_case(
      "case-a",
      "research",
      "property",
      ["dublin", "price"],
      "success",
      0.9,
    )
  let c2 =
    make_case(
      "case-b",
      "research",
      "property",
      ["dublin", "rent"],
      "success",
      0.7,
    )
  let sim = bridge.case_similarity(c1, c2)
  // Same intent + domain = 0.6, partial keyword overlap, success status
  should.be_true(sim >. 0.5)
}

pub fn different_cases_have_low_similarity_test() {
  let c1 =
    make_case(
      "case-a",
      "research",
      "property",
      ["dublin", "price"],
      "success",
      0.9,
    )
  let c2 =
    make_case(
      "case-b",
      "coding",
      "software",
      ["rust", "compiler"],
      "failure",
      0.3,
    )
  let sim = bridge.case_similarity(c1, c2)
  should.be_true(sim <. 0.2)
}

// ---------------------------------------------------------------------------
// 10. Inverted Index Tests
// ---------------------------------------------------------------------------

pub fn approach_text_is_indexed_test() {
  let base = bridge.new()

  let c1 =
    CbrCase(
      ..make_case("case-1", "research", "property", [], "success", 0.8),
      solution: CbrSolution(
        approach: "comprehensive market analysis using multiple sources",
        agents_used: [],
        tools_used: [],
        steps: [],
      ),
    )
  let c2 =
    CbrCase(
      ..make_case("case-2", "research", "property", [], "success", 0.7),
      solution: CbrSolution(
        approach: "quick database lookup",
        agents_used: [],
        tools_used: [],
        steps: [],
      ),
    )
  let base = bridge.retain_case(base, c1)
  let base = bridge.retain_case(base, c2)

  let metadata = dict.from_list([#("case-1", c1), #("case-2", c2)])

  let query =
    CbrQuery(
      intent: "",
      domain: "",
      keywords: ["analysis"],
      entities: [],
      max_results: 10,
      query_complexity: None,
    )
  let results = bridge.retrieve_cases(base, query, metadata, weights(), 0.0)

  should.be_true(list.length(results) >= 1)
  let assert [top, ..] = results
  top.cbr_case.case_id |> should.equal("case-1")
}

pub fn short_words_not_indexed_test() {
  let base = bridge.new()

  let c1 =
    CbrCase(
      ..make_case("case-1", "research", "property", [], "success", 0.8),
      solution: CbrSolution(
        approach: "we do it by an ok go",
        agents_used: [],
        tools_used: [],
        steps: [],
      ),
    )
  let base = bridge.retain_case(base, c1)

  let metadata = dict.from_list([#("case-1", c1)])

  let query =
    CbrQuery(
      intent: "",
      domain: "",
      keywords: ["we", "do", "it", "by", "an", "ok", "go"],
      entities: [],
      max_results: 10,
      query_complexity: None,
    )
  let results = bridge.retrieve_cases(base, query, metadata, weights(), 0.0)

  let long_word_query =
    CbrQuery(
      intent: "",
      domain: "",
      keywords: ["research"],
      entities: [],
      max_results: 10,
      query_complexity: None,
    )
  let long_results =
    bridge.retrieve_cases(base, long_word_query, metadata, weights(), 0.0)

  case results, long_results {
    [short_top], [long_top] -> {
      should.be_true(
        long_top.score >=. short_top.score
        || float.absolute_value(long_top.score -. short_top.score) <. 0.001,
      )
    }
    _, _ -> {
      Nil
    }
  }
}
