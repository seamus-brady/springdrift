//// D' audit logging — self-contained audit records per evaluation.
////
//// Every request produces an audit record regardless of outcome. The raw
//// user prompt is never stored — only a SHA-256 hash for correlation.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import cycle_log
import dprime/engine
import dprime/types.{
  type AuditRecord, type Feature, type FeatureScore, type Forecast,
  type GateResult, type Intervention, AuditRecord, FeatureScore,
}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import slog

@external(erlang, "springdrift_ffi", "sha256_hex")
fn sha256_hex(input: String) -> String

/// Build an audit record from gate evaluation results.
pub fn build_record(
  request_id: String,
  user_prompt: String,
  result: GateResult,
  features: List(Feature),
  reactive_dprime: Option(Float),
  meta_intervention: Option(Intervention),
) -> AuditRecord {
  let prompt_hash = sha256_hex(user_prompt)
  let canary_hijack = case result.canary_result {
    Some(probe) -> Some(probe.hijack_detected)
    None -> None
  }
  let canary_leakage = case result.canary_result {
    Some(probe) -> Some(probe.leakage_detected)
    None -> None
  }
  let deliberative_dprime = case result.layer {
    types.Deliberative -> Some(result.dprime_score)
    types.MetaManagement -> Some(result.dprime_score)
    types.Reactive -> None
  }
  let per_feature = build_per_feature(result.forecasts, features)
  let source = case result.layer {
    types.Reactive -> "reactive"
    types.Deliberative -> "deliberative"
    types.MetaManagement -> "meta_management"
  }

  AuditRecord(
    request_id:,
    prompt_hash:,
    canary_hijack:,
    canary_leakage:,
    reactive_dprime:,
    deliberative_dprime:,
    magnitudes: result.forecasts,
    per_feature:,
    decision: result.decision,
    source:,
    meta_intervention:,
  )
}

/// Log an audit record to the cycle log as a self-contained JSON object.
pub fn log_record(record: AuditRecord, cycle_id: String) -> Nil {
  slog.debug(
    "dprime/audit",
    "log_record",
    "Logging audit record for request " <> record.request_id,
    Some(cycle_id),
  )
  let decision_str = case record.decision {
    types.Accept -> "accept"
    types.Modify -> "modify"
    types.Reject -> "reject"
  }
  let intervention_str = case record.meta_intervention {
    None -> json.null()
    Some(types.NoIntervention) -> json.string("none")
    Some(types.Stalled) -> json.string("stalled")
    Some(types.AbortMaxIterations) -> json.string("abort_max_iterations")
  }
  let magnitudes_json =
    json.array(record.magnitudes, fn(f) {
      json.object([
        #("feature", json.string(f.feature_name)),
        #("magnitude", json.int(f.magnitude)),
      ])
    })
  let per_feature_json =
    json.array(record.per_feature, fn(fs) {
      json.object([
        #("name", json.string(fs.name)),
        #("importance", json.int(fs.importance)),
        #("magnitude", json.int(fs.magnitude)),
        #("score", json.int(fs.score)),
      ])
    })
  cycle_log.log_dprime_audit(
    cycle_id,
    json.object([
      #("request_id", json.string(record.request_id)),
      #("prompt_hash", json.string(record.prompt_hash)),
      #("canary_hijack", case record.canary_hijack {
        Some(v) -> json.bool(v)
        None -> json.null()
      }),
      #("canary_leakage", case record.canary_leakage {
        Some(v) -> json.bool(v)
        None -> json.null()
      }),
      #("reactive_dprime", case record.reactive_dprime {
        Some(v) -> json.float(v)
        None -> json.null()
      }),
      #("deliberative_dprime", case record.deliberative_dprime {
        Some(v) -> json.float(v)
        None -> json.null()
      }),
      #("magnitudes", magnitudes_json),
      #("per_feature", per_feature_json),
      #("decision", json.string(decision_str)),
      #("source", json.string(record.source)),
      #("meta_intervention", intervention_str),
    ]),
  )
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

fn build_per_feature(
  forecasts: List(Forecast),
  features: List(Feature),
) -> List(FeatureScore) {
  list.filter_map(features, fn(feat) {
    case list.find(forecasts, fn(f) { f.feature_name == feat.name }) {
      Ok(forecast) -> {
        let imp = engine.importance_weight(feat.importance)
        let mag = int.min(3, int.max(0, forecast.magnitude))
        Ok(FeatureScore(
          name: feat.name,
          importance: imp,
          magnitude: mag,
          score: imp * mag,
        ))
      }
      Error(_) -> {
        let imp = engine.importance_weight(feat.importance)
        Ok(FeatureScore(
          name: feat.name,
          importance: imp,
          magnitude: 0,
          score: 0,
        ))
      }
    }
  })
}
