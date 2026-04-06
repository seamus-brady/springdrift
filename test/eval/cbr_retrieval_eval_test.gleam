//// CBR Retrieval Quality Evaluation — Leave-One-Out Signal Ablation
////
//// Loads all CBR cases from disk, performs leave-one-out evaluation
//// (each case as query against the rest), measures retrieval quality
//// under different signal weight configurations.
////
//// Outputs JSONL to evals/results/cbr_retrieval.jsonl for Python analysis.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import cbr/bridge
import cbr/log as cbr_log
import cbr/types.{type CbrCase, type CbrQuery, CbrQuery, ScoredCase}
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Weight configurations for ablation
// ---------------------------------------------------------------------------

fn full_weights() -> bridge.RetrievalWeights {
  bridge.default_weights()
}

fn field_only() -> bridge.RetrievalWeights {
  bridge.RetrievalWeights(
    field_weight: 1.0,
    index_weight: 0.0,
    recency_weight: 0.0,
    domain_weight: 0.0,
    embedding_weight: 0.0,
    utility_weight: 0.0,
  )
}

fn index_only() -> bridge.RetrievalWeights {
  bridge.RetrievalWeights(
    field_weight: 0.0,
    index_weight: 1.0,
    recency_weight: 0.0,
    domain_weight: 0.0,
    embedding_weight: 0.0,
    utility_weight: 0.0,
  )
}

fn recency_only() -> bridge.RetrievalWeights {
  bridge.RetrievalWeights(
    field_weight: 0.0,
    index_weight: 0.0,
    recency_weight: 1.0,
    domain_weight: 0.0,
    embedding_weight: 0.0,
    utility_weight: 0.0,
  )
}

fn domain_only() -> bridge.RetrievalWeights {
  bridge.RetrievalWeights(
    field_weight: 0.0,
    index_weight: 0.0,
    recency_weight: 0.0,
    domain_weight: 1.0,
    embedding_weight: 0.0,
    utility_weight: 0.0,
  )
}

fn field_index() -> bridge.RetrievalWeights {
  bridge.RetrievalWeights(
    field_weight: 0.5,
    index_weight: 0.5,
    recency_weight: 0.0,
    domain_weight: 0.0,
    embedding_weight: 0.0,
    utility_weight: 0.0,
  )
}

// ---------------------------------------------------------------------------
// Case → Query conversion
// ---------------------------------------------------------------------------

fn case_to_query(c: CbrCase) -> CbrQuery {
  CbrQuery(
    intent: c.problem.intent,
    domain: c.problem.domain,
    keywords: c.problem.keywords,
    entities: c.problem.entities,
    max_results: 4,
    query_complexity: None,
  )
}

/// Two cases are relevant if they share the same domain.
fn is_relevant(query_case: CbrCase, other: CbrCase) -> Bool {
  query_case.problem.domain == other.problem.domain
  && query_case.case_id != other.case_id
}

// ---------------------------------------------------------------------------
// Metrics
// ---------------------------------------------------------------------------

fn precision_at_k(
  relevant_ids: List(String),
  retrieved_ids: List(String),
  k: Int,
) -> Float {
  let top_k = list.take(retrieved_ids, k)
  let hits = list.count(top_k, fn(id) { list.contains(relevant_ids, id) })
  case k {
    0 -> 0.0
    _ -> int.to_float(hits) /. int.to_float(k)
  }
}

fn reciprocal_rank(
  relevant_ids: List(String),
  retrieved_ids: List(String),
) -> Float {
  find_rr(relevant_ids, retrieved_ids, 1)
}

fn find_rr(
  relevant_ids: List(String),
  retrieved_ids: List(String),
  rank: Int,
) -> Float {
  case retrieved_ids {
    [] -> 0.0
    [id, ..rest] ->
      case list.contains(relevant_ids, id) {
        True -> 1.0 /. int.to_float(rank)
        False -> find_rr(relevant_ids, rest, rank + 1)
      }
  }
}

// ---------------------------------------------------------------------------
// Main evaluation
// ---------------------------------------------------------------------------

