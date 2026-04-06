//// CBR bridge — weighted field scoring + inverted index for hybrid retrieval.
////
//// Retrieval uses four signals fused by weighted sum (not RRF):
////   1. Weighted field score — deterministic structural similarity
////   2. Inverted index — token overlap (keywords, entities, tools, agents)
////   3. Recency — newer cases ranked higher
////   4. Domain — exact domain match boost
////
//// Optional 5th signal (embedding) can be plugged in via embed_fn.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import cbr/types.{type CbrCase, type CbrQuery, type ScoredCase, ScoredCase}
import dprime/decay
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set
import gleam/string

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// In-memory CBR store. Owned by the Librarian.
pub type CaseBase {
  CaseBase(
    // Tracked case IDs (for accurate case_count regardless of token coverage)
    case_ids: set.Set(String),
    // Inverted index — token → list of case_ids
    index: Dict(String, List(String)),
    // Optional semantic embeddings — case_id → vector
    embeddings: Dict(String, List(Float)),
    // Optional embedding function
    embed_fn: Option(fn(String) -> Result(List(Float), String)),
  )
}

/// Weights for each retrieval signal. All should be >= 0.0.
/// When embeddings are unavailable, embedding_weight is redistributed.
pub type RetrievalWeights {
  RetrievalWeights(
    field_weight: Float,
    index_weight: Float,
    recency_weight: Float,
    domain_weight: Float,
    embedding_weight: Float,
    utility_weight: Float,
  )
}

