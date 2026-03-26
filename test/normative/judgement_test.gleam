import gleeunit
import gleeunit/should
import normative/judgement
import normative/types.{
  type HarmContext, type VirtueConflictResult, Absolute, Constrained, Coordinate,
  CoordinateConflict, EthicalMoral, Flourishing, HarmContext,
  IntellectualHonesty, Legal, NoConflict, NoConflictResolution,
  NormativeProposition, Operational, Ought, Possible, ProfessionalEthics,
  Prohibited, Required, SafetyPhysical, Superordinate, SystemWins,
  VirtueConflictResult,
}

pub fn main() -> Nil {
  gleeunit.main()
}

fn np(level, operator) -> types.NormativeProposition {
  NormativeProposition(
    level:,
    operator:,
    modality: Possible,
    description: "test",
  )
}

fn conflict(
  user_level,
  user_op,
  system_level,
  system_op,
  severity,
  resolution,
  rule,
) -> VirtueConflictResult {
  VirtueConflictResult(
    user_np: np(user_level, user_op),
    system_np: np(system_level, system_op),
    severity:,
    resolution:,
    rule_fired: rule,
  )
}

fn no_harm() -> HarmContext {
  HarmContext(impact_score: 0.0, catastrophic: False)
}

fn catastrophic_harm() -> HarmContext {
  HarmContext(impact_score: 0.8, catastrophic: True)
}

// ---------------------------------------------------------------------------
// Floor 1: PROHIBITED — any ABSOLUTE severity
// ---------------------------------------------------------------------------

pub fn floor_1_absolute_test() {
  let conflicts = [
    conflict(
      Operational,
      Ought,
      EthicalMoral,
      Required,
      Absolute,
      SystemWins,
      "axiom_6.2_absolute_prohibition",
    ),
  ]
  let j = judgement.judge(conflicts, no_harm(), 0.0, 0.4, 0.7)
  j.verdict |> should.equal(Prohibited)
  j.floor_rule |> should.equal("floor_1_absolute_prohibition")
}

// ---------------------------------------------------------------------------
// Floor 2: PROHIBITED — SUPERORDINATE at Legal or higher
// ---------------------------------------------------------------------------

pub fn floor_2_superordinate_legal_test() {
  let conflicts = [
    conflict(
      Operational,
      Ought,
      Legal,
      Required,
      Superordinate,
      SystemWins,
      "axiom_6.3_moral_priority",
    ),
  ]
  let j = judgement.judge(conflicts, no_harm(), 0.0, 0.4, 0.7)
  j.verdict |> should.equal(Prohibited)
  j.floor_rule |> should.equal("floor_2_superordinate_legal")
}

pub fn floor_2_superordinate_ethical_moral_test() {
  // EthicalMoral is above Legal — still triggers floor 2
  let conflicts = [
    conflict(
      Operational,
      Ought,
      EthicalMoral,
      Ought,
      Superordinate,
      SystemWins,
      "axiom_6.3_moral_priority",
    ),
  ]
  let j = judgement.judge(conflicts, no_harm(), 0.0, 0.4, 0.7)
  // Actually floor 1 won't fire (not Absolute), floor 2 checks >= Legal
  j.verdict |> should.equal(Prohibited)
  j.floor_rule |> should.equal("floor_2_superordinate_legal")
}

pub fn floor_2_superordinate_below_legal_no_trigger_test() {
  // SafetyPhysical is below Legal — doesn't trigger floor 2
  let conflicts = [
    conflict(
      Operational,
      Ought,
      SafetyPhysical,
      Required,
      Superordinate,
      SystemWins,
      "axiom_6.3_moral_priority",
    ),
  ]
  let j = judgement.judge(conflicts, no_harm(), 0.0, 0.4, 0.7)
  // Should fall through to floor 7 (mid-level superordinate)
  j.verdict |> should.equal(Constrained)
  j.floor_rule |> should.equal("floor_7_mid_level_superordinate")
}

// ---------------------------------------------------------------------------
// Floor 3: PROHIBITED — D' score ≥ reject_threshold
// ---------------------------------------------------------------------------

