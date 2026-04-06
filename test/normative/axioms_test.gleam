// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleeunit
import gleeunit/should
import normative/axioms
import normative/types.{
  EthicalMoral, Impossible, Indifferent, Legal, NoConflict, NoConflictResolution,
  NormativeProposition, Operational, Ought, Possible, Required, SafetyPhysical,
  VirtueConflictResult,
}

pub fn main() -> Nil {
  gleeunit.main()
}

fn np(level, operator, modality) -> types.NormativeProposition {
  NormativeProposition(level:, operator:, modality:, description: "test")
}

// ---------------------------------------------------------------------------
// is_futile (Axiom 6.6)
// ---------------------------------------------------------------------------

pub fn futile_impossible_test() {
  np(EthicalMoral, Required, Impossible)
  |> axioms.is_futile()
  |> should.be_true()
}

pub fn futile_possible_test() {
  np(EthicalMoral, Required, Possible)
  |> axioms.is_futile()
  |> should.be_false()
}

// ---------------------------------------------------------------------------
// is_indifferent (Axiom 6.7)
// ---------------------------------------------------------------------------

pub fn indifferent_yes_test() {
  np(Operational, Indifferent, Possible)
  |> axioms.is_indifferent()
  |> should.be_true()
}

pub fn indifferent_required_test() {
  np(Operational, Required, Possible)
  |> axioms.is_indifferent()
  |> should.be_false()
}

pub fn indifferent_ought_test() {
  np(Operational, Ought, Possible)
  |> axioms.is_indifferent()
  |> should.be_false()
}

// ---------------------------------------------------------------------------
// is_absolute_prohibition (Axiom 6.2)
// ---------------------------------------------------------------------------

pub fn absolute_ethical_required_test() {
  np(EthicalMoral, Required, Possible)
  |> axioms.is_absolute_prohibition()
  |> should.be_true()
}

pub fn absolute_ethical_ought_test() {
  np(EthicalMoral, Ought, Possible)
  |> axioms.is_absolute_prohibition()
  |> should.be_false()
}

pub fn absolute_legal_required_test() {
  np(Legal, Required, Possible)
  |> axioms.is_absolute_prohibition()
  |> should.be_false()
}

// ---------------------------------------------------------------------------
// has_moral_priority (Axiom 6.3)
// ---------------------------------------------------------------------------

pub fn moral_priority_higher_system_test() {
  axioms.has_moral_priority(
    np(EthicalMoral, Required, Possible),
    np(Operational, Required, Possible),
  )
  |> should.be_true()
}

pub fn moral_priority_equal_test() {
  axioms.has_moral_priority(
    np(Legal, Required, Possible),
    np(Legal, Required, Possible),
  )
  |> should.be_false()
}

pub fn moral_priority_lower_system_test() {
  axioms.has_moral_priority(
    np(Operational, Required, Possible),
    np(EthicalMoral, Required, Possible),
  )
  |> should.be_false()
}

// ---------------------------------------------------------------------------
// has_moral_rank (Axiom 6.4)
// ---------------------------------------------------------------------------

pub fn moral_rank_stronger_operator_test() {
  axioms.has_moral_rank(
    np(Legal, Required, Possible),
    np(Legal, Ought, Possible),
  )
  |> should.be_true()
}

pub fn moral_rank_equal_operator_test() {
  axioms.has_moral_rank(np(Legal, Ought, Possible), np(Legal, Ought, Possible))
  |> should.be_false()
}

pub fn moral_rank_different_level_test() {
  axioms.has_moral_rank(
    np(EthicalMoral, Required, Possible),
    np(Legal, Ought, Possible),
  )
  |> should.be_false()
}

// ---------------------------------------------------------------------------
// is_normatively_open (Axiom 6.5)
// ---------------------------------------------------------------------------

pub fn normatively_open_empty_test() {
  axioms.is_normatively_open([])
  |> should.be_true()
}

pub fn normatively_open_all_no_conflict_test() {
  let c =
    VirtueConflictResult(
      user_np: np(Operational, Ought, Possible),
      system_np: np(EthicalMoral, Required, Possible),
      severity: NoConflict,
      resolution: NoConflictResolution,
      rule_fired: "test",
    )
  axioms.is_normatively_open([c])
  |> should.be_true()
}

pub fn normatively_open_with_conflict_test() {
  let c =
    VirtueConflictResult(
      user_np: np(Operational, Ought, Possible),
      system_np: np(EthicalMoral, Required, Possible),
      severity: types.Superordinate,
      resolution: types.SystemWins,
      rule_fired: "test",
    )
  axioms.is_normatively_open([c])
  |> should.be_false()
}

pub fn normatively_open_mixed_test() {
  let no_c =
    VirtueConflictResult(
      user_np: np(Operational, Ought, Possible),
      system_np: np(SafetyPhysical, Required, Possible),
      severity: NoConflict,
      resolution: NoConflictResolution,
      rule_fired: "test",
    )
  let has_c =
    VirtueConflictResult(
      user_np: np(Legal, Required, Possible),
      system_np: np(EthicalMoral, Required, Possible),
      severity: types.Superordinate,
      resolution: types.SystemWins,
      rule_fired: "test",
    )
  axioms.is_normatively_open([no_c, has_c])
  |> should.be_false()
}