/// Default retrieval weights. Must sum to 1.0.
/// Tuned from experiment-3 ablation: index+embedding dominates.
/// When embeddings unavailable, weights are renormalized automatically.
pub fn default_weights() -> RetrievalWeights {
  RetrievalWeights(
    field_weight: 0.1,
    index_weight: 0.25,
    recency_weight: 0.05,
    domain_weight: 0.1,
    embedding_weight: 0.4,
    utility_weight: 0.1,
  )
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// Create a new empty CaseBase.
pub fn new() -> CaseBase {
  CaseBase(
    case_ids: set.new(),
    index: dict.new(),
    embeddings: dict.new(),
    embed_fn: None,
  )
}

/// Create a CaseBase with an embedding function.
pub fn new_with_embeddings(
  embed_fn: fn(String) -> Result(List(Float), String),
) -> CaseBase {
  CaseBase(
    case_ids: set.new(),
    index: dict.new(),
    embeddings: dict.new(),
    embed_fn: Some(embed_fn),
  )
}

/// Rebuild the inverted index from a list of cases (after loading metadata).
/// Also rebuilds the case_ids set.
pub fn rebuild_index(base: CaseBase, cases: List(CbrCase)) -> CaseBase {
  let case_ids =
    list.fold(cases, set.new(), fn(ids, c) { set.insert(ids, c.case_id) })
  let index =
    list.fold(cases, dict.new(), fn(idx, c) {
      let tokens = case_tokens(c)
      list.fold(tokens, idx, fn(idx2, tok) {
        let existing = dict.get(idx2, tok) |> result.unwrap([])
        dict.insert(idx2, tok, [c.case_id, ..existing])
      })
    })
  CaseBase(..base, case_ids:, index:)
}

// ---------------------------------------------------------------------------
// Retain — add a new case to the CaseBase
// ---------------------------------------------------------------------------

/// Add a CbrCase to the CaseBase (inverted index + optional embedding).
/// Returns the updated CaseBase.
pub fn retain_case(base: CaseBase, cbr_case: CbrCase) -> CaseBase {
  // Track case ID
  let case_ids = set.insert(base.case_ids, cbr_case.case_id)

  // Update inverted index
  let tokens = case_tokens(cbr_case)
  let index =
    list.fold(tokens, base.index, fn(idx, tok) {
      let existing = dict.get(idx, tok) |> result.unwrap([])
      dict.insert(idx, tok, [cbr_case.case_id, ..existing])
    })

  // Compute embedding if embed_fn is available
  let embeddings = case base.embed_fn {
    None -> base.embeddings
    Some(embed) -> {
      let text = case_text(cbr_case)
      case embed(text) {
        Ok(vec) -> dict.insert(base.embeddings, cbr_case.case_id, vec)
        Error(_) -> base.embeddings
      }
    }
  }

  CaseBase(..base, case_ids:, index:, embeddings:)
}

// ---------------------------------------------------------------------------
// Retrieve — find similar cases
// ---------------------------------------------------------------------------

/// Retrieve cases matching a query, scored by weighted sum of multiple signals.
/// Returns ScoredCase list sorted by score descending.
/// When cbr_decay_half_life_days > 0 and today is provided, outcome confidence
/// is decayed by half-life before contributing to the score.
pub fn retrieve_cases(
  base: CaseBase,
  query: CbrQuery,
  metadata: Dict(String, CbrCase),
  weights: RetrievalWeights,
  min_score: Float,
) -> List(ScoredCase) {
  retrieve_cases_with_decay(base, query, metadata, weights, min_score, 0, "")
}

/// Retrieve cases with confidence decay applied to outcome confidence.
pub fn retrieve_cases_with_decay(
  base: CaseBase,
  query: CbrQuery,
  metadata: Dict(String, CbrCase),
  weights: RetrievalWeights,
  min_score: Float,
  cbr_decay_half_life_days: Int,
  today: String,
) -> List(ScoredCase) {
  let max_results = query.max_results
  let case_ids = dict.keys(metadata)

  case case_ids {
    [] -> []
    _ -> {
      // Signal 1: Weighted field scoring (0.0–1.0)
      // When decay is enabled, outcome confidence is decayed before scoring
      let field_scores =
        list.map(case_ids, fn(id) {
          case dict.get(metadata, id) {
            Ok(c) -> #(
              id,
              weighted_field_score_with_decay(
                query,
                c,
                cbr_decay_half_life_days,
                today,
              ),
            )
            Error(_) -> #(id, 0.0)
          }
        })

      // Signal 2: Inverted index overlap (normalized 0.0–1.0)
      let index_scores = index_score(base, query, case_ids)

      // Signal 3: Recency (normalized 0.0–1.0)
      let recency_scores = recency_score(metadata, case_ids)

      // Signal 4: Domain match (0.0 or 1.0)
      let domain_scores = domain_score(query.domain, metadata, case_ids)

      // Signal 5: Embedding similarity (0.0–1.0, if available)
      let has_embeddings = !dict.is_empty(base.embeddings)
      let embedding_scores = case has_embeddings {
        True -> embedding_score(base, query, case_ids)
        False -> list.map(case_ids, fn(id) { #(id, 0.0) })
      }

      // Signal 6: Utility score from usage stats (0.0–1.0, Laplace smoothed)
      let utility_scores = utility_score_signal(metadata, case_ids)

      // Compute effective weights (renormalize when embeddings unavailable)
      let #(w_field, w_index, w_recency, w_domain, w_embed, w_utility) = case
        has_embeddings
      {
        True -> #(
          weights.field_weight,
          weights.index_weight,
          weights.recency_weight,
          weights.domain_weight,
          weights.embedding_weight,
          weights.utility_weight,
        )
        False -> {
          let sum =
            weights.field_weight
            +. weights.index_weight
            +. weights.recency_weight
            +. weights.domain_weight
            +. weights.utility_weight
          case sum >. 0.0 {
            True -> #(
              weights.field_weight /. sum,
              weights.index_weight /. sum,
              weights.recency_weight /. sum,
              weights.domain_weight /. sum,
              0.0,
              weights.utility_weight /. sum,
            )
            False -> #(0.25, 0.25, 0.25, 0.25, 0.0, 0.0)
          }
        }
      }

      // Convert score lists to dicts for lookup
      let field_d = dict.from_list(field_scores)
      let index_d = dict.from_list(index_scores)
      let recency_d = dict.from_list(recency_scores)
      let domain_d = dict.from_list(domain_scores)
      let embed_d = dict.from_list(embedding_scores)
      let utility_d = dict.from_list(utility_scores)

      // Compute final weighted sum
      let scored =
        list.map(case_ids, fn(id) {
          let f = dict.get(field_d, id) |> result.unwrap(0.0)
          let i = dict.get(index_d, id) |> result.unwrap(0.0)
          let r = dict.get(recency_d, id) |> result.unwrap(0.0)
          let d = dict.get(domain_d, id) |> result.unwrap(0.0)
          let e = dict.get(embed_d, id) |> result.unwrap(0.0)
          let u = dict.get(utility_d, id) |> result.unwrap(0.5)
          let score =
            w_field
            *. f
            +. w_index
            *. i
            +. w_recency
            *. r
            +. w_domain
            *. d
            +. w_embed
            *. e
            +. w_utility
            *. u
          #(id, score)
        })

      // Sort by score descending
      let sorted =
        list.sort(scored, fn(a, b) {
          case a.1 >. b.1 {
            True -> order.Lt
            False ->
              case a.1 <. b.1 {
                True -> order.Gt
                False -> order.Eq
              }
          }
        })

      // Filter by min_score, take max_results, resolve to ScoredCase
      sorted
      |> list.filter(fn(pair) { pair.1 >=. min_score })
      |> list.take(max_results)
      |> list.filter_map(fn(pair) {
        case dict.get(metadata, pair.0) {
          Ok(cbr_case) -> Ok(ScoredCase(score: pair.1, cbr_case:))
          Error(_) -> Error(Nil)
        }
      })
    }
  }
}