pub fn floor_3_dprime_reject_test() {
  let j = judgement.judge([], no_harm(), 0.75, 0.4, 0.7)
  j.verdict |> should.equal(Prohibited)
  j.floor_rule |> should.equal("floor_3_dprime_reject")
}

pub fn floor_3_dprime_at_threshold_test() {
  let j = judgement.judge([], no_harm(), 0.7, 0.4, 0.7)
  j.verdict |> should.equal(Prohibited)
  j.floor_rule |> should.equal("floor_3_dprime_reject")
}

// ---------------------------------------------------------------------------
// Floor 4: CONSTRAINED — catastrophic + SUPERORDINATE
// ---------------------------------------------------------------------------

pub fn floor_4_catastrophic_superordinate_test() {
  let conflicts = [
    conflict(
      Operational,
      Ought,
      IntellectualHonesty,
      Required,
      Superordinate,
      SystemWins,
      "axiom_6.3_moral_priority",
    ),
  ]
  let j = judgement.judge(conflicts, catastrophic_harm(), 0.0, 0.4, 0.7)
  j.verdict |> should.equal(Constrained)
  j.floor_rule |> should.equal("floor_4_catastrophic_superordinate")
}

pub fn floor_4_catastrophic_no_superordinate_test() {
  let conflicts = [
    conflict(
      Operational,
      Ought,
      IntellectualHonesty,
      Ought,
      Coordinate,
      CoordinateConflict,
      "equal_weight_coordinate",
    ),
  ]
  let j = judgement.judge(conflicts, catastrophic_harm(), 0.0, 0.4, 0.7)
  // Not floor 4 — no SUPERORDINATE. Falls through.
  j.verdict |> should.equal(Flourishing)
}

// ---------------------------------------------------------------------------
// Floor 5: CONSTRAINED — 2+ COORDINATE conflicts
// ---------------------------------------------------------------------------

pub fn floor_5_multiple_coordinate_test() {
  let conflicts = [
    conflict(
      IntellectualHonesty,
      Ought,
      IntellectualHonesty,
      Ought,
      Coordinate,
      CoordinateConflict,
      "equal_weight_coordinate",
    ),
    conflict(
      Legal,
      Ought,
      Legal,
      Ought,
      Coordinate,
      CoordinateConflict,
      "equal_weight_coordinate",
    ),
  ]
  let j = judgement.judge(conflicts, no_harm(), 0.0, 0.4, 0.7)
  j.verdict |> should.equal(Constrained)
  j.floor_rule |> should.equal("floor_5_multiple_coordinate")
}

pub fn floor_5_single_coordinate_no_trigger_test() {
  let conflicts = [
    conflict(
      IntellectualHonesty,
      Ought,
      IntellectualHonesty,
      Ought,
      Coordinate,
      CoordinateConflict,
      "equal_weight_coordinate",
    ),
  ]
  let j = judgement.judge(conflicts, no_harm(), 0.0, 0.4, 0.7)
  j.verdict |> should.equal(Flourishing)
}

// ---------------------------------------------------------------------------
// Floor 6: CONSTRAINED — D' score ≥ modify_threshold
// ---------------------------------------------------------------------------

pub fn floor_6_dprime_modify_test() {
  let j = judgement.judge([], no_harm(), 0.5, 0.4, 0.7)
  j.verdict |> should.equal(Constrained)
  j.floor_rule |> should.equal("floor_6_dprime_modify")
}

pub fn floor_6_dprime_at_threshold_test() {
  let j = judgement.judge([], no_harm(), 0.4, 0.4, 0.7)
  j.verdict |> should.equal(Constrained)
  j.floor_rule |> should.equal("floor_6_dprime_modify")
}

// ---------------------------------------------------------------------------
// Floor 7: CONSTRAINED — SUPERORDINATE at mid levels
// ---------------------------------------------------------------------------

pub fn floor_7_mid_level_superordinate_test() {
  let conflicts = [
    conflict(
      Operational,
      Ought,
      ProfessionalEthics,
      Required,
      Superordinate,
      SystemWins,
      "axiom_6.3_moral_priority",
    ),
  ]
  let j = judgement.judge(conflicts, no_harm(), 0.0, 0.4, 0.7)
  j.verdict |> should.equal(Constrained)
  j.floor_rule |> should.equal("floor_7_mid_level_superordinate")
}

