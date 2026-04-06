//// Session summaries — periodic aggregation of narrative entries.
////
//// Generates a Summary-type NarrativeEntry by feeding recent entries
//// to the LLM for distillation. Supports weekly and monthly schedules.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import cycle_log
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/provider.{type Provider}
import narrative/log as narrative_log
import narrative/types.{
  type NarrativeEntry, Conversation, Entities, Intent, Metrics, NarrativeEntry,
  Outcome, Success, Summary,
}
import paths
import slog
import xstructor
import xstructor/schemas

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Generate a summary of entries in the given date range.
/// Returns None if there are no entries or the LLM call fails.
pub fn generate(
  dir: String,
  from: String,
  to: String,
  provider: Provider,
  model: String,
  _verbose: Bool,
) -> Option(NarrativeEntry) {
  let entries = narrative_log.load_entries(dir, from, to)
  case entries {
    [] -> {
      slog.info(
        "narrative/summary",
        "generate",
        "No entries in range " <> from <> " to " <> to,
        None,
      )
      None
    }
    _ -> {
      let prompt = build_summary_prompt(entries, from, to)
      let schema_dir = paths.schemas_dir()
      case
        xstructor.compile_schema(schema_dir, "summary.xsd", schemas.summary_xsd)
      {
        Error(_) -> Some(fallback_summary(entries, from, to))
        Ok(schema) -> {
          let system =
            schemas.build_system_prompt(
              summary_system_prompt_base(),
              schemas.summary_xsd,
              schemas.summary_example,
            )
          let config =
            xstructor.XStructorConfig(
              schema: schema,
              system_prompt: system,
              xml_example: schemas.summary_example,
              max_retries: 2,
              max_tokens: 2048,
            )
          case xstructor.generate(config, prompt, provider, model) {
            Ok(result) -> {
              let #(summary_text, keywords) = extract_summary(result.elements)
              let cycle_id = cycle_log.generate_uuid()
              slog.info(
                "narrative/summary",
                "generate",
                "Generated summary for "
                  <> from
                  <> " to "
                  <> to
                  <> " ("
                  <> int.to_string(list.length(entries))
                  <> " entries)",
                Some(cycle_id),
              )
              Some(build_summary_entry(
                cycle_id,
                summary_text,
                keywords,
                from,
                to,
                entries,
              ))
            }
            Error(_) -> {
              slog.warn(
                "narrative/summary",
                "generate",
                "XStructor generation failed for summary",
                None,
              )
              Some(fallback_summary(entries, from, to))
            }
          }
        }
      }
    }
  }
}

/// Generate and append a summary to the narrative log.
pub fn generate_and_append(
  dir: String,
  from: String,
  to: String,
  provider: Provider,
  model: String,
  verbose: Bool,
) -> Nil {
  case generate(dir, from, to, provider, model, verbose) {
    Some(entry) -> narrative_log.append(dir, entry)
    None -> Nil
  }
}

/// Determine the date range for a "weekly" summary ending today.
pub fn weekly_range(today: String) -> #(String, String) {
  // Simple approach: go back 7 days from today
  // Since we store dates as YYYY-MM-DD strings and load_entries
  // uses string comparison, we just need the start date
  let to = today
  let from = subtract_days(today, 7)
  #(from, to)
}

/// Determine the date range for a "monthly" summary ending today.
pub fn monthly_range(today: String) -> #(String, String) {
  let to = today
  let from = subtract_days(today, 30)
  #(from, to)
}

// ---------------------------------------------------------------------------
// Prompt
// ---------------------------------------------------------------------------

fn summary_system_prompt_base() -> String {
  "You are the Archivist for an AI agent called Springdrift. Your job is to write a first-person summary of what happened over a period of conversations.

RULES:
- Write in first person, past tense
- Identify themes, patterns, and recurring topics
- Note any trends in data or questions
- Highlight key decisions and their outcomes
- Be concise but comprehensive"
}

fn build_summary_prompt(
  entries: List(NarrativeEntry),
  from: String,
  to: String,
) -> String {
  let entry_summaries =
    list.index_map(entries, fn(entry, i) {
      int.to_string(i + 1)
      <> ". ["
      <> entry.cycle_id
      <> "] "
      <> entry.summary
      <> " (intent: "
      <> entry.intent.description
      <> ", outcome: "
      <> case entry.outcome.status {
        types.Success -> "success"
        types.Partial -> "partial"
        types.Failure -> "failure"
      }
      <> ")"
    })
    |> string.join("\n")

  let all_keywords =
    list.flat_map(entries, fn(e) { e.keywords })
    |> list.unique
    |> list.take(30)
    |> string.join(", ")

  "PERIOD: "
  <> from
  <> " to "
  <> to
  <> "\nTOTAL CYCLES: "
  <> int.to_string(list.length(entries))
  <> "\n\nENTRY SUMMARIES:\n"
  <> entry_summaries
  <> "\n\nAGGREGATED KEYWORDS: "
  <> all_keywords
}

// ---------------------------------------------------------------------------
// XML extraction / fallback
// ---------------------------------------------------------------------------

