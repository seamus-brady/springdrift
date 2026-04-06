//// Appraisal types — pre-mortems, post-mortems, and verdicts.
////
//// Pre-mortems predict failure modes before work starts.
//// Post-mortems evaluate quality after completion.
//// Together they close the learning loop between planning and execution.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/json
import gleam/option.{type Option, None, Some}

// ---------------------------------------------------------------------------
// Verdict
// ---------------------------------------------------------------------------

pub type AppraisalVerdict {
  Achieved
  PartiallyAchieved
  NotAchieved
  AbandonedWithLearnings
}

pub fn verdict_to_string(v: AppraisalVerdict) -> String {
  case v {
    Achieved -> "achieved"
    PartiallyAchieved -> "partially_achieved"
    NotAchieved -> "not_achieved"
    AbandonedWithLearnings -> "abandoned_with_learnings"
  }
}

pub fn verdict_from_string(s: String) -> AppraisalVerdict {
  case s {
    "achieved" -> Achieved
    "partially_achieved" -> PartiallyAchieved
    "not_achieved" -> NotAchieved
    "abandoned_with_learnings" -> AbandonedWithLearnings
    _ -> NotAchieved
  }
}

// ---------------------------------------------------------------------------
// Pre-mortem — predicted failure modes before work begins
// ---------------------------------------------------------------------------

pub type PreMortem {
  PreMortem(
    task_id: String,
    failure_modes: List(String),
    blind_spot_assumptions: List(String),
    dependencies_at_risk: List(String),
    information_gaps: List(String),
    similar_pitfall_case_ids: List(String),
    created_at: String,
  )
}

pub fn encode_pre_mortem(pm: PreMortem) -> json.Json {
  json.object([
    #("task_id", json.string(pm.task_id)),
    #("failure_modes", json.array(pm.failure_modes, json.string)),
    #(
      "blind_spot_assumptions",
      json.array(pm.blind_spot_assumptions, json.string),
    ),
    #("dependencies_at_risk", json.array(pm.dependencies_at_risk, json.string)),
    #("information_gaps", json.array(pm.information_gaps, json.string)),
    #(
      "similar_pitfall_case_ids",
      json.array(pm.similar_pitfall_case_ids, json.string),
    ),
    #("created_at", json.string(pm.created_at)),
  ])
}

// ---------------------------------------------------------------------------
// Post-mortem — quality evaluation after completion
// ---------------------------------------------------------------------------

pub type PredictionComparison {
  PredictionComparison(prediction: String, reality: String, accurate: Bool)
}

pub type PostMortem {
  PostMortem(
    task_id: String,
    verdict: AppraisalVerdict,
    prediction_comparisons: List(PredictionComparison),
    lessons_learned: List(String),
    contributing_factors: List(String),
    created_at: String,
  )
}

pub fn encode_post_mortem(pm: PostMortem) -> json.Json {
  json.object([
    #("task_id", json.string(pm.task_id)),
    #("verdict", json.string(verdict_to_string(pm.verdict))),
    #(
      "prediction_comparisons",
      json.array(pm.prediction_comparisons, fn(pc) {
        json.object([
          #("prediction", json.string(pc.prediction)),
          #("reality", json.string(pc.reality)),
          #("accurate", json.bool(pc.accurate)),
        ])
      }),
    ),
    #("lessons_learned", json.array(pm.lessons_learned, json.string)),
    #("contributing_factors", json.array(pm.contributing_factors, json.string)),
    #("created_at", json.string(pm.created_at)),
  ])
}

// ---------------------------------------------------------------------------
// Endeavour post-mortem — synthesis across all task post-mortems
// ---------------------------------------------------------------------------

pub type CriterionResult {
  CriterionResult(criterion: String, met: Bool, evidence: String)
}

pub type EndeavourPostMortem {
  EndeavourPostMortem(
    endeavour_id: String,
    verdict: AppraisalVerdict,
    goal_achieved: Bool,
    criteria_results: List(CriterionResult),
    task_verdicts: List(#(String, AppraisalVerdict)),
    synthesis: String,
    created_at: String,
  )
}

pub fn encode_endeavour_post_mortem(epm: EndeavourPostMortem) -> json.Json {
  json.object([
    #("endeavour_id", json.string(epm.endeavour_id)),
    #("verdict", json.string(verdict_to_string(epm.verdict))),
    #("goal_achieved", json.bool(epm.goal_achieved)),
    #(
      "criteria_results",
      json.array(epm.criteria_results, fn(cr) {
        json.object([
          #("criterion", json.string(cr.criterion)),
          #("met", json.bool(cr.met)),
          #("evidence", json.string(cr.evidence)),
        ])
      }),
    ),
    #(
      "task_verdicts",
      json.array(epm.task_verdicts, fn(tv) {
        json.object([
          #("task_id", json.string(tv.0)),
          #("verdict", json.string(verdict_to_string(tv.1))),
        ])
      }),
    ),
    #("synthesis", json.string(epm.synthesis)),
    #("created_at", json.string(epm.created_at)),
  ])
}

// ---------------------------------------------------------------------------
// Decoders
// ---------------------------------------------------------------------------

import gleam/dynamic/decode

