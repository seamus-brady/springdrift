//// Scenario runner. Boots a minimal cognitive + Frontdoor harness, drives
//// the declared steps against it, then evaluates the declared assertions.
//// Exits 0 on all-pass, 1 on any-fail, 2 on setup / parse failure.
////
//// The harness uses `cognitive_config.default_test_config` with a mock
//// provider by default. This is deliberate: scenarios are for asserting
//// on message-flow and state-transition behaviour, not LLM quality. Boot
//// is milliseconds, teardown is automatic on process exit.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/cognitive
import agent/cognitive_config
import agent/types as agent_types
import frontdoor
import frontdoor/types as frontdoor_types
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import llm/adapters/mock
import paths
import scenario/parser
import scenario/types.{
  type Assertion, type AssertionOutcome, type RunOutcome, type Scenario,
  type Step, Failed, LogAbsent, LogPresent, NarrativeEntryCount, Passed,
  RunOutcome, SendUserInput, WaitDuration, WaitForReply,
}
import simplifile
import slog

// ---------------------------------------------------------------------------
// Harness — subjects the runner holds to drive the instance
// ---------------------------------------------------------------------------

type Harness {
  Harness(
    cognitive: Subject(agent_types.CognitiveMessage),
    notify: Subject(agent_types.Notification),
    frontdoor: Subject(frontdoor_types.FrontdoorMessage),
    sinks: List(#(String, Subject(frontdoor_types.Delivery))),
    log_path: String,
    started_at_ms: Int,
  )
}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "monotonic_now_ms")
fn monotonic_now_ms() -> Int

