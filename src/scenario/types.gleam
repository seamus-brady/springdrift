//// Scenario types — scripted integration-test definitions parsed from TOML.
////
//// A scenario is a sequence of steps followed by a set of assertions. Steps
//// drive the instance (send user input, wait for things to happen).
//// Assertions evaluate the resulting state (log contents, diagnostic fields,
//// filesystem state). The runner executes in the same process as the
//// instance, so "the instance" is just the subjects and subsystems this
//// module holds handles to.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/option.{type Option}

pub type Scenario {
  Scenario(
    name: String,
    description: String,
    catches_regression_of: List(String),
    steps: List(Step),
    asserts: List(Assertion),
  )
}

pub type Step {
  /// Send a `UserInput` message to the cognitive loop with the given
  /// source_id. The source_id claims a Frontdoor cycle so the reply
  /// routes back to our delivery sink.
  SendUserInput(source_id: String, text: String)
  /// Block until a `DeliverReply` arrives on the scenario's Frontdoor
  /// sink, or the timeout expires.
  WaitForReply(timeout_ms: Int)
  /// Block for a fixed duration. For scenarios that need background
  /// work (scheduler ticks, archivist completion) to settle.
  WaitDuration(duration_ms: Int)
}

pub type Assertion {
  /// Regex over the instance's slog output. Passes when no line matches.
  LogAbsent(pattern: String, message: String)
  /// Regex over the instance's slog output. Passes when at least one
  /// line matches.
  LogPresent(pattern: String, message: String)
  /// Count narrative entries written this run. Passes when the count
  /// is in [min, max] inclusive. max=None means no upper bound.
  NarrativeEntryCount(min_count: Int, max_count: Option(Int), message: String)
}

pub type AssertionOutcome {
  Passed(assertion: Assertion)
  Failed(assertion: Assertion, reason: String)
}

pub type RunOutcome {
  RunOutcome(
    scenario_name: String,
    step_count: Int,
    passed: List(AssertionOutcome),
    failed: List(AssertionOutcome),
  )
}
