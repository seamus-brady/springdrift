//// Affect-Performance Correlation Engine — meta-learning Phase D.
////
//// Joins affect snapshots and narrative entries by cycle_id and computes
//// Pearson correlations between each affect dimension and outcome
//// success (1.0) / failure (0.0), grouped by task domain. The result
//// tells the agent whether, e.g., high pressure in a "research" domain
//// reliably predicts failure — a maladaptive emotional pattern worth
//// monitoring.
////
//// This module is pure — no I/O, no LLM calls. It is consumed by:
////   - The Remembrancer's `analyze_affect_performance` tool, which writes
////     significant correlations as facts so the sensorium can surface them.
////   - Tests, which exercise the math directly.
////
//// Design notes:
////   - Pearson r is bounded to [-1.0, 1.0]. Constant inputs (zero variance)
////     return r = 0 with `inconclusive: True` so callers can distinguish
////     "no signal" from "definitely no relationship".
////   - Sample size <= 1 always returns inconclusive.
////   - We treat outcome as a binary {0, 1}, which is mathematically a
////     point-biserial correlation. Pearson on {0, 1} happens to give the
////     same numeric result, so we keep the cleaner name.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import affect/types.{type AffectSnapshot}
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/string
import narrative/types as narrative_types

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Which affect dimension the correlation describes.
pub type AffectDimension {
  Desperation
  Calm
  Confidence
  Frustration
  Pressure
}

pub fn dimension_to_string(d: AffectDimension) -> String {
  case d {
    Desperation -> "desperation"
    Calm -> "calm"
    Confidence -> "confidence"
    Frustration -> "frustration"
    Pressure -> "pressure"
  }
}

/// A single correlation result: how strongly an affect dimension predicts
/// success in a given task domain.
pub type AffectCorrelation {
  AffectCorrelation(
    dimension: AffectDimension,
    domain: String,
    /// Pearson r in [-1.0, 1.0]. Negative means high dimension → failure.
    correlation: Float,
    /// Number of (affect, outcome) pairs that fed the calculation.
    sample_size: Int,
    /// True when the correlation is meaningless (n <= 1 or zero variance
    /// on either axis). Callers should ignore the `correlation` field when
    /// this is True.
    inconclusive: Bool,
  )
}

// ---------------------------------------------------------------------------
// Correlation computation
// ---------------------------------------------------------------------------

