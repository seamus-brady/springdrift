//// TOML scenario parser. Builds a `Scenario` from a TOML file. Unknown
//// step / assertion types are a hard error — scenarios are regression
//// tests and a silently-skipped step is worse than an outright failure.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import scenario/types.{
  type Assertion, type Scenario, type Step, LogAbsent, LogPresent,
  NarrativeEntryCount, Scenario, SendUserInput, WaitDuration, WaitForReply,
}
import simplifile
import tom

pub type ParseError {
  FileReadFailed(path: String)
  TomlParseFailed
  MissingField(path: String)
  UnknownStepType(type_name: String)
  UnknownAssertType(type_name: String)
}

pub fn parse_file(path: String) -> Result(Scenario, ParseError) {
  use content <- result.try(
    simplifile.read(path)
    |> result.replace_error(FileReadFailed(path)),
  )
  parse_string(content)
}

pub fn parse_string(input: String) -> Result(Scenario, ParseError) {
  use toml <- result.try(
    tom.parse(input) |> result.replace_error(TomlParseFailed),
  )
  use name <- result.try(
    tom.get_string(toml, ["scenario", "name"])
    |> result.replace_error(MissingField("scenario.name")),
  )
  let description =
    tom.get_string(toml, ["scenario", "description"])
    |> result.unwrap("")
  let catches_regression_of =
    get_string_array(toml, ["scenario", "catches_regression_of"])
    |> option.unwrap([])

  use steps <- result.try(parse_steps(toml))
  use asserts <- result.try(parse_asserts(toml))

  Ok(Scenario(name:, description:, catches_regression_of:, steps:, asserts:))
}

// ---------------------------------------------------------------------------
// Steps
// ---------------------------------------------------------------------------

fn parse_steps(
  toml: dict.Dict(String, tom.Toml),
) -> Result(List(Step), ParseError) {
  case tom.get_array(toml, ["step"]) {
    Error(_) -> Ok([])
    Ok(items) -> items |> list.try_map(parse_step)
  }
}

fn parse_step(item: tom.Toml) -> Result(Step, ParseError) {
  case item {
    tom.InlineTable(table) | tom.Table(table) -> parse_step_table(table)
    _ -> Error(MissingField("step"))
  }
}

fn parse_step_table(
  table: dict.Dict(String, tom.Toml),
) -> Result(Step, ParseError) {
  use type_name <- result.try(
    tom.get_string(table, ["type"])
    |> result.replace_error(MissingField("step.type")),
  )
  case type_name {
    "send_user_input" -> {
      use source_id <- result.try(
        tom.get_string(table, ["source_id"])
        |> result.replace_error(MissingField("step.source_id")),
      )
      use text <- result.try(
        tom.get_string(table, ["text"])
        |> result.replace_error(MissingField("step.text")),
      )
      Ok(SendUserInput(source_id:, text:))
    }
    "wait_for_reply" -> {
      let timeout_ms =
        tom.get_int(table, ["timeout_ms"]) |> result.unwrap(30_000)
      Ok(WaitForReply(timeout_ms:))
    }
    "wait_duration" -> {
      use duration_ms <- result.try(
        tom.get_int(table, ["duration_ms"])
        |> result.replace_error(MissingField("step.duration_ms")),
      )
      Ok(WaitDuration(duration_ms:))
    }
    other -> Error(UnknownStepType(other))
  }
}

// ---------------------------------------------------------------------------
// Assertions
// ---------------------------------------------------------------------------

fn parse_asserts(
  toml: dict.Dict(String, tom.Toml),
) -> Result(List(Assertion), ParseError) {
  case tom.get_array(toml, ["assert"]) {
    Error(_) -> Ok([])
    Ok(items) -> items |> list.try_map(parse_assert)
  }
}

fn parse_assert(item: tom.Toml) -> Result(Assertion, ParseError) {
  case item {
    tom.InlineTable(table) | tom.Table(table) -> parse_assert_table(table)
    _ -> Error(MissingField("assert"))
  }
}

fn parse_assert_table(
  table: dict.Dict(String, tom.Toml),
) -> Result(Assertion, ParseError) {
  use type_name <- result.try(
    tom.get_string(table, ["type"])
    |> result.replace_error(MissingField("assert.type")),
  )
  case type_name {
    "log_absent" -> {
      use pattern <- result.try(
        tom.get_string(table, ["pattern"])
        |> result.replace_error(MissingField("assert.pattern")),
      )
      let message =
        tom.get_string(table, ["message"])
        |> result.unwrap("Pattern found in log: " <> pattern)
      Ok(LogAbsent(pattern:, message:))
    }
    "log_present" -> {
      use pattern <- result.try(
        tom.get_string(table, ["pattern"])
        |> result.replace_error(MissingField("assert.pattern")),
      )
      let message =
        tom.get_string(table, ["message"])
        |> result.unwrap("Pattern not found in log: " <> pattern)
      Ok(LogPresent(pattern:, message:))
    }
    "narrative_entry_count" -> {
      use min_count <- result.try(
        tom.get_int(table, ["min"])
        |> result.replace_error(MissingField("assert.min")),
      )
      let max_count = case tom.get_int(table, ["max"]) {
        Ok(n) -> Some(n)
        Error(_) -> None
      }
      let message =
        tom.get_string(table, ["message"])
        |> result.unwrap("Narrative entry count out of range")
      Ok(NarrativeEntryCount(min_count:, max_count:, message:))
    }
    other -> Error(UnknownAssertType(other))
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn get_string_array(
  table: dict.Dict(String, tom.Toml),
  path: List(String),
) -> Option(List(String)) {
  case tom.get_array(table, path) {
    Error(_) -> None
    Ok(items) ->
      Some(
        list.filter_map(items, fn(item) {
          case item {
            tom.String(s) -> Ok(s)
            _ -> Error(Nil)
          }
        }),
      )
  }
}
