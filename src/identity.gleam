//// Identity system — persona loading and session preamble templating.
////
//// The identity system provides two files:
////   1. persona.md — first-person character text. May reference identity
////      slots {{agent_name}} and {{agent_version}}, which are substituted
////      by `render_persona`. Other slots are not exposed here — keep
////      persona narrowly about WHO the agent is, not live state.
////   2. session_preamble.md — template with full {{slot}} syntax and
////      OMIT IF rules for live working context.
////
//// File lookup order (first found wins per file):
////   1. .springdrift/identity/ (local project override)
////   2. ~/.config/springdrift/identity/ (global user default)
////
//// The Curator calls `load_persona` and `render_preamble` to assemble the
//// system prompt. If neither identity directory exists, the caller falls
//// back to the configured system_prompt verbatim.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import paths
import simplifile

// ---------------------------------------------------------------------------
// Persona
// ---------------------------------------------------------------------------

/// Load persona.md from the first identity directory that contains it.
/// Returns None if not found in any directory.
pub fn load_persona(dirs: List(String)) -> Option(String) {
  find_and_read(dirs, paths.persona_filename)
}

/// Load session_preamble.md from the first identity directory that contains it.
/// Returns None if not found in any directory.
pub fn load_preamble_template(dirs: List(String)) -> Option(String) {
  find_and_read(dirs, paths.preamble_filename)
}