// ---------------------------------------------------------------------------
// Weighted field scoring (deterministic, pure)
// ---------------------------------------------------------------------------

/// Score a case against a query using weighted field comparison.
/// Returns a value in 0.0–1.0.
pub fn weighted_field_score(query: CbrQuery, cbr_case: CbrCase) -> Float {
  let intent_score = case
    string.lowercase(query.intent) == string.lowercase(cbr_case.problem.intent)
  {
    True -> 0.3
    False -> 0.0
  }
  let domain_score = case
    string.lowercase(query.domain) == string.lowercase(cbr_case.problem.domain)
  {
    True -> 0.3
    False -> 0.0
  }
  let keyword_score =
    jaccard(
      list.map(query.keywords, string.lowercase),
      list.map(cbr_case.problem.keywords, string.lowercase),
    )
    *. 0.2
  let entity_score =
    jaccard(
      list.map(query.entities, string.lowercase),
      list.map(cbr_case.problem.entities, string.lowercase),
    )
    *. 0.1
  let status_score = case cbr_case.outcome.status {
    "success" -> 0.1
    _ -> 0.0
  }

  intent_score +. domain_score +. keyword_score +. entity_score +. status_score
}

/// Score a case against a query with confidence decay applied to outcome.
/// When cbr_decay_half_life_days <= 0 or today is empty, behaves identically
/// to weighted_field_score.
pub fn weighted_field_score_with_decay(
  query: CbrQuery,
  cbr_case: CbrCase,
  cbr_decay_half_life_days: Int,
  today: String,
) -> Float {
  let intent_score = case
    string.lowercase(query.intent) == string.lowercase(cbr_case.problem.intent)
  {
    True -> 0.3
    False -> 0.0
  }
  let domain_score = case
    string.lowercase(query.domain) == string.lowercase(cbr_case.problem.domain)
  {
    True -> 0.3
    False -> 0.0
  }
  let keyword_score =
    jaccard(
      list.map(query.keywords, string.lowercase),
      list.map(cbr_case.problem.keywords, string.lowercase),
    )
    *. 0.2
  let entity_score =
    jaccard(
      list.map(query.entities, string.lowercase),
      list.map(cbr_case.problem.entities, string.lowercase),
    )
    *. 0.1

  // Apply confidence decay to the status score component
  let effective_confidence = case cbr_decay_half_life_days > 0 && today != "" {
    True ->
      decay.decay_fact_confidence(
        cbr_case.outcome.confidence,
        cbr_case.timestamp,
        today,
        cbr_decay_half_life_days,
      )
    False -> cbr_case.outcome.confidence
  }
  // Status score weighted by decayed confidence (max 0.1)
  let status_score = case cbr_case.outcome.status {
    "success" -> 0.1 *. effective_confidence
    _ -> 0.0
  }

  intent_score +. domain_score +. keyword_score +. entity_score +. status_score
}

/// Jaccard similarity between two lists (|intersection| / |union|).
/// Returns 0.0 for empty inputs.
pub fn jaccard(a: List(String), b: List(String)) -> Float {
  case a, b {
    [], _ -> 0.0
    _, [] -> 0.0
    _, _ -> {
      let set_a = set.from_list(a)
      let set_b = set.from_list(b)
      let intersection_size =
        set.intersection(set_a, set_b)
        |> set.size
      let union_size =
        set.union(set_a, set_b)
        |> set.size
      case union_size {
        0 -> 0.0
        _ -> int.to_float(intersection_size) /. int.to_float(union_size)
      }
    }
  }
}

/// Cosine similarity between two vectors.
/// Returns 0.0 if either vector is zero-length or vectors have different lengths.
pub fn cosine_similarity(a: List(Float), b: List(Float)) -> Float {
  case list.length(a) == list.length(b) && !list.is_empty(a) {
    False -> 0.0
    True -> {
      let pairs = list.zip(a, b)
      let dot = list.fold(pairs, 0.0, fn(acc, pair) { acc +. pair.0 *. pair.1 })
      let mag_a =
        list.fold(a, 0.0, fn(acc, x) { acc +. x *. x })
        |> float_sqrt
      let mag_b =
        list.fold(b, 0.0, fn(acc, x) { acc +. x *. x })
        |> float_sqrt
      case mag_a *. mag_b {
        0.0 -> 0.0
        denom -> dot /. denom
      }
    }
  }
}

