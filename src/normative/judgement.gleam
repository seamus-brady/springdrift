//// Floor rules — maps conflict results + harm context to a FlourishingVerdict.
////
//// 8 floor rules in priority order determine whether the output promotes
//// flourishing (accept), is constrained (modify), or is prohibited (reject).
//// The rules preserve backward compatibility with D' threshold-based decisions
//// while adding normative reasoning.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleam/string
import normative/types.{
  type ConflictSeverity, type FlourishingVerdict, type HarmContext,
  type NormativeJudgement, type VirtueConflictResult, Absolute, Constrained,
  Coordinate, Flourishing, Legal, NormativeJudgement, ProfessionalEthics,
  Prohibited, SafetyPhysical, Superordinate,
}

/// Produce a normative judgement from conflict results, harm context, and
/// D' score with thresholds. Applies 8 floor rules in priority order.
pub fn judge(
  conflicts: List(VirtueConflictResult),
  harm_context: HarmContext,
  dprime_score: Float,
  modify_threshold: Float,
  reject_threshold: Float,
) -> NormativeJudgement {
  let trail = build_axiom_trail(conflicts)

  // Floor 1: PROHIBITED — any ABSOLUTE severity
  case has_severity(conflicts, Absolute) {
    True ->
      NormativeJudgement(
        verdict: Prohibited,
        floor_rule: "floor_1_absolute_prohibition",
        conflicts:,
        axiom_trail: trail,
      )
    False ->
      judge_floor_2(
        conflicts,
        harm_context,
        dprime_score,
        modify_threshold,
        reject_threshold,
        trail,
      )
  }
}

// ---------------------------------------------------------------------------
// Floor rules 2-8
// ---------------------------------------------------------------------------

fn judge_floor_2(
  conflicts: List(VirtueConflictResult),
  harm_context: HarmContext,
  dprime_score: Float,
  modify_threshold: Float,
  reject_threshold: Float,
  trail: List(String),
) -> NormativeJudgement {
  // Floor 2: PROHIBITED — SUPERORDINATE at Legal or higher
  case has_superordinate_at_or_above(conflicts, Legal) {
    True ->
      NormativeJudgement(
        verdict: Prohibited,
        floor_rule: "floor_2_superordinate_legal",
        conflicts:,
        axiom_trail: trail,
      )
    False ->
      judge_floor_3(
        conflicts,
        harm_context,
        dprime_score,
        modify_threshold,
        reject_threshold,
        trail,
      )
  }
}

fn judge_floor_3(
  conflicts: List(VirtueConflictResult),
  harm_context: HarmContext,
  dprime_score: Float,
  modify_threshold: Float,
  reject_threshold: Float,
  trail: List(String),
) -> NormativeJudgement {
  // Floor 3: PROHIBITED — D' score ≥ reject_threshold (preserves existing behaviour)
  case dprime_score >=. reject_threshold {
    True ->
      NormativeJudgement(
        verdict: Prohibited,
        floor_rule: "floor_3_dprime_reject",
        conflicts:,
        axiom_trail: trail,
      )
    False ->
      judge_floor_4(
        conflicts,
        harm_context,
        dprime_score,
        modify_threshold,
        trail,
      )
  }
}

fn judge_floor_4(
  conflicts: List(VirtueConflictResult),
  harm_context: HarmContext,
  dprime_score: Float,
  modify_threshold: Float,
  trail: List(String),
) -> NormativeJudgement {
  // Floor 4: CONSTRAINED — catastrophic potential + any SUPERORDINATE
  case harm_context.catastrophic && has_severity(conflicts, Superordinate) {
    True ->
      NormativeJudgement(
        verdict: Constrained,
        floor_rule: "floor_4_catastrophic_superordinate",
        conflicts:,
        axiom_trail: trail,
      )
    False -> judge_floor_5(conflicts, dprime_score, modify_threshold, trail)
  }
}