pub fn cbr_retrieval_ablation_test() {
  let cbr_dir = ".springdrift/memory/cbr"
  let all_cases = cbr_log.load_all(cbr_dir)
  let n = list.length(all_cases)

  io.println("CBR Retrieval Eval: " <> int.to_string(n) <> " cases loaded")

  case n < 10 {
    True -> {
      io.println("SKIP: Need at least 10 cases")
      Nil
    }
    False -> {
      let configs = [
        #("full_6signal", full_weights()),
        #("field_only", field_only()),
        #("index_only", index_only()),
        #("recency_only", recency_only()),
        #("domain_only", domain_only()),
        #("field_index", field_index()),
      ]

      // Sample 50 cases as queries (full LOO on 427 is O(n²) and too slow)
      let query_cases = list.take(all_cases, 50)

      let results =
        list.map(configs, fn(config) {
          let #(name, weights) = config
          let metrics = run_loo_sampled(query_cases, all_cases, weights, 4)
          io.println(
            name
            <> ": P@4="
            <> float.to_string(metrics.mean_precision)
            <> " MRR="
            <> float.to_string(metrics.mean_mrr)
            <> " R@4="
            <> float.to_string(metrics.mean_recall),
          )
          #(name, metrics)
        })

      let jsonl =
        list.map(results, fn(r) {
          let #(name, m) = r
          json.to_string(
            json.object([
              #("config", json.string(name)),
              #("n_cases", json.int(n)),
              #("n_queries", json.int(m.n_queries)),
              #("mean_precision_at_4", json.float(m.mean_precision)),
              #("mean_mrr", json.float(m.mean_mrr)),
              #("mean_recall_at_4", json.float(m.mean_recall)),
              #("queries_with_results", json.int(m.queries_with_results)),
              #("queries_with_relevant", json.int(m.queries_with_relevant)),
            ]),
          )
        })
        |> string.join("\n")

      let _ = simplifile.write("evals/results/cbr_retrieval.jsonl", jsonl)
      io.println("Written to evals/results/cbr_retrieval.jsonl")
      Nil
    }
  }
}

// ---------------------------------------------------------------------------
// Leave-one-out
// ---------------------------------------------------------------------------

pub type EvalMetrics {
  EvalMetrics(
    n_queries: Int,
    mean_precision: Float,
    mean_mrr: Float,
    mean_recall: Float,
    queries_with_results: Int,
    queries_with_relevant: Int,
  )
}

fn run_loo_sampled(
  query_cases: List(CbrCase),
  all_cases: List(CbrCase),
  weights: bridge.RetrievalWeights,
  k: Int,
) -> EvalMetrics {
  // Build case base once from all cases (query case is still in base,
  // but we exclude it from relevance scoring)
  let base = build_base(all_cases)
  let metadata = build_meta(all_cases)

  let results =
    list.map(query_cases, fn(query_case) {
      let other_cases =
        list.filter(all_cases, fn(c) { c.case_id != query_case.case_id })
      let query = case_to_query(query_case)

      let retrieved = bridge.retrieve_cases(base, query, metadata, weights, 0.0)
      let retrieved_ids =
        list.map(retrieved, fn(sc) {
          let ScoredCase(cbr_case: c, ..) = sc
          c.case_id
        })

      let relevant_ids =
        list.filter_map(other_cases, fn(c) {
          case is_relevant(query_case, c) {
            True -> Ok(c.case_id)
            False -> Error(Nil)
          }
        })

      let p = precision_at_k(relevant_ids, retrieved_ids, k)
      let mrr = reciprocal_rank(relevant_ids, retrieved_ids)
      let recall = case relevant_ids {
        [] -> 0.0
        _ -> {
          let total = list.length(relevant_ids)
          let top_k = list.take(retrieved_ids, k)
          let hits =
            list.count(top_k, fn(id) { list.contains(relevant_ids, id) })
          int.to_float(hits) /. int.to_float(int.min(total, k))
        }
      }
      let has_results = retrieved_ids != []
      let has_relevant = relevant_ids != []

      #(p, mrr, recall, has_results, has_relevant)
    })

  let n = list.length(results)
  let n_f = int.to_float(int.max(n, 1))
  let sum_p = list.fold(results, 0.0, fn(acc, r) { acc +. r.0 })
  let sum_mrr = list.fold(results, 0.0, fn(acc, r) { acc +. r.1 })
  let sum_recall = list.fold(results, 0.0, fn(acc, r) { acc +. r.2 })
  let with_results = list.count(results, fn(r) { r.3 })
  let with_relevant = list.count(results, fn(r) { r.4 })

  EvalMetrics(
    n_queries: n,
    mean_precision: sum_p /. n_f,
    mean_mrr: sum_mrr /. n_f,
    mean_recall: sum_recall /. n_f,
    queries_with_results: with_results,
    queries_with_relevant: with_relevant,
  )
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn build_base(cases: List(CbrCase)) -> bridge.CaseBase {
  list.fold(cases, bridge.new(), fn(base, c) { bridge.retain_case(base, c) })
}

fn build_meta(cases: List(CbrCase)) -> Dict(String, CbrCase) {
  list.fold(cases, dict.new(), fn(d, c) { dict.insert(d, c.case_id, c) })
}
