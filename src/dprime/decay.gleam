//// Confidence decay — half-life based decay for facts and CBR cases.
////
//// Applies a mathematical half-life function at read/query time so that
//// stored confidence values naturally diminish as information ages.
//// The stored confidence is never mutated (append-only principle).
////
//// Formula: confidence_t = confidence_0 * 2^(-age_days / half_life_days)

import gleam/float
import gleam/int

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "math", "pow")
fn math_pow(base: Float, exponent: Float) -> Float

@external(erlang, "springdrift_ffi", "days_between")
fn days_between(date_a: String, date_b: String) -> Int

// ---------------------------------------------------------------------------
// Core decay function
// ---------------------------------------------------------------------------

/// Apply half-life confidence decay.
///
/// Returns original_confidence * 2^(-age_days / half_life_days), clamped
/// to [0.0, 1.0]. When age_days <= 0 or half_life_days <= 0, returns the
/// original confidence unchanged.
pub fn decay_confidence(
  original_confidence: Float,
  age_days: Int,
  half_life_days: Int,
) -> Float {
  case age_days <= 0 || half_life_days <= 0 {
    True -> original_confidence
    False -> {
      let exponent =
        float.negate(int.to_float(age_days) /. int.to_float(half_life_days))
      let decayed = original_confidence *. math_pow(2.0, exponent)
      // Clamp to [0.0, 1.0]
      float.min(1.0, float.max(0.0, decayed))
    }
  }
}

/// Apply decay to a fact's confidence based on its timestamp.
///
/// Extracts the date portion from fact_date (YYYY-MM-DD prefix of an ISO
/// timestamp) and computes the age in days relative to today.
pub fn decay_fact_confidence(
  confidence: Float,
  fact_date: String,
  today: String,
  half_life_days: Int,
) -> Float {
  let age = days_between(fact_date, today)
  decay_confidence(confidence, age, half_life_days)
}