fn judge_floor_5(
  conflicts: List(VirtueConflictResult),
  dprime_score: Float,
  modify_threshold: Float,
  trail: List(String),
) -> NormativeJudgement {
  // Floor 5: CONSTRAINED — 2+ COORDINATE conflicts
  case count_severity(conflicts, Coordinate) >= 2 {
    True ->
      NormativeJudgement(
        verdict: Constrained,
        floor_rule: "floor_5_multiple_coordinate",
        conflicts:,
        axiom_trail: trail,
      )
    False -> judge_floor_6(conflicts, dprime_score, modify_threshold, trail)
  }
}

fn judge_floor_6(
  conflicts: List(VirtueConflictResult),
  dprime_score: Float,
  modify_threshold: Float,
  trail: List(String),
) -> NormativeJudgement {
  // Floor 6: CONSTRAINED — D' score ≥ modify_threshold (preserves existing behaviour)
  case dprime_score >=. modify_threshold {
    True ->
      NormativeJudgement(
        verdict: Constrained,
        floor_rule: "floor_6_dprime_modify",
        conflicts:,
        axiom_trail: trail,
      )
    False -> judge_floor_7(conflicts, trail)
  }
}

fn judge_floor_7(
  conflicts: List(VirtueConflictResult),
  trail: List(String),
) -> NormativeJudgement {
  // Floor 7: CONSTRAINED — any SUPERORDINATE at mid levels
  // (ProfessionalEthics through SafetyPhysical)
  case has_superordinate_in_mid_range(conflicts) {
    True ->
      NormativeJudgement(
        verdict: Constrained,
        floor_rule: "floor_7_mid_level_superordinate",
        conflicts:,
        axiom_trail: trail,
      )
    False -> judge_floor_8(conflicts, trail)
  }
}

fn judge_floor_8(
  conflicts: List(VirtueConflictResult),
  trail: List(String),
) -> NormativeJudgement {
  // Floor 8: FLOURISHING — default
  NormativeJudgement(
    verdict: Flourishing,
    floor_rule: "floor_8_flourishing",
    conflicts:,
    axiom_trail: trail,
  )
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn has_severity(
  conflicts: List(VirtueConflictResult),
  target: ConflictSeverity,
) -> Bool {
  list.any(conflicts, fn(c) { c.severity == target })
}

fn count_severity(
  conflicts: List(VirtueConflictResult),
  target: ConflictSeverity,
) -> Int {
  list.count(conflicts, fn(c) { c.severity == target })
}

/// Check if any SUPERORDINATE conflict exists at or above the given level.
fn has_superordinate_at_or_above(
  conflicts: List(VirtueConflictResult),
  min_level: types.NormativeLevel,
) -> Bool {
  let min_ord = types.level_ordinal(min_level)
  list.any(conflicts, fn(c) {
    c.severity == Superordinate
    && types.level_ordinal(c.system_np.level) >= min_ord
  })
}

/// Check if any SUPERORDINATE conflict exists in the mid-level range
/// (ProfessionalEthics through SafetyPhysical).
fn has_superordinate_in_mid_range(conflicts: List(VirtueConflictResult)) -> Bool {
  let min_ord = types.level_ordinal(ProfessionalEthics)
  let max_ord = types.level_ordinal(SafetyPhysical)
  list.any(conflicts, fn(c) {
    c.severity == Superordinate
    && {
      let ord = types.level_ordinal(c.system_np.level)
      ord >= min_ord && ord <= max_ord
    }
  })
}

/// Build an axiom trail from the conflict results — the list of rules
/// that fired during resolution, deduplicated.
fn build_axiom_trail(conflicts: List(VirtueConflictResult)) -> List(String) {
  conflicts
  |> list.map(fn(c) { c.rule_fired })
  |> list.unique()
  |> list.sort(string.compare)
}

/// Map a FlourishingVerdict to a human-readable string.
pub fn verdict_to_string(verdict: FlourishingVerdict) -> String {
  case verdict {
    Flourishing -> "flourishing"
    Constrained -> "constrained"
    Prohibited -> "prohibited"
  }
}
