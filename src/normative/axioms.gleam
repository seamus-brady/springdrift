//// Stoic axioms — deterministic pre-processors for normative conflict resolution.
////
//// Six axioms from Becker's *A New Stoicism* (§6.2–6.7), ported from
//// TallMountain's Python implementation. Each axiom is a pure predicate
//// that can short-circuit conflict resolution before the main rules fire.

import normative/types.{
  type NormativeProposition, type VirtueConflictResult, EthicalMoral, Impossible,
  Indifferent, Required,
}

/// Axiom 6.6 — Futility: an IMPOSSIBLE proposition is normatively inert.
/// If something cannot be done, it carries no normative weight.
pub fn is_futile(np: NormativeProposition) -> Bool {
  np.modality == Impossible
}

/// Axiom 6.7 — Indifference: an INDIFFERENT proposition carries no weight.
/// If the operator doesn't care, there's nothing to conflict with.
pub fn is_indifferent(np: NormativeProposition) -> Bool {
  np.operator == Indifferent
}

/// Axiom 6.2 — Absolute prohibition: ETHICAL_MORAL + REQUIRED is categorical.
/// This combination represents an absolute moral imperative that cannot be
/// overridden by any other consideration.
pub fn is_absolute_prohibition(np: NormativeProposition) -> Bool {
  np.level == EthicalMoral && np.operator == Required
}

/// Axiom 6.3 — Moral priority: system NP at a higher level dominates.
/// When the system's normative concern operates at a higher level than
/// the user's, the system has moral priority.
pub fn has_moral_priority(
  system_np: NormativeProposition,
  user_np: NormativeProposition,
) -> Bool {
  types.level_ordinal(system_np.level) > types.level_ordinal(user_np.level)
}

/// Axiom 6.4 — Moral rank: same level, but system has stronger operator.
/// When both propositions address the same normative level, the one with
/// the stronger deontic operator (Required > Ought > Indifferent) dominates.
pub fn has_moral_rank(
  system_np: NormativeProposition,
  user_np: NormativeProposition,
) -> Bool {
  types.level_ordinal(system_np.level) == types.level_ordinal(user_np.level)
  && types.operator_ordinal(system_np.operator)
  > types.operator_ordinal(user_np.operator)
}

/// Axiom 6.5 — Normative openness: no confirmed conflicts means compatible.
/// When resolution produces no conflicts, the propositions are normatively open.
pub fn is_normatively_open(conflicts: List(VirtueConflictResult)) -> Bool {
  case conflicts {
    [] -> True
    _ -> list.all(conflicts, fn(c) { c.severity == types.NoConflict })
  }
}

import gleam/list