/// Symmetric similarity between two cases using weighted field comparison.
/// Returns the average of scoring A→B and B→A, giving a value in 0.0–1.0.
/// Used by housekeeping for deduplication.
pub fn case_similarity(case_a: CbrCase, case_b: CbrCase) -> Float {
  let query_a =
    types.CbrQuery(
      intent: case_a.problem.intent,
      domain: case_a.problem.domain,
      keywords: case_a.problem.keywords,
      entities: case_a.problem.entities,
      max_results: 1,
      query_complexity: None,
    )
  let query_b =
    types.CbrQuery(
      intent: case_b.problem.intent,
      domain: case_b.problem.domain,
      keywords: case_b.problem.keywords,
      entities: case_b.problem.entities,
      max_results: 1,
      query_complexity: None,
    )
  let score_ab = weighted_field_score(query_a, case_b)
  let score_ba = weighted_field_score(query_b, case_a)
  { score_ab +. score_ba } /. 2.0
}

// ---------------------------------------------------------------------------
// Inverted index scoring
// ---------------------------------------------------------------------------

/// Extract tokens for the inverted index from a CbrCase.
pub fn case_tokens(c: CbrCase) -> List(String) {
  let kw_tokens = list.map(c.problem.keywords, string.lowercase)
  let entity_tokens = list.map(c.problem.entities, string.lowercase)
  let tool_tokens = list.map(c.solution.tools_used, string.lowercase)
  let agent_tokens = list.map(c.solution.agents_used, string.lowercase)
  let intent_tokens = case c.problem.intent {
    "" -> []
    i -> [string.lowercase(i)]
  }
  let domain_tokens = case c.problem.domain {
    "" -> []
    d -> [string.lowercase(d)]
  }
  // Tokenise approach into individual words for the inverted index
  let approach_tokens = case c.solution.approach {
    "" -> []
    a ->
      a
      |> string.lowercase
      |> string.split(" ")
      |> list.filter(fn(w) { string.length(w) > 2 })
  }
  // Include query_complexity as a token
  let complexity_tokens = case c.problem.query_complexity {
    "" -> []
    qc -> [string.lowercase(qc)]
  }
  list.flatten([
    kw_tokens,
    entity_tokens,
    tool_tokens,
    agent_tokens,
    intent_tokens,
    domain_tokens,
    approach_tokens,
    complexity_tokens,
  ])
  |> list.unique
}

/// Score cases by token overlap with query. Returns normalized (0.0–1.0) scores.
fn index_score(
  base: CaseBase,
  query: CbrQuery,
  case_ids: List(String),
) -> List(#(String, Float)) {
  let complexity_tokens = case query.query_complexity {
    Some(qc) ->
      case qc {
        "" -> []
        _ -> [string.lowercase(qc)]
      }
    None -> []
  }
  let query_tokens =
    list.flatten([
      list.map(query.keywords, string.lowercase),
      list.map(query.entities, string.lowercase),
      case query.intent {
        "" -> []
        i -> [string.lowercase(i)]
      },
      case query.domain {
        "" -> []
        d -> [string.lowercase(d)]
      },
      complexity_tokens,
    ])
    |> list.unique

  let total_query_tokens = int.to_float(list.length(query_tokens))

  // Count how many query tokens each case matches
  let hit_counts =
    list.fold(query_tokens, dict.new(), fn(counts, tok) {
      case dict.get(base.index, tok) {
        Error(_) -> counts
        Ok(matching_ids) ->
          list.fold(matching_ids, counts, fn(c, id) {
            let current = dict.get(c, id) |> result.unwrap(0)
            dict.insert(c, id, current + 1)
          })
      }
    })

  // Normalize: hits / total_query_tokens
  list.map(case_ids, fn(id) {
    let hits = dict.get(hit_counts, id) |> result.unwrap(0)
    let score = case total_query_tokens >. 0.0 {
      True -> int.to_float(hits) /. total_query_tokens
      False -> 0.0
    }
    #(id, score)
  })
}

// ---------------------------------------------------------------------------
// Recency scoring
// ---------------------------------------------------------------------------