pub fn pre_mortem_decoder() -> decode.Decoder(PreMortem) {
  use task_id <- decode.field("task_id", decode.string)
  use failure_modes <- decode.optional_field(
    "failure_modes",
    [],
    decode.list(decode.string),
  )
  use blind_spot_assumptions <- decode.optional_field(
    "blind_spot_assumptions",
    [],
    decode.list(decode.string),
  )
  use dependencies_at_risk <- decode.optional_field(
    "dependencies_at_risk",
    [],
    decode.list(decode.string),
  )
  use information_gaps <- decode.optional_field(
    "information_gaps",
    [],
    decode.list(decode.string),
  )
  use similar_pitfall_case_ids <- decode.optional_field(
    "similar_pitfall_case_ids",
    [],
    decode.list(decode.string),
  )
  use created_at <- decode.optional_field("created_at", "", decode.string)
  decode.success(PreMortem(
    task_id:,
    failure_modes:,
    blind_spot_assumptions:,
    dependencies_at_risk:,
    information_gaps:,
    similar_pitfall_case_ids:,
    created_at:,
  ))
}

fn prediction_comparison_decoder() -> decode.Decoder(PredictionComparison) {
  use prediction <- decode.field("prediction", decode.string)
  use reality <- decode.optional_field("reality", "", decode.string)
  use accurate <- decode.optional_field("accurate", False, decode.bool)
  decode.success(PredictionComparison(prediction:, reality:, accurate:))
}

pub fn post_mortem_decoder() -> decode.Decoder(PostMortem) {
  use task_id <- decode.field("task_id", decode.string)
  use verdict_str <- decode.optional_field(
    "verdict",
    "not_achieved",
    decode.string,
  )
  use prediction_comparisons <- decode.optional_field(
    "prediction_comparisons",
    [],
    decode.list(prediction_comparison_decoder()),
  )
  use lessons_learned <- decode.optional_field(
    "lessons_learned",
    [],
    decode.list(decode.string),
  )
  use contributing_factors <- decode.optional_field(
    "contributing_factors",
    [],
    decode.list(decode.string),
  )
  use created_at <- decode.optional_field("created_at", "", decode.string)
  decode.success(PostMortem(
    task_id:,
    verdict: verdict_from_string(verdict_str),
    prediction_comparisons:,
    lessons_learned:,
    contributing_factors:,
    created_at:,
  ))
}

fn criterion_result_decoder() -> decode.Decoder(CriterionResult) {
  use criterion <- decode.field("criterion", decode.string)
  use met <- decode.optional_field("met", False, decode.bool)
  use evidence <- decode.optional_field("evidence", "", decode.string)
  decode.success(CriterionResult(criterion:, met:, evidence:))
}

fn task_verdict_decoder() -> decode.Decoder(#(String, AppraisalVerdict)) {
  use task_id <- decode.field("task_id", decode.string)
  use verdict_str <- decode.optional_field(
    "verdict",
    "not_achieved",
    decode.string,
  )
  decode.success(#(task_id, verdict_from_string(verdict_str)))
}

pub fn endeavour_post_mortem_decoder() -> decode.Decoder(EndeavourPostMortem) {
  use endeavour_id <- decode.field("endeavour_id", decode.string)
  use verdict_str <- decode.optional_field(
    "verdict",
    "not_achieved",
    decode.string,
  )
  use goal_achieved <- decode.optional_field(
    "goal_achieved",
    False,
    decode.bool,
  )
  use criteria_results <- decode.optional_field(
    "criteria_results",
    [],
    decode.list(criterion_result_decoder()),
  )
  use task_verdicts <- decode.optional_field(
    "task_verdicts",
    [],
    decode.list(task_verdict_decoder()),
  )
  use synthesis <- decode.optional_field("synthesis", "", decode.string)
  use created_at <- decode.optional_field("created_at", "", decode.string)
  decode.success(EndeavourPostMortem(
    endeavour_id:,
    verdict: verdict_from_string(verdict_str),
    goal_achieved:,
    criteria_results:,
    task_verdicts:,
    synthesis:,
    created_at:,
  ))
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Default empty pre-mortem for tasks that skip the LLM call.
pub fn empty_pre_mortem(task_id: String) -> PreMortem {
  PreMortem(
    task_id:,
    failure_modes: [],
    blind_spot_assumptions: [],
    dependencies_at_risk: [],
    information_gaps: [],
    similar_pitfall_case_ids: [],
    created_at: "",
  )
}

/// Deterministic post-mortem for simple completed tasks — no LLM call needed.
pub fn deterministic_achieved(task_id: String, at: String) -> PostMortem {
  PostMortem(
    task_id:,
    verdict: Achieved,
    prediction_comparisons: [],
    lessons_learned: [],
    contributing_factors: [],
    created_at: at,
  )
}

/// Encode an optional PreMortem for JSON output.
pub fn encode_optional_pre_mortem(pm: Option(PreMortem)) -> json.Json {
  case pm {
    None -> json.null()
    Some(p) -> encode_pre_mortem(p)
  }
}

/// Encode an optional PostMortem for JSON output.
pub fn encode_optional_post_mortem(pm: Option(PostMortem)) -> json.Json {
  case pm {
    None -> json.null()
    Some(p) -> encode_post_mortem(p)
  }
}

/// Encode an optional EndeavourPostMortem for JSON output.
pub fn encode_optional_endeavour_post_mortem(
  epm: Option(EndeavourPostMortem),
) -> json.Json {
  case epm {
    None -> json.null()
    Some(p) -> encode_endeavour_post_mortem(p)
  }
}

/// Decode an optional PreMortem (null → None).
pub fn optional_pre_mortem_decoder() -> decode.Decoder(Option(PreMortem)) {
  decode.optional(pre_mortem_decoder())
}

/// Decode an optional PostMortem (null → None).
pub fn optional_post_mortem_decoder() -> decode.Decoder(Option(PostMortem)) {
  decode.optional(post_mortem_decoder())
}

/// Decode an optional EndeavourPostMortem (null → None).
pub fn optional_endeavour_post_mortem_decoder() -> decode.Decoder(
  Option(EndeavourPostMortem),
) {
  decode.optional(endeavour_post_mortem_decoder())
}