/// Compute correlations for every (dimension × domain) pair derivable from
/// the inputs. Returns one `AffectCorrelation` per pair that has at least
/// `min_sample` matched (snapshot, entry) records. Pairs below the
/// threshold are dropped entirely (rather than returned inconclusive) to
/// keep callers honest about what they have evidence for.
pub fn compute_correlations(
  snapshots: List(AffectSnapshot),
  entries: List(narrative_types.NarrativeEntry),
  min_sample: Int,
) -> List(AffectCorrelation) {
  let by_cycle = index_snapshots(snapshots)
  let pairs =
    entries
    |> list.filter_map(fn(entry) {
      case dict.get(by_cycle, entry.cycle_id) {
        Ok(snap) -> Ok(#(snap, entry))
        Error(_) -> Error(Nil)
      }
    })
  // Group by domain.
  let grouped =
    list.fold(pairs, dict.new(), fn(acc, pair) {
      let #(_, entry) = pair
      let domain = case string.trim(entry.intent.domain) {
        "" -> "unknown"
        d -> d
      }
      let prior = case dict.get(acc, domain) {
        Ok(xs) -> xs
        Error(_) -> []
      }
      dict.insert(acc, domain, [pair, ..prior])
    })
  let dims = [Desperation, Calm, Confidence, Frustration, Pressure]
  dict.to_list(grouped)
  |> list.flat_map(fn(kv) {
    let #(domain, pairs_for_domain) = kv
    list.map(dims, fn(dim) { correlation_for(dim, domain, pairs_for_domain) })
  })
  |> list.filter(fn(c) { c.sample_size >= min_sample })
}

fn index_snapshots(
  snapshots: List(AffectSnapshot),
) -> Dict(String, AffectSnapshot) {
  list.fold(snapshots, dict.new(), fn(acc, s) {
    case s.cycle_id {
      "" -> acc
      id -> dict.insert(acc, id, s)
    }
  })
}

fn correlation_for(
  dimension: AffectDimension,
  domain: String,
  pairs: List(#(AffectSnapshot, narrative_types.NarrativeEntry)),
) -> AffectCorrelation {
  let xs = list.map(pairs, fn(p) { dimension_value(dimension, p.0) })
  let ys =
    list.map(pairs, fn(p) {
      case { p.1 }.outcome.status == narrative_types.Success {
        True -> 1.0
        False -> 0.0
      }
    })
  let n = list.length(xs)
  let #(r, inconclusive) = pearson(xs, ys)
  AffectCorrelation(
    dimension: dimension,
    domain: domain,
    correlation: r,
    sample_size: n,
    inconclusive: inconclusive,
  )
}

pub fn dimension_value(d: AffectDimension, s: AffectSnapshot) -> Float {
  case d {
    Desperation -> s.desperation
    Calm -> s.calm
    Confidence -> s.confidence
    Frustration -> s.frustration
    Pressure -> s.pressure
  }
}

// ---------------------------------------------------------------------------
// Pearson correlation — pure math, returns (r, inconclusive)
// ---------------------------------------------------------------------------

/// Pearson r for two equal-length lists of floats. Returns (0.0, True) for
/// n <= 1 or when either input has zero variance — the "inconclusive"
/// flag tells callers to treat the number as meaningless.
pub fn pearson(xs: List(Float), ys: List(Float)) -> #(Float, Bool) {
  let n = list.length(xs)
  case n {
    0 -> #(0.0, True)
    1 -> #(0.0, True)
    _ -> {
      let nf = int.to_float(n)
      let mean_x = sum(xs) /. nf
      let mean_y = sum(ys) /. nf
      let pairs = list.zip(xs, ys)
      let cov =
        list.fold(pairs, 0.0, fn(acc, p) {
          acc +. { p.0 -. mean_x } *. { p.1 -. mean_y }
        })
      let var_x =
        list.fold(xs, 0.0, fn(acc, x) {
          acc +. { x -. mean_x } *. { x -. mean_x }
        })
      let var_y =
        list.fold(ys, 0.0, fn(acc, y) {
          acc +. { y -. mean_y } *. { y -. mean_y }
        })
      case var_x <=. 0.0 || var_y <=. 0.0 {
        True -> #(0.0, True)
        False -> {
          let denom_sq = var_x *. var_y
          case float.square_root(denom_sq) {
            Ok(denom) -> #(cov /. denom, False)
            Error(_) -> #(0.0, True)
          }
        }
      }
    }
  }
}

fn sum(xs: List(Float)) -> Float {
  list.fold(xs, 0.0, fn(acc, x) { acc +. x })
}

// ---------------------------------------------------------------------------
// Fact key naming — used by the Remembrancer to persist correlations into
// the facts store and by the Curator to read them back for the sensorium.
// ---------------------------------------------------------------------------

/// `affect_corr_<dimension>_<domain>` — domain is normalised by replacing
/// whitespace with '-' so it's safe inside a fact key.
pub fn fact_key(c: AffectCorrelation) -> String {
  let dim = dimension_to_string(c.dimension)
  let safe_domain =
    c.domain
    |> string.replace(" ", "-")
    |> string.replace("\t", "-")
  "affect_corr_" <> dim <> "_" <> safe_domain
}

/// Encode an AffectCorrelation as a compact, pipe-delimited fact value
/// suitable for storage and later parsing. Format:
///   "<r>|<n>|<inconclusive>"
pub fn fact_value(c: AffectCorrelation) -> String {
  float.to_string(c.correlation)
  <> "|"
  <> int.to_string(c.sample_size)
  <> "|"
  <> case c.inconclusive {
    True -> "1"
    False -> "0"
  }
}

/// Parse a fact value back into the (correlation, sample_size,
/// inconclusive) triple. Returns Error(Nil) on malformed input.
pub fn parse_fact_value(value: String) -> Result(#(Float, Int, Bool), Nil) {
  case string.split(value, "|") {
    [r_str, n_str, inc_str] -> {
      case float.parse(r_str), int.parse(n_str) {
        Ok(r), Ok(n) -> {
          let inconclusive = inc_str == "1"
          Ok(#(r, n, inconclusive))
        }
        _, _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}
