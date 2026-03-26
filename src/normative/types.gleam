//// Normative Calculus types — Stoic-inspired deterministic safety reasoning.
////
//// Based on Becker's *A New Stoicism* and the TallMountain normative calculus.
//// These types model normative propositions (level + operator + modality),
//// conflict resolution, and virtue-based judgement. All computation is pure —
//// no LLM calls, no I/O.

// ---------------------------------------------------------------------------
// Normative levels — 14-tier hierarchy of normative concerns
// ---------------------------------------------------------------------------

/// Normative level representing the domain of a concern.
/// Higher ordinals indicate stronger normative weight.
pub type NormativeLevel {
  EthicalMoral
  Legal
  SafetyPhysical
  PrivacyData
  IntellectualHonesty
  ProfessionalEthics
  UserAutonomy
  Transparency
  Proportionality
  Efficiency
  Courtesy
  Stylistic
  Aesthetic
  Operational
}

/// Numeric ordinal for level comparison. Higher = stronger normative weight.
pub fn level_ordinal(level: NormativeLevel) -> Int {
  case level {
    EthicalMoral -> 6000
    Legal -> 5000
    SafetyPhysical -> 4500
    PrivacyData -> 4000
    IntellectualHonesty -> 3500
    ProfessionalEthics -> 3000
    UserAutonomy -> 2500
    Transparency -> 2000
    Proportionality -> 1500
    Efficiency -> 1000
    Courtesy -> 750
    Stylistic -> 500
    Aesthetic -> 250
    Operational -> 100
  }
}

// ---------------------------------------------------------------------------
// Normative operators — deontic strength
// ---------------------------------------------------------------------------

/// Deontic operator — how strongly something is normatively required.
pub type NormativeOperator {
  Required
  Ought
  Indifferent
}

/// Numeric ordinal for operator comparison. Higher = stronger.
pub fn operator_ordinal(op: NormativeOperator) -> Int {
  case op {
    Required -> 3
    Ought -> 2
    Indifferent -> 1
  }
}

// ---------------------------------------------------------------------------
// Modality
// ---------------------------------------------------------------------------

/// Alethic modality — whether something is achievable.
pub type Modality {
  Possible
  Impossible
}

// ---------------------------------------------------------------------------
// Normative proposition
// ---------------------------------------------------------------------------

/// A normative proposition: a claim about what should/must/may be done.
pub type NormativeProposition {
  NormativeProposition(
    level: NormativeLevel,
    operator: NormativeOperator,
    modality: Modality,
    description: String,
  )
}

// ---------------------------------------------------------------------------
// Conflict resolution types
// ---------------------------------------------------------------------------

/// Severity of a conflict between two normative propositions.
pub type ConflictSeverity {
  /// No conflict detected — propositions are compatible
  NoConflict
  /// Both propositions have equal weight — coordination needed
  Coordinate
  /// System proposition dominates — system wins
  Superordinate
  /// Absolute prohibition — categorical override
  Absolute
}

/// Numeric ordinal for severity. Higher = more severe.
pub fn severity_ordinal(severity: ConflictSeverity) -> Int {
  case severity {
    NoConflict -> 0
    Coordinate -> 2
    Superordinate -> 3
    Absolute -> 4
  }
}

/// How a conflict was resolved.
pub type ConflictResolution {
  SystemWins
  CoordinateConflict
  NoConflictResolution
}

/// Result of resolving a conflict between a user-side and system-side NP.
pub type VirtueConflictResult {
  VirtueConflictResult(
    user_np: NormativeProposition,
    system_np: NormativeProposition,
    severity: ConflictSeverity,
    resolution: ConflictResolution,
    rule_fired: String,
  )
}

// ---------------------------------------------------------------------------
// Harm context
// ---------------------------------------------------------------------------

/// Contextual information about potential harm derived from D' forecasts.
pub type HarmContext {
  HarmContext(
    /// Aggregate impact score from forecasts [0.0, 1.0]
    impact_score: Float,
    /// Whether any critical feature scored maximum magnitude
    catastrophic: Bool,
  )
}

// ---------------------------------------------------------------------------
// Flourishing verdict + judgement
// ---------------------------------------------------------------------------

/// The eudaimonic verdict — does the output promote flourishing?
pub type FlourishingVerdict {
  /// Output promotes flourishing — accept
  Flourishing
  /// Output has normative tensions — modify
  Constrained
  /// Output violates core commitments — reject
  Prohibited
}

/// Full normative judgement with audit trail.
pub type NormativeJudgement {
  NormativeJudgement(
    verdict: FlourishingVerdict,
    floor_rule: String,
    conflicts: List(VirtueConflictResult),
    axiom_trail: List(String),
  )
}

// ---------------------------------------------------------------------------
// Character specification
// ---------------------------------------------------------------------------

/// A named virtue with behavioural expressions.
pub type Virtue {
  Virtue(name: String, expressions: List(String))
}

/// The agent's character specification — virtues and highest endeavour.
/// The highest endeavour is the set of normative commitments the agent
/// holds as non-negotiable.
pub type CharacterSpec {
  CharacterSpec(
    virtues: List(Virtue),
    highest_endeavour: List(NormativeProposition),
  )
}
