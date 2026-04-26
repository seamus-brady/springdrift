//// Token / cost circuit breaker for the coder.
////
//// Independent of OpenCode's own cost tracking. The supervisor polls
//// session usage at config.cost_poll_interval_ms cadence, calls
//// evaluate/4 with the current snapshot, and acts on the verdict —
//// usually meaning: kill the OpenCode process, end the session, record
//// the breach as the session's outcome.
////
//// Why separate from the supervisor: the upstream regression that
//// motivated this (entire project sent on every request, 13k+ tokens
//// for trivial questions) shows the upstream can silently spend
//// against operator API keys. A tested, pure rule layer is worth more
//// than mingling these checks into the supervisor's lifecycle code.
////
//// See docs/roadmap/planned/real-coder-opencode.md §"Token-spend
//// circuit breaker — independent of OpenCode".

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import coder/types.{
  type CoderConfig, type CoderError, type SessionUsage, CostBudgetExceeded,
  HourlyBudgetExceeded, TokenBudgetExceeded,
}

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// What the supervisor should do given the latest usage snapshot.
pub type CircuitVerdict {
  /// Within all caps. Continue the session.
  Continue
  /// Per-task budget breached. Kill THIS session; future sessions in
  /// the hourly window remain allowed.
  KillTask(reason: CoderError)
  /// Hourly aggregate breached. Kill this session AND refuse new ones
  /// until the window rolls.
  KillHourly(reason: CoderError)
}

/// Rolling-hour cost window. `accumulated_usd` sums every session that
/// ended (or was killed) within the current window. The supervisor
/// updates it on each session teardown via add_session_cost/3.
pub type HourlyCost {
  HourlyCost(
    /// Total USD spent in the current window.
    accumulated_usd: Float,
    /// Unix milliseconds at which the current window started.
    window_started_at_ms: Int,
  )
}

// Window length is exactly one hour; surfacing as a constant keeps
// magic numbers out of the rule body.
const hour_ms: Int = 3_600_000

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

/// Initial hourly state — no spend yet, window starts at the supplied
/// wall-clock millisecond.
pub fn new_hourly(now_ms: Int) -> HourlyCost {
  HourlyCost(accumulated_usd: 0.0, window_started_at_ms: now_ms)
}

// ---------------------------------------------------------------------------
// Evaluation — pure
// ---------------------------------------------------------------------------

/// Decide whether the active session may continue. Order:
///   1. Hourly aggregate cap (most aggressive — refuses new sessions too)
///   2. Per-task token cap
///   3. Per-task cost cap
///
/// Hourly comes first deliberately: if the hourly cap is breached, the
/// per-task verdict is moot (session would still die) and the supervisor
/// needs the more-restrictive signal.
pub fn evaluate(
  usage: SessionUsage,
  hourly: HourlyCost,
  config: CoderConfig,
  now_ms: Int,
) -> CircuitVerdict {
  let rolled = maybe_roll_hourly(hourly, now_ms)

  // Project hourly: existing accumulated + this session's running cost.
  // `usage.cost_usd` is the in-flight spend, not yet added to `rolled`.
  let projected_hourly = rolled.accumulated_usd +. usage.cost_usd

  case projected_hourly >. config.max_cost_per_hour_usd {
    True ->
      KillHourly(HourlyBudgetExceeded(
        consumed_usd: projected_hourly,
        cap_usd: config.max_cost_per_hour_usd,
      ))
    False ->
      case usage.total_tokens > config.max_tokens_per_task {
        True ->
          KillTask(TokenBudgetExceeded(
            consumed: usage.total_tokens,
            cap: config.max_tokens_per_task,
          ))
        False ->
          case usage.cost_usd >. config.max_cost_per_task_usd {
            True ->
              KillTask(CostBudgetExceeded(
                consumed_usd: usage.cost_usd,
                cap_usd: config.max_cost_per_task_usd,
              ))
            False -> Continue
          }
      }
  }
}

// ---------------------------------------------------------------------------
// Window management — pure
// ---------------------------------------------------------------------------

/// If an hour has elapsed since the window started, return a fresh
/// window starting at now_ms with zero accumulated spend. Otherwise
/// pass the input through unchanged.
pub fn maybe_roll_hourly(hourly: HourlyCost, now_ms: Int) -> HourlyCost {
  let elapsed = now_ms - hourly.window_started_at_ms
  case elapsed >= hour_ms {
    True -> HourlyCost(accumulated_usd: 0.0, window_started_at_ms: now_ms)
    False -> hourly
  }
}

/// Add a completed session's cost to the hourly accumulator. Rolls the
/// window first if needed, so a session that ended after the hour
/// boundary lands in the new window.
pub fn add_session_cost(
  hourly: HourlyCost,
  session_cost_usd: Float,
  now_ms: Int,
) -> HourlyCost {
  let rolled = maybe_roll_hourly(hourly, now_ms)
  HourlyCost(
    accumulated_usd: rolled.accumulated_usd +. session_cost_usd,
    window_started_at_ms: rolled.window_started_at_ms,
  )
}
