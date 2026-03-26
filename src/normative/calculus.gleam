//// Normative calculus — deterministic conflict resolution between normative
//// propositions.
////
//// Resolves conflicts between user-side NPs (derived from D' forecasts) and
//// system-side NPs (from the character spec's highest endeavour). The resolution
//// rules produce a severity + audit trail for each pair.
////
//// Resolution order:
//// 1. Pre-process: Futility, Indifference (short-circuit to NoConflict)
//// 2. Absolute prohibition check (Axiom 6.2)
//// 3. Level comparison (Axiom 6.3 — moral priority)
//// 4. Operator comparison at same level (Axiom 6.4 — moral rank)
//// 5. Same level + same operator → Coordinate conflict
//// 6. Default → NoConflict

import gleam/list
import normative/axioms
import normative/types.{
  type ConflictResolution, type ConflictSeverity, type NormativeProposition,
  type VirtueConflictResult, Absolute, Coordinate, CoordinateConflict,
  NoConflict, NoConflictResolution, Superordinate, SystemWins,
  VirtueConflictResult,
}

/// Resolve a single conflict between a user-side NP and a system-side NP.
///
/// The `has_conflict` flag indicates whether the D' scorer found a non-zero
/// magnitude for the relevant feature. When False, the pair is trivially
/// compatible (no conflict to resolve).
pub fn resolve(
  user_np: NormativeProposition,
  system_np: NormativeProposition,
  has_conflict: Bool,
) -> VirtueConflictResult {
  // No D' signal → no conflict
  case has_conflict {
    False ->
      make_result(
        user_np,
        system_np,
        NoConflict,
        NoConflictResolution,
        "no_dprime_signal",
      )
    True -> resolve_conflict(user_np, system_np)
  }
}

/// Resolve all pairs of user NPs against system NPs.
/// Each user NP is checked against every system NP, producing the
/// worst-case conflict for each pair.
pub fn resolve_all(
  user_nps: List(NormativeProposition),
  system_nps: List(NormativeProposition),
) -> List(VirtueConflictResult) {
  list.flat_map(user_nps, fn(user_np) {
    list.map(system_nps, fn(system_np) { resolve(user_np, system_np, True) })
  })
}

// ---------------------------------------------------------------------------
// Internal resolution logic
// ---------------------------------------------------------------------------

fn resolve_conflict(
  user_np: NormativeProposition,
  system_np: NormativeProposition,
) -> VirtueConflictResult {
  // Pre-processor 1: Futility — impossible user NP is inert
  case axioms.is_futile(user_np) {
    True ->
      make_result(
        user_np,
        system_np,
        NoConflict,
        NoConflictResolution,
        "axiom_6.6_futility",
      )
    False -> resolve_after_futility(user_np, system_np)
  }
}

fn resolve_after_futility(
  user_np: NormativeProposition,
  system_np: NormativeProposition,
) -> VirtueConflictResult {
  // Pre-processor 2: Indifference — indifferent user NP carries no weight
  case axioms.is_indifferent(user_np) {
    True ->
      make_result(
        user_np,
        system_np,
        NoConflict,
        NoConflictResolution,
        "axiom_6.7_indifference",
      )
    False -> resolve_after_indifference(user_np, system_np)
  }
}

fn resolve_after_indifference(
  user_np: NormativeProposition,
  system_np: NormativeProposition,
) -> VirtueConflictResult {
  // Rule 1: Absolute prohibition — system's ETHICAL_MORAL + REQUIRED
  case axioms.is_absolute_prohibition(system_np) {
    True ->
      make_result(
        user_np,
        system_np,
        Absolute,
        SystemWins,
        "axiom_6.2_absolute_prohibition",
      )
    False -> resolve_by_level(user_np, system_np)
  }
}

fn resolve_by_level(
  user_np: NormativeProposition,
  system_np: NormativeProposition,
) -> VirtueConflictResult {
  let system_level = types.level_ordinal(system_np.level)
  let user_level = types.level_ordinal(user_np.level)

  case system_level > user_level {
    // Rule 2: System level higher → system wins (Axiom 6.3)
    True ->
      make_result(
        user_np,
        system_np,
        Superordinate,
        SystemWins,
        "axiom_6.3_moral_priority",
      )
    False ->
      case system_level == user_level {
        True -> resolve_by_operator(user_np, system_np)
        // User level higher → no conflict from system's perspective
        False ->
          make_result(
            user_np,
            system_np,
            NoConflict,
            NoConflictResolution,
            "user_level_dominant",
          )
      }
  }
}

fn resolve_by_operator(
  user_np: NormativeProposition,
  system_np: NormativeProposition,
) -> VirtueConflictResult {
  let system_op = types.operator_ordinal(system_np.operator)
  let user_op = types.operator_ordinal(user_np.operator)

  case system_op > user_op {
    // Rule 3: Same level, system operator stronger → system wins (Axiom 6.4)
    True ->
      make_result(
        user_np,
        system_np,
        Superordinate,
        SystemWins,
        "axiom_6.4_moral_rank",
      )
    False ->
      case system_op == user_op {
        // Rule 4: Same level + same operator → coordinate
        True ->
          make_result(
            user_np,
            system_np,
            Coordinate,
            CoordinateConflict,
            "equal_weight_coordinate",
          )
        // Rule 5: User operator stronger → no conflict
        False ->
          make_result(
            user_np,
            system_np,
            NoConflict,
            NoConflictResolution,
            "user_operator_dominant",
          )
      }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_result(
  user_np: NormativeProposition,
  system_np: NormativeProposition,
  severity: ConflictSeverity,
  resolution: ConflictResolution,
  rule_fired: String,
) -> VirtueConflictResult {
  VirtueConflictResult(
    user_np:,
    system_np:,
    severity:,
    resolution:,
    rule_fired:,
  )
}
