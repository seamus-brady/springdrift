import gleeunit
import gleeunit/should
import normative/calculus
import normative/types.{
  Absolute, Coordinate, EthicalMoral, Impossible, Indifferent,
  IntellectualHonesty, Legal, NoConflict, NormativeProposition, Operational,
  Ought, Possible, Required, SafetyPhysical, Superordinate, Transparency,
  UserAutonomy,
}

pub fn main() -> Nil {
  gleeunit.main()
}

fn np(level, operator, modality) -> types.NormativeProposition {
  NormativeProposition(level:, operator:, modality:, description: "test")
}

// ---------------------------------------------------------------------------
// No D' signal → NoConflict
// ---------------------------------------------------------------------------

pub fn no_dprime_signal_test() {
  let r =
    calculus.resolve(
      np(EthicalMoral, Required, Possible),
      np(EthicalMoral, Required, Possible),
      False,
    )
  r.severity |> should.equal(NoConflict)
  r.rule_fired |> should.equal("no_dprime_signal")
}

// ---------------------------------------------------------------------------
// Futility pre-processor (Axiom 6.6)
// ---------------------------------------------------------------------------

pub fn futile_user_np_test() {
  let r =
    calculus.resolve(
      np(EthicalMoral, Required, Impossible),
      np(EthicalMoral, Required, Possible),
      True,
    )
  r.severity |> should.equal(NoConflict)
  r.rule_fired |> should.equal("axiom_6.6_futility")
}

// ---------------------------------------------------------------------------
// Indifference pre-processor (Axiom 6.7)
// ---------------------------------------------------------------------------

pub fn indifferent_user_np_test() {
  let r =
    calculus.resolve(
      np(EthicalMoral, Indifferent, Possible),
      np(EthicalMoral, Required, Possible),
      True,
    )
  r.severity |> should.equal(NoConflict)
  r.rule_fired |> should.equal("axiom_6.7_indifference")
}

// ---------------------------------------------------------------------------
// Absolute prohibition (Axiom 6.2)
// ---------------------------------------------------------------------------

pub fn absolute_prohibition_test() {
  let r =
    calculus.resolve(
      np(Operational, Ought, Possible),
      np(EthicalMoral, Required, Possible),
      True,
    )
  r.severity |> should.equal(Absolute)
  r.rule_fired |> should.equal("axiom_6.2_absolute_prohibition")
}

pub fn absolute_prohibition_legal_required_not_absolute_test() {
  // Legal + Required is NOT absolute (only EthicalMoral + Required is)
  let r =
    calculus.resolve(
      np(Operational, Ought, Possible),
      np(Legal, Required, Possible),
      True,
    )
  r.severity |> should.equal(Superordinate)
  r.rule_fired |> should.equal("axiom_6.3_moral_priority")
}

// ---------------------------------------------------------------------------
// Moral priority — system level > user level (Axiom 6.3)
// ---------------------------------------------------------------------------

pub fn moral_priority_system_higher_test() {
  let r =
    calculus.resolve(
      np(Operational, Required, Possible),
      np(Legal, Ought, Possible),
      True,
    )
  r.severity |> should.equal(Superordinate)
  r.rule_fired |> should.equal("axiom_6.3_moral_priority")
}

pub fn moral_priority_adjacent_levels_test() {
  let r =
    calculus.resolve(
      np(Transparency, Required, Possible),
      np(UserAutonomy, Ought, Possible),
      True,
    )
  r.severity |> should.equal(Superordinate)
  r.rule_fired |> should.equal("axiom_6.3_moral_priority")
}

// ---------------------------------------------------------------------------
// User level dominant → NoConflict
// ---------------------------------------------------------------------------

pub fn user_level_dominant_test() {
  let r =
    calculus.resolve(
      np(EthicalMoral, Ought, Possible),
      np(Operational, Required, Possible),
      True,
    )
  r.severity |> should.equal(NoConflict)
  r.rule_fired |> should.equal("user_level_dominant")
}

// ---------------------------------------------------------------------------
// Moral rank — same level, system operator stronger (Axiom 6.4)
// ---------------------------------------------------------------------------

pub fn moral_rank_system_stronger_test() {
  let r =
    calculus.resolve(
      np(Legal, Ought, Possible),
      np(Legal, Required, Possible),
      True,
    )
  r.severity |> should.equal(Superordinate)
  r.rule_fired |> should.equal("axiom_6.4_moral_rank")
}

pub fn moral_rank_required_vs_indifferent_test() {
  let r =
    calculus.resolve(
      np(IntellectualHonesty, Indifferent, Possible),
      np(IntellectualHonesty, Required, Possible),
      True,
    )
  // Indifference pre-processor fires first
  r.severity |> should.equal(NoConflict)
  r.rule_fired |> should.equal("axiom_6.7_indifference")
}

// ---------------------------------------------------------------------------
// Equal weight → Coordinate
// ---------------------------------------------------------------------------

pub fn coordinate_same_level_same_operator_test() {
  let r =
    calculus.resolve(
      np(SafetyPhysical, Ought, Possible),
      np(SafetyPhysical, Ought, Possible),
      True,
    )
  r.severity |> should.equal(Coordinate)
  r.rule_fired |> should.equal("equal_weight_coordinate")
}

pub fn coordinate_required_vs_required_test() {
  let r =
    calculus.resolve(
      np(Legal, Required, Possible),
      np(Legal, Required, Possible),
      True,
    )
  // Legal + Required system NP is NOT absolute prohibition (only EthicalMoral is)
  r.severity |> should.equal(Coordinate)
  r.rule_fired |> should.equal("equal_weight_coordinate")
}

// ---------------------------------------------------------------------------
// User operator dominant → NoConflict
// ---------------------------------------------------------------------------

pub fn user_operator_dominant_test() {
  let r =
    calculus.resolve(
      np(Legal, Required, Possible),
      np(Legal, Ought, Possible),
      True,
    )
  r.severity |> should.equal(NoConflict)
  r.rule_fired |> should.equal("user_operator_dominant")
}

// ---------------------------------------------------------------------------
// resolve_all — cross-product
// ---------------------------------------------------------------------------

pub fn resolve_all_empty_test() {
  calculus.resolve_all([], [])
  |> should.equal([])
}

pub fn resolve_all_single_pair_test() {
  let results =
    calculus.resolve_all([np(Operational, Ought, Possible)], [
      np(EthicalMoral, Required, Possible),
    ])
  list.length(results) |> should.equal(1)
  let assert [r] = results
  r.severity |> should.equal(Absolute)
}

pub fn resolve_all_cross_product_test() {
  let user_nps = [
    np(Operational, Ought, Possible),
    np(Legal, Ought, Possible),
  ]
  let system_nps = [
    np(EthicalMoral, Required, Possible),
    np(IntellectualHonesty, Ought, Possible),
  ]
  let results = calculus.resolve_all(user_nps, system_nps)
  // 2 user × 2 system = 4 results
  list.length(results) |> should.equal(4)
}

import gleam/list