/// Score cases by timestamp (newer = higher score, normalized 0.0–1.0).
fn recency_score(
  metadata: Dict(String, CbrCase),
  case_ids: List(String),
) -> List(#(String, Float)) {
  // Sort by timestamp descending
  let with_timestamps =
    list.filter_map(case_ids, fn(id) {
      case dict.get(metadata, id) {
        Ok(c) -> Ok(#(id, c.timestamp))
        Error(_) -> Error(Nil)
      }
    })
    |> list.sort(fn(a, b) { string.compare(b.1, a.1) })

  let n = list.length(with_timestamps)
  case n {
    0 -> []
    1 -> list.map(with_timestamps, fn(pair) { #(pair.0, 1.0) })
    _ -> {
      let n_f = int.to_float(n - 1)
      list.index_map(with_timestamps, fn(pair, idx) {
        let score = case n_f >. 0.0 {
          True -> { n_f -. int.to_float(idx) } /. n_f
          False -> 1.0
        }
        #(pair.0, score)
      })
    }
  }
}

// ---------------------------------------------------------------------------
// Domain scoring
// ---------------------------------------------------------------------------

/// Score cases by exact domain match (1.0 for match, 0.0 for mismatch).
fn domain_score(
  query_domain: String,
  metadata: Dict(String, CbrCase),
  case_ids: List(String),
) -> List(#(String, Float)) {
  let lower_domain = string.lowercase(query_domain)
  list.map(case_ids, fn(id) {
    case dict.get(metadata, id) {
      Ok(c) ->
        case
          lower_domain != ""
          && string.lowercase(c.problem.domain) == lower_domain
        {
          True -> #(id, 1.0)
          False -> #(id, 0.0)
        }
      Error(_) -> #(id, 0.0)
    }
  })
}

// ---------------------------------------------------------------------------
// Embedding scoring
// ---------------------------------------------------------------------------

/// Score cases by cosine similarity to query embedding (0.0–1.0).
fn embedding_score(
  base: CaseBase,
  query: CbrQuery,
  case_ids: List(String),
) -> List(#(String, Float)) {
  let query_text =
    query.intent
    <> " "
    <> query.domain
    <> " "
    <> string.join(query.keywords, " ")

  case base.embed_fn {
    None -> list.map(case_ids, fn(id) { #(id, 0.0) })
    Some(embed) ->
      case embed(query_text) {
        Error(_) -> list.map(case_ids, fn(id) { #(id, 0.0) })
        Ok(query_vec) ->
          list.map(case_ids, fn(id) {
            case dict.get(base.embeddings, id) {
              Ok(case_vec) -> {
                let sim = cosine_similarity(query_vec, case_vec)
                // Clamp to 0.0–1.0 (cosine can be negative for unrelated texts)
                #(id, float.max(0.0, sim))
              }
              Error(_) -> #(id, 0.0)
            }
          })
      }
  }
}

// ---------------------------------------------------------------------------
// Utility scoring (from usage stats)
// ---------------------------------------------------------------------------

/// Score cases by utility using Laplace-smoothed retrieval success rate.
/// Returns (0.0–1.0) per case. Cases without usage stats get 0.5 (neutral).
fn utility_score_signal(
  metadata: Dict(String, CbrCase),
  case_ids: List(String),
) -> List(#(String, Float)) {
  list.map(case_ids, fn(id) {
    case dict.get(metadata, id) {
      Ok(c) -> #(id, types.utility_score(c.usage_stats))
      Error(_) -> #(id, 0.5)
    }
  })
}

// ---------------------------------------------------------------------------
// Cleanup / mutation
// ---------------------------------------------------------------------------

/// Remove a case from the CaseBase.
pub fn remove_case(base: CaseBase, case_id: String) -> CaseBase {
  // Remove from tracked IDs
  let case_ids = set.delete(base.case_ids, case_id)

  // Remove from inverted index, filtering out empty posting lists
  let index =
    dict.map_values(base.index, fn(_tok, ids) {
      list.filter(ids, fn(id) { id != case_id })
    })
    |> dict.filter(fn(_tok, ids) { !list.is_empty(ids) })

  // Remove from embeddings
  let embeddings = dict.delete(base.embeddings, case_id)

  CaseBase(..base, case_ids:, index:, embeddings:)
}

/// Get the number of cases in the CaseBase.
pub fn case_count(base: CaseBase) -> Int {
  set.size(base.case_ids)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build text representation of a case for embedding.
fn case_text(c: CbrCase) -> String {
  c.problem.intent
  <> " "
  <> c.problem.domain
  <> " "
  <> string.join(c.problem.keywords, " ")
}

fn float_sqrt(x: Float) -> Float {
  do_float_sqrt(x)
}

@external(erlang, "math", "sqrt")
fn do_float_sqrt(x: Float) -> Float