@external(erlang, "erlang", "halt")
fn do_halt(code: Int) -> Nil

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Run the scenario at `path`. Exits the VM with 0 on pass, 1 on any failed
/// assertion, 2 on parse / setup failure.
pub fn run(path: String) -> Nil {
  io.println("Scenario runner — " <> path)
  case parser.parse_file(path) {
    Error(err) -> {
      io.println_error("Scenario parse failed: " <> describe_parse_error(err))
      do_halt(2)
    }
    Ok(scenario) -> {
      io.println("  name: " <> scenario.name)
      io.println(
        "  steps: "
        <> int.to_string(list.length(scenario.steps))
        <> ", asserts: "
        <> int.to_string(list.length(scenario.asserts)),
      )
      case execute(scenario) {
        Error(reason) -> {
          io.println_error("Scenario setup failed: " <> reason)
          do_halt(2)
        }
        Ok(outcome) -> {
          report(outcome)
          case outcome.failed {
            [] -> do_halt(0)
            _ -> do_halt(1)
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Execute
// ---------------------------------------------------------------------------

fn execute(scenario: Scenario) -> Result(RunOutcome, String) {
  use harness <- result_bind(boot_harness())
  let steps_result =
    list.each(scenario.steps, fn(step) { exec_step(harness, step) })
  let _ = steps_result
  // Evaluate assertions against the final state.
  let outcomes =
    list.map(scenario.asserts, fn(a) { eval_assertion(harness, a) })
  let #(passed, failed) =
    list.partition(outcomes, fn(o) {
      case o {
        Passed(..) -> True
        Failed(..) -> False
      }
    })
  Ok(RunOutcome(
    scenario_name: scenario.name,
    step_count: list.length(scenario.steps),
    passed:,
    failed:,
  ))
}

fn result_bind(r: Result(a, b), f: fn(a) -> Result(c, b)) -> Result(c, b) {
  case r {
    Ok(v) -> f(v)
    Error(e) -> Error(e)
  }
}

// ---------------------------------------------------------------------------
// Boot minimal harness (cognitive + Frontdoor + mock provider)
// ---------------------------------------------------------------------------

fn boot_harness() -> Result(Harness, String) {
  let provider = mock.provider_with_text("[scenario mock reply]")
  let notify: Subject(agent_types.Notification) = process.new_subject()
  let base = cognitive_config.default_test_config(provider, notify)
  let fd = frontdoor.start()
  let cfg = cognitive_config.CognitiveConfig(..base, frontdoor: Some(fd))
  case cognitive.start(cfg) {
    Error(_) -> Error("cognitive.start returned Error")
    Ok(cognitive_subj) -> {
      // Pre-flight the slog output path so log_absent assertions have
      // something to grep even if nothing gets logged. Today's file.
      let log_path =
        paths.logs_dir() <> "/" <> today_date_from_ffi() <> ".jsonl"
      Ok(Harness(
        cognitive: cognitive_subj,
        notify:,
        frontdoor: fd,
        sinks: [],
        log_path:,
        started_at_ms: monotonic_now_ms(),
      ))
    }
  }
}

@external(erlang, "springdrift_ffi", "get_date")
fn today_date_from_ffi() -> String

// ---------------------------------------------------------------------------
// Step execution
// ---------------------------------------------------------------------------

fn exec_step(harness: Harness, step: Step) -> Harness {
  case step {
    SendUserInput(source_id:, text:) -> {
      // Ensure a Frontdoor sink exists for this source_id so replies land.
      let #(harness2, _sink) = ensure_sink(harness, source_id)
      process.send(harness2.cognitive, agent_types.UserInput(source_id:, text:))
      harness2
    }
    WaitForReply(timeout_ms:) -> {
      // Wait for ANY registered sink to receive a DeliverReply.
      // Simple approach: iterate each sink with a short timeout slice.
      wait_for_any_reply(harness.sinks, timeout_ms)
      harness
    }
    WaitDuration(duration_ms:) -> {
      process.sleep(duration_ms)
      harness
    }
  }
}

fn ensure_sink(
  harness: Harness,
  source_id: String,
) -> #(Harness, Subject(frontdoor_types.Delivery)) {
  case list.find(harness.sinks, fn(pair) { pair.0 == source_id }) {
    Ok(pair) -> #(harness, pair.1)
    Error(_) -> {
      let sink: Subject(frontdoor_types.Delivery) = process.new_subject()
      process.send(
        harness.frontdoor,
        frontdoor_types.Subscribe(
          source_id:,
          kind: frontdoor_types.UserSource,
          sink:,
        ),
      )
      let new_sinks = [#(source_id, sink), ..harness.sinks]
      #(Harness(..harness, sinks: new_sinks), sink)
    }
  }
}

/// Poll each sink in turn with a small per-sink timeout until something
/// arrives or the overall deadline expires. Crude but works for MVP —
/// single-sink scenarios are the common case.
fn wait_for_any_reply(
  sinks: List(#(String, Subject(frontdoor_types.Delivery))),
  overall_timeout_ms: Int,
) -> Nil {
  let deadline = monotonic_now_ms() + overall_timeout_ms
  wait_for_any_reply_loop(sinks, deadline)
}

fn wait_for_any_reply_loop(
  sinks: List(#(String, Subject(frontdoor_types.Delivery))),
  deadline_ms: Int,
) -> Nil {
  let now = monotonic_now_ms()
  case now >= deadline_ms, sinks {
    True, _ -> Nil
    _, [] -> Nil
    _, [#(_, sink), ..rest] -> {
      case process.receive(sink, 100) {
        Ok(frontdoor_types.DeliverReply(..)) -> Nil
        _ ->
          wait_for_any_reply_loop(list.append(rest, [#("", sink)]), deadline_ms)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Assertion evaluation
// ---------------------------------------------------------------------------

fn eval_assertion(harness: Harness, a: Assertion) -> AssertionOutcome {
  case a {
    LogAbsent(pattern:, ..) ->
      case log_has_line_matching(harness.log_path, pattern) {
        True -> Failed(a, "Pattern found in log: " <> pattern)
        False -> Passed(a)
      }
    LogPresent(pattern:, ..) ->
      case log_has_line_matching(harness.log_path, pattern) {
        True -> Passed(a)
        False -> Failed(a, "Pattern not found in log: " <> pattern)
      }
    NarrativeEntryCount(min_count:, max_count:, ..) -> {
      let n = count_narrative_entries_since(harness.started_at_ms)
      let below_min = n < min_count
      let above_max = case max_count {
        Some(max) -> n > max
        None -> False
      }
      case below_min || above_max {
        True ->
          Failed(
            a,
            "Narrative entry count=" <> int.to_string(n) <> " out of range",
          )
        False -> Passed(a)
      }
    }
  }
}

fn log_has_line_matching(path: String, pattern: String) -> Bool {
  case simplifile.read(path) {
    Error(_) -> False
    Ok(content) -> string.contains(content, pattern)
  }
}

fn count_narrative_entries_since(_since_ms: Int) -> Int {
  // MVP: count all lines in today's narrative file. Precise since-time
  // filtering requires JSON parsing; not needed for the first scenario.
  let path = paths.narrative_dir() <> "/" <> today_date_from_ffi() <> ".jsonl"
  case simplifile.read(path) {
    Error(_) -> 0
    Ok(content) ->
      string.split(content, "\n")
      |> list.filter(fn(line) { line != "" })
      |> list.length
  }
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

fn report(outcome: RunOutcome) -> Nil {
  let total = list.length(outcome.passed) + list.length(outcome.failed)
  io.println("")
  io.println("Scenario: " <> outcome.scenario_name)
  io.println("  steps run:   " <> int.to_string(outcome.step_count))
  io.println(
    "  assertions:  "
    <> int.to_string(list.length(outcome.passed))
    <> " passed, "
    <> int.to_string(list.length(outcome.failed))
    <> " failed, "
    <> int.to_string(total)
    <> " total",
  )
  list.each(outcome.failed, fn(o) {
    case o {
      Failed(_, reason) -> io.println("  ✗ " <> reason)
      _ -> Nil
    }
  })
  slog.info(
    "scenario/runner",
    "report",
    "Scenario '"
      <> outcome.scenario_name
      <> "' "
      <> case outcome.failed {
      [] -> "PASSED"
      _ -> "FAILED"
    },
    option.None,
  )
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn describe_parse_error(err: parser.ParseError) -> String {
  case err {
    parser.FileReadFailed(path) -> "Could not read " <> path
    parser.TomlParseFailed -> "TOML parse failure"
    parser.MissingField(path) -> "Missing required field: " <> path
    parser.UnknownStepType(t) -> "Unknown step type: " <> t
    parser.UnknownAssertType(t) -> "Unknown assertion type: " <> t
  }
}