fn extract_summary(elements: Dict(String, String)) -> #(String, List(String)) {
  let summary = case dict.get(elements, "summary_response.summary") {
    Ok(s) -> s
    Error(_) -> ""
  }
  let keywords = extract_keywords_loop(elements, 0, [])
  #(summary, keywords)
}

fn extract_keywords_loop(
  elements: Dict(String, String),
  idx: Int,
  acc: List(String),
) -> List(String) {
  let key = "summary_response.keywords.keyword." <> int.to_string(idx)
  case dict.get(elements, key) {
    Ok(kw) -> extract_keywords_loop(elements, idx + 1, [kw, ..acc])
    Error(_) -> list.reverse(acc)
  }
}

fn build_summary_entry(
  cycle_id: String,
  summary_text: String,
  keywords: List(String),
  from: String,
  to: String,
  entries: List(NarrativeEntry),
) -> NarrativeEntry {
  let success_count =
    list.count(entries, fn(e) { e.outcome.status == types.Success })
  NarrativeEntry(
    schema_version: 1,
    cycle_id:,
    parent_cycle_id: None,
    timestamp: "",
    entry_type: Summary,
    summary: summary_text,
    intent: Intent(
      classification: Conversation,
      description: "Summary for " <> from <> " to " <> to,
      domain: "",
    ),
    outcome: Outcome(
      status: Success,
      confidence: 1.0,
      assessment: "Summary of "
        <> int.to_string(list.length(entries))
        <> " entries",
    ),
    delegation_chain: [],
    decisions: [],
    keywords:,
    topics: [],
    entities: Entities(
      locations: [],
      organisations: [],
      data_points: [
        types.DataPoint(
          label: "total_cycles",
          value: int.to_string(list.length(entries)),
          unit: "",
          period: from <> " to " <> to,
          source: "narrative_log",
        ),
        types.DataPoint(
          label: "success_count",
          value: int.to_string(success_count),
          unit: "",
          period: from <> " to " <> to,
          source: "narrative_log",
        ),
      ],
      temporal_references: [from, to],
    ),
    sources: [],
    thread: None,
    metrics: Metrics(
      total_duration_ms: 0,
      input_tokens: list.fold(entries, 0, fn(acc, e) {
        acc + e.metrics.input_tokens
      }),
      output_tokens: list.fold(entries, 0, fn(acc, e) {
        acc + e.metrics.output_tokens
      }),
      thinking_tokens: 0,
      tool_calls: list.fold(entries, 0, fn(acc, e) {
        acc + e.metrics.tool_calls
      }),
      agent_delegations: list.fold(entries, 0, fn(acc, e) {
        acc + e.metrics.agent_delegations
      }),
      dprime_evaluations: 0,
      model_used: "summary",
    ),
    observations: [],
    redacted: False,
  )
}

fn fallback_summary(
  entries: List(NarrativeEntry),
  from: String,
  to: String,
) -> NarrativeEntry {
  let cycle_id = cycle_log.generate_uuid()
  let all_keywords =
    list.flat_map(entries, fn(e) { e.keywords })
    |> list.unique
    |> list.take(20)
  build_summary_entry(
    cycle_id,
    "I processed "
      <> int.to_string(list.length(entries))
      <> " requests between "
      <> from
      <> " and "
      <> to
      <> ". Summary generation encountered a parsing error.",
    all_keywords,
    from,
    to,
    entries,
  )
}

// ---------------------------------------------------------------------------
// Date arithmetic (simple string-based)
// ---------------------------------------------------------------------------

fn subtract_days(date: String, days: Int) -> String {
  // Parse YYYY-MM-DD, subtract days, handle month/year boundaries
  case string.split(date, "-") {
    [year_str, month_str, day_str] -> {
      let year = parse_int_or(year_str, 2026)
      let month = parse_int_or(month_str, 1)
      let day = parse_int_or(day_str, 1)
      let total_days = day - days
      subtract_days_loop(year, month, total_days)
    }
    _ -> date
  }
}

fn subtract_days_loop(year: Int, month: Int, day: Int) -> String {
  case day > 0 {
    True -> format_date(year, month, day)
    False -> {
      let prev_month = case month > 1 {
        True -> month - 1
        False -> 12
      }
      let prev_year = case month > 1 {
        True -> year
        False -> year - 1
      }
      let days_in_prev = days_in_month(prev_year, prev_month)
      subtract_days_loop(prev_year, prev_month, day + days_in_prev)
    }
  }
}

fn days_in_month(year: Int, month: Int) -> Int {
  case month {
    1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
    4 | 6 | 9 | 11 -> 30
    2 ->
      case year % 4 == 0 && { year % 100 != 0 || year % 400 == 0 } {
        True -> 29
        False -> 28
      }
    _ -> 30
  }
}

fn format_date(year: Int, month: Int, day: Int) -> String {
  int.to_string(year) <> "-" <> pad2(month) <> "-" <> pad2(day)
}

fn pad2(n: Int) -> String {
  case n < 10 {
    True -> "0" <> int.to_string(n)
    False -> int.to_string(n)
  }
}

fn parse_int_or(s: String, default: Int) -> Int {
  case int.parse(s) {
    Ok(n) -> n
    Error(_) -> default
  }
}