fn find_and_read(dirs: List(String), filename: String) -> Option(String) {
  case dirs {
    [] -> None
    [dir, ..rest] -> {
      let path = dir <> "/" <> filename
      case simplifile.read(path) {
        Ok(content) -> Some(string.trim(content))
        Error(_) -> find_and_read(rest, filename)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Template rendering
// ---------------------------------------------------------------------------

/// A slot value to substitute into a preamble template.
pub type SlotValue {
  SlotValue(key: String, value: String)
}

/// Render a preamble template by substituting {{slot}} placeholders
/// and applying OMIT IF rules. Lines containing unresolved slots or
/// matching OMIT conditions are dropped.
pub fn render_preamble(template: String, slots: List(SlotValue)) -> String {
  template
  |> string.split("\n")
  |> list.filter_map(fn(line) { render_line(line, slots) })
  |> string.join("\n")
  |> collapse_blank_lines()
}

fn render_line(line: String, slots: List(SlotValue)) -> Result(String, Nil) {
  // Strip OMIT IF comment from the line for evaluation
  let #(content, omit_rule) = extract_omit_rule(line)
  let rendered = substitute_slots(content, slots)

  // Check if any unresolved {{...}} remain
  case string.contains(rendered, "{{") {
    True -> Error(Nil)
    False ->
      case should_omit(rendered, omit_rule) {
        True -> Error(Nil)
        False -> Ok(rendered)
      }
  }
}

/// Extract an OMIT IF rule from a line comment.
/// Returns (content_without_comment, optional_rule).
fn extract_omit_rule(line: String) -> #(String, Option(String)) {
  case string.split(line, "[OMIT IF ") {
    [content, rest] ->
      case string.split(rest, "]") {
        [rule, ..] -> #(string.trim_end(content), Some(string.trim(rule)))
        _ -> #(line, None)
      }
    _ -> #(line, None)
  }
}

/// Check if a rendered line should be omitted based on its OMIT IF rule.
fn should_omit(rendered: String, rule: Option(String)) -> Bool {
  case rule {
    None -> False
    Some("EMPTY") -> string.trim(rendered) == "" || ends_with_colon(rendered)
    Some("ZERO") -> contains_zero_count(rendered)
    Some("THREADS EXIST") -> False
    Some("FACTS EXIST") -> False
    Some("NO PROFILE") -> True
    Some(_) -> False
  }
}

fn ends_with_colon(s: String) -> Bool {
  let trimmed = string.trim(s)
  string.ends_with(trimmed, ":")
}

fn contains_zero_count(s: String) -> Bool {
  let trimmed = string.trim(s)
  string.starts_with(trimmed, "0 ") || string.contains(trimmed, " 0 ")
}

/// Substitute all {{key}} placeholders in a string with their values.
pub fn substitute_slots(text: String, slots: List(SlotValue)) -> String {
  case slots {
    [] -> text
    [SlotValue(key:, value:), ..rest] -> {
      let placeholder = "{{" <> key <> "}}"
      let replaced = string.replace(text, placeholder, value)
      substitute_slots(replaced, rest)
    }
  }
}

/// Render persona text by substituting only the identity slots
/// ({{agent_name}}, {{agent_version}}). Persona is fixed character text —
/// it should not reference live working state, so the full preamble slot
/// set is intentionally not exposed here.
pub fn render_persona(
  persona: String,
  agent_name: String,
  agent_version: String,
) -> String {
  substitute_slots(persona, [
    SlotValue(key: "agent_name", value: agent_name),
    SlotValue(key: "agent_version", value: agent_version),
  ])
}

/// Collapse runs of 3+ blank lines into 2.
fn collapse_blank_lines(text: String) -> String {
  case string.contains(text, "\n\n\n\n") {
    True -> collapse_blank_lines(string.replace(text, "\n\n\n\n", "\n\n\n"))
    False -> text
  }
}

// ---------------------------------------------------------------------------
// System prompt assembly
// ---------------------------------------------------------------------------

/// Assemble the full system prompt from persona + rendered preamble.
/// The preamble is wrapped in a configurable memory block tag.
pub fn assemble_system_prompt(
  persona: Option(String),
  preamble: Option(String),
  memory_tag: String,
) -> Option(String) {
  case persona, preamble {
    None, None -> None
    Some(p), None -> Some(p)
    None, Some(pre) ->
      Some("<" <> memory_tag <> ">\n" <> pre <> "\n</" <> memory_tag <> ">")
    Some(p), Some(pre) ->
      Some(
        p
        <> "\n\n<"
        <> memory_tag
        <> ">\n"
        <> pre
        <> "\n</"
        <> memory_tag
        <> ">",
      )
  }
}

// ---------------------------------------------------------------------------
// Relative date formatting
// ---------------------------------------------------------------------------

/// Format a date relative to today.
/// Input: days_ago (0 = today, 1 = yesterday, etc.)
pub fn format_relative_date(days_ago: Int) -> String {
  case days_ago {
    0 -> "today"
    1 -> "yesterday"
    n if n >= 2 && n <= 6 -> int.to_string(n) <> " days ago"
    n if n >= 7 && n <= 13 -> "last week"
    n if n >= 14 && n <= 29 -> int.to_string(n) <> " days ago"
    _ -> "more than 30 days ago"
  }
}

/// Format a date string relative to a reference date string.
/// Both should be YYYY-MM-DD format. Falls back to the raw date on parse failure.
pub fn format_relative_date_from_strings(date: String, today: String) -> String {
  let days = date_diff_days(today, date)
  case days {
    Ok(n) if n >= 0 && n <= 29 -> format_relative_date(n)
    Ok(_) -> date
    Error(_) -> date
  }
}

/// Compute difference in days between two YYYY-MM-DD strings (a - b).
/// Returns Ok(days) or Error(Nil) on parse failure.
fn date_diff_days(a: String, b: String) -> Result(Int, Nil) {
  case parse_ymd(a), parse_ymd(b) {
    Ok(#(ay, am, ad)), Ok(#(by, bm, bd)) -> {
      let days_a = ay * 365 + am * 30 + ad
      let days_b = by * 365 + bm * 30 + bd
      Ok(days_a - days_b)
    }
    _, _ -> Error(Nil)
  }
}

fn parse_ymd(date: String) -> Result(#(Int, Int, Int), Nil) {
  // Handle timestamps by extracting date part
  let date_part = case string.split(date, "T") {
    [d, ..] -> d
    _ -> date
  }
  case string.split(date_part, "-") {
    [y_str, m_str, d_str] ->
      case int.parse(y_str), int.parse(m_str), int.parse(d_str) {
        Ok(y), Ok(m), Ok(d) -> Ok(#(y, m, d))
        _, _, _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

// ---------------------------------------------------------------------------
// Slot builders
// ---------------------------------------------------------------------------

/// Build the active_threads slot text from thread data.
pub fn format_thread_lines(
  threads: List(#(String, Int, String, List(String))),
  today: String,
) -> String {
  threads
  |> list.map(fn(t) {
    let #(name, cycle_count, last_active, keywords) = t
    let relative = format_relative_date_from_strings(last_active, today)
    let kw_line = case keywords {
      [] -> ""
      kws -> "\n  Keywords: " <> string.join(list.take(kws, 5), ", ")
    }
    "- "
    <> name
    <> " — "
    <> int.to_string(cycle_count)
    <> " cycle(s), last active "
    <> relative
    <> kw_line
  })
  |> string.join("\n")
}

/// Build the recent_fact_sample slot text from fact data.
pub fn format_fact_lines(
  facts: List(#(String, String, String, Float)),
  today: String,
) -> String {
  facts
  |> list.take(3)
  |> list.map(fn(f) {
    let #(key, value, timestamp, confidence) = f
    let relative = format_relative_date_from_strings(timestamp, today)
    let pct = float.to_string(confidence *. 100.0)
    "- "
    <> key
    <> ": "
    <> value
    <> " (written "
    <> relative
    <> ", confidence "
    <> pct
    <> "%)"
  })
  |> string.join("\n")
}