pub fn floor_7_safety_physical_test() {
  let conflicts = [
    conflict(
      Operational,
      Ought,
      SafetyPhysical,
      Ought,
      Superordinate,
      SystemWins,
      "axiom_6.3_moral_priority",
    ),
  ]
  let j = judgement.judge(conflicts, no_harm(), 0.0, 0.4, 0.7)
  j.verdict |> should.equal(Constrained)
  j.floor_rule |> should.equal("floor_7_mid_level_superordinate")
}

// ---------------------------------------------------------------------------
// Floor 8: FLOURISHING — default
// ---------------------------------------------------------------------------

pub fn floor_8_flourishing_no_conflicts_test() {
  let j = judgement.judge([], no_harm(), 0.0, 0.4, 0.7)
  j.verdict |> should.equal(Flourishing)
  j.floor_rule |> should.equal("floor_8_flourishing")
}

pub fn floor_8_flourishing_only_no_conflict_test() {
  let conflicts = [
    conflict(
      Operational,
      Ought,
      Operational,
      Required,
      NoConflict,
      NoConflictResolution,
      "no_dprime_signal",
    ),
  ]
  let j = judgement.judge(conflicts, no_harm(), 0.0, 0.4, 0.7)
  j.verdict |> should.equal(Flourishing)
  j.floor_rule |> should.equal("floor_8_flourishing")
}

// ---------------------------------------------------------------------------
// Axiom trail
// ---------------------------------------------------------------------------

pub fn axiom_trail_populated_test() {
  let conflicts = [
    conflict(
      Operational,
      Ought,
      EthicalMoral,
      Required,
      Absolute,
      SystemWins,
      "axiom_6.2_absolute_prohibition",
    ),
    conflict(
      Legal,
      Ought,
      SafetyPhysical,
      Required,
      Superordinate,
      SystemWins,
      "axiom_6.3_moral_priority",
    ),
  ]
  let j = judgement.judge(conflicts, no_harm(), 0.0, 0.4, 0.7)
  // Trail should be sorted and deduplicated
  j.axiom_trail
  |> should.equal(["axiom_6.2_absolute_prohibition", "axiom_6.3_moral_priority"])
}

pub fn axiom_trail_empty_no_conflicts_test() {
  let j = judgement.judge([], no_harm(), 0.0, 0.4, 0.7)
  j.axiom_trail |> should.equal([])
}

// ---------------------------------------------------------------------------
// verdict_to_string
// ---------------------------------------------------------------------------

pub fn verdict_flourishing_string_test() {
  judgement.verdict_to_string(Flourishing)
  |> should.equal("flourishing")
}

pub fn verdict_constrained_string_test() {
  judgement.verdict_to_string(Constrained)
  |> should.equal("constrained")
}

pub fn verdict_prohibited_string_test() {
  judgement.verdict_to_string(Prohibited)
  |> should.equal("prohibited")
}

// ---------------------------------------------------------------------------
// Priority ordering — higher floors take precedence
// ---------------------------------------------------------------------------

pub fn floor_1_beats_floor_3_test() {
  // Both Absolute conflict AND high D' — floor 1 should win
  let conflicts = [
    conflict(
      Operational,
      Ought,
      EthicalMoral,
      Required,
      Absolute,
      SystemWins,
      "axiom_6.2_absolute_prohibition",
    ),
  ]
  let j = judgement.judge(conflicts, no_harm(), 0.9, 0.4, 0.7)
  j.verdict |> should.equal(Prohibited)
  j.floor_rule |> should.equal("floor_1_absolute_prohibition")
}

pub fn floor_2_beats_floor_6_test() {
  // SUPERORDINATE at Legal + D' above modify threshold — floor 2 wins
  let conflicts = [
    conflict(
      Operational,
      Ought,
      Legal,
      Required,
      Superordinate,
      SystemWins,
      "axiom_6.3_moral_priority",
    ),
  ]
  let j = judgement.judge(conflicts, no_harm(), 0.5, 0.4, 0.7)
  j.verdict |> should.equal(Prohibited)
  j.floor_rule |> should.equal("floor_2_superordinate_legal")
}
