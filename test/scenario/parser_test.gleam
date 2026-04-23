//// Parser unit tests. Covers the pure TOML-to-Scenario shape: fields,
//// step dispatch, assertion dispatch, error cases.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/option.{None, Some}
import gleeunit/should
import scenario/parser
import scenario/types

pub fn parse_minimal_scenario_test() {
  let toml = "[scenario]\nname = \"minimal\"\n"
  let assert Ok(s) = parser.parse_string(toml)
  s.name |> should.equal("minimal")
  s.description |> should.equal("")
  s.catches_regression_of |> should.equal([])
  s.steps |> should.equal([])
  s.asserts |> should.equal([])
}

pub fn missing_name_fails_test() {
  let toml = "[scenario]\n"
  case parser.parse_string(toml) {
    Error(parser.MissingField(path)) -> path |> should.equal("scenario.name")
    _ -> should.fail()
  }
}

pub fn parse_send_user_input_step_test() {
  let toml =
    "[scenario]\nname = \"x\"\n\n"
    <> "[[step]]\ntype = \"send_user_input\"\nsource_id = \"s1\"\ntext = \"hi\"\n"
  let assert Ok(s) = parser.parse_string(toml)
  case s.steps {
    [types.SendUserInput(source_id:, text:)] -> {
      source_id |> should.equal("s1")
      text |> should.equal("hi")
    }
    _ -> should.fail()
  }
}

pub fn parse_wait_for_reply_step_test() {
  let toml =
    "[scenario]\nname = \"x\"\n\n"
    <> "[[step]]\ntype = \"wait_for_reply\"\ntimeout_ms = 5000\n"
  let assert Ok(s) = parser.parse_string(toml)
  case s.steps {
    [types.WaitForReply(timeout_ms:)] -> timeout_ms |> should.equal(5000)
    _ -> should.fail()
  }
}

pub fn parse_wait_duration_step_test() {
  let toml =
    "[scenario]\nname = \"x\"\n\n"
    <> "[[step]]\ntype = \"wait_duration\"\nduration_ms = 250\n"
  let assert Ok(s) = parser.parse_string(toml)
  case s.steps {
    [types.WaitDuration(duration_ms:)] -> duration_ms |> should.equal(250)
    _ -> should.fail()
  }
}

pub fn unknown_step_fails_test() {
  let toml =
    "[scenario]\nname = \"x\"\n\n" <> "[[step]]\ntype = \"summon_demon\"\n"
  case parser.parse_string(toml) {
    Error(parser.UnknownStepType(t)) -> t |> should.equal("summon_demon")
    _ -> should.fail()
  }
}

pub fn parse_log_absent_assertion_test() {
  let toml =
    "[scenario]\nname = \"x\"\n\n"
    <> "[[assert]]\ntype = \"log_absent\"\npattern = \"bad\"\nmessage = \"oops\"\n"
  let assert Ok(s) = parser.parse_string(toml)
  case s.asserts {
    [types.LogAbsent(pattern:, message:)] -> {
      pattern |> should.equal("bad")
      message |> should.equal("oops")
    }
    _ -> should.fail()
  }
}

pub fn parse_log_present_assertion_test() {
  let toml =
    "[scenario]\nname = \"x\"\n\n"
    <> "[[assert]]\ntype = \"log_present\"\npattern = \"Started scheduler\"\n"
  let assert Ok(s) = parser.parse_string(toml)
  case s.asserts {
    [types.LogPresent(pattern:, ..)] ->
      pattern |> should.equal("Started scheduler")
    _ -> should.fail()
  }
}

pub fn parse_narrative_entry_count_with_both_bounds_test() {
  let toml =
    "[scenario]\nname = \"x\"\n\n"
    <> "[[assert]]\ntype = \"narrative_entry_count\"\nmin = 1\nmax = 3\n"
  let assert Ok(s) = parser.parse_string(toml)
  case s.asserts {
    [types.NarrativeEntryCount(min_count:, max_count:, ..)] -> {
      min_count |> should.equal(1)
      max_count |> should.equal(Some(3))
    }
    _ -> should.fail()
  }
}

pub fn parse_narrative_entry_count_without_max_test() {
  let toml =
    "[scenario]\nname = \"x\"\n\n"
    <> "[[assert]]\ntype = \"narrative_entry_count\"\nmin = 1\n"
  let assert Ok(s) = parser.parse_string(toml)
  case s.asserts {
    [types.NarrativeEntryCount(min_count:, max_count:, ..)] -> {
      min_count |> should.equal(1)
      max_count |> should.equal(None)
    }
    _ -> should.fail()
  }
}

pub fn unknown_assertion_fails_test() {
  let toml =
    "[scenario]\nname = \"x\"\n\n" <> "[[assert]]\ntype = \"check_horoscope\"\n"
  case parser.parse_string(toml) {
    Error(parser.UnknownAssertType(t)) -> t |> should.equal("check_horoscope")
    _ -> should.fail()
  }
}

pub fn parse_catches_regression_of_list_test() {
  let toml =
    "[scenario]\nname = \"x\"\n"
    <> "catches_regression_of = [\"PR-107\", \"PR-113\"]\n"
  let assert Ok(s) = parser.parse_string(toml)
  s.catches_regression_of |> should.equal(["PR-107", "PR-113"])
}

pub fn reference_scenario_parses_test() {
  // The reply-to-noise scenario that ships with Phase 1 must parse cleanly.
  let assert Ok(s) = parser.parse_file("test/scenarios/reply-to-noise.toml")
  s.name |> should.equal("reply_to noise regression")
  // 2 steps: send_user_input, wait_for_reply
  // 2 asserts: log_absent x2
  s.steps
  |> should.equal([
    types.SendUserInput(source_id: "scenario:reply-to-noise", text: "Hello"),
    types.WaitForReply(timeout_ms: 30_000),
  ])
}
