//// Append-only CBR case log — JSON-L files in .springdrift/memory/cbr/.
////
//// Each day gets its own file (YYYY-MM-DD.jsonl). Cases are encoded as
//// self-contained JSON objects, one per line. Follows the same pattern
//// as narrative/log.gleam.

import cbr/types.{
  type CbrCase, type CbrOutcome, type CbrProblem, type CbrSolution, CbrCase,
  CbrOutcome, CbrProblem, CbrSolution,
}
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string
import simplifile
import slog

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

// ---------------------------------------------------------------------------
// Append
// ---------------------------------------------------------------------------

/// Append a CbrCase to the day's log file.
pub fn append(dir: String, cbr_case: CbrCase) -> Nil {
  let date = get_date()
  let path = dir <> "/" <> date <> ".jsonl"
  let json_str = json.to_string(encode_case(cbr_case))
  let _ = simplifile.create_directory_all(dir)
  case simplifile.append(path, json_str <> "\n") {
    Ok(_) ->
      slog.debug(
        "cbr/log",
        "append",
        "Appended case " <> cbr_case.case_id,
        Some(cbr_case.case_id),
      )
    Error(e) ->
      slog.log_error(
        "cbr/log",
        "append",
        "Failed to append: " <> simplifile.describe_error(e),
        Some(cbr_case.case_id),
      )
  }
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

/// Load all CBR cases from a specific date file.
/// Uses last-write-wins deduplication by case_id to handle mutations.
pub fn load_date(dir: String, date: String) -> List(CbrCase) {
  let path = dir <> "/" <> date <> ".jsonl"
  case simplifile.read(path) {
    Error(_) -> []
    Ok(content) -> dedup_by_case_id(parse_jsonl(content))
  }
}

/// Load all cases from all date files in the directory.
/// Uses last-write-wins deduplication by case_id to handle mutations.
pub fn load_all(dir: String) -> List(CbrCase) {
  case simplifile.read_directory(dir) {
    Error(_) -> []
    Ok(files) -> {
      let jsonl_files =
        files
        |> list.filter(fn(f) { string.ends_with(f, ".jsonl") })
        |> list.sort(string.compare)
      let all_cases =
        list.flat_map(jsonl_files, fn(f) {
          let date = string.drop_end(f, 6)
          // Raw parse without per-file dedup (dedup across all files)
          let path = dir <> "/" <> date <> ".jsonl"
          case simplifile.read(path) {
            Error(_) -> []
            Ok(content) -> parse_jsonl(content)
          }
        })
      dedup_by_case_id(all_cases)
    }
  }
}

/// Deduplicate cases by case_id using last-write-wins (dict fold preserves
/// insertion order, last entry for a key wins).
fn dedup_by_case_id(cases: List(CbrCase)) -> List(CbrCase) {
  cases
  |> list.fold(dict.new(), fn(acc, c) { dict.insert(acc, c.case_id, c) })
  |> dict.values
  |> list.sort(fn(a, b) { string.compare(a.timestamp, b.timestamp) })
}

// ---------------------------------------------------------------------------
// JSONL parsing
// ---------------------------------------------------------------------------

fn parse_jsonl(content: String) -> List(CbrCase) {
  content
  |> string.split("\n")
  |> list.filter(fn(line) { string.trim(line) != "" })
  |> list.filter_map(fn(line) {
    case json.parse(line, case_decoder()) {
      Ok(entry) -> Ok(entry)
      Error(_) -> Error(Nil)
    }
  })
}

// ---------------------------------------------------------------------------
// JSON encoding
// ---------------------------------------------------------------------------

pub fn encode_case(c: CbrCase) -> json.Json {
  json.object([
    #("case_id", json.string(c.case_id)),
    #("timestamp", json.string(c.timestamp)),
    #("schema_version", json.int(c.schema_version)),
    #("problem", encode_problem(c.problem)),
    #("solution", encode_solution(c.solution)),
    #("outcome", encode_outcome(c.outcome)),
    #("source_narrative_id", json.string(c.source_narrative_id)),
    #("profile", case c.profile {
      option.Some(p) -> json.string(p)
      option.None -> json.null()
    }),
  ])
}

fn encode_problem(p: CbrProblem) -> json.Json {
  json.object([
    #("user_input", json.string(p.user_input)),
    #("intent", json.string(p.intent)),
    #("domain", json.string(p.domain)),
    #("entities", json.array(p.entities, json.string)),
    #("keywords", json.array(p.keywords, json.string)),
    #("query_complexity", json.string(p.query_complexity)),
  ])
}

fn encode_solution(s: CbrSolution) -> json.Json {
  json.object([
    #("approach", json.string(s.approach)),
    #("agents_used", json.array(s.agents_used, json.string)),
    #("tools_used", json.array(s.tools_used, json.string)),
    #("steps", json.array(s.steps, json.string)),
  ])
}

fn encode_outcome(o: CbrOutcome) -> json.Json {
  json.object([
    #("status", json.string(o.status)),
    #("confidence", json.float(o.confidence)),
    #("assessment", json.string(o.assessment)),
    #("pitfalls", json.array(o.pitfalls, json.string)),
  ])
}

// ---------------------------------------------------------------------------
// JSON decoding — lenient with defaults
// ---------------------------------------------------------------------------

pub fn case_decoder() -> decode.Decoder(CbrCase) {
  use case_id <- decode.field("case_id", decode.string)
  use timestamp <- decode.field("timestamp", decode.string)
  use schema_version <- decode.field(
    "schema_version",
    decode.optional(decode.int) |> decode.map(option.unwrap(_, 1)),
  )
  use problem <- decode.field("problem", problem_decoder())
  use solution <- decode.field("solution", solution_decoder())
  use outcome <- decode.field("outcome", outcome_decoder())
  use source_narrative_id <- decode.field(
    "source_narrative_id",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use profile <- decode.field("profile", decode.optional(decode.string))
  decode.success(CbrCase(
    case_id:,
    timestamp:,
    schema_version:,
    problem:,
    solution:,
    outcome:,
    source_narrative_id:,
    profile:,
  ))
}

fn problem_decoder() -> decode.Decoder(CbrProblem) {
  use user_input <- decode.field(
    "user_input",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use intent <- decode.field(
    "intent",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use domain <- decode.field(
    "domain",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use entities <- decode.field(
    "entities",
    decode.optional(decode.list(decode.string))
      |> decode.map(option.unwrap(_, [])),
  )
  use keywords <- decode.field(
    "keywords",
    decode.optional(decode.list(decode.string))
      |> decode.map(option.unwrap(_, [])),
  )
  use query_complexity <- decode.field(
    "query_complexity",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "simple")),
  )
  decode.success(CbrProblem(
    user_input:,
    intent:,
    domain:,
    entities:,
    keywords:,
    query_complexity:,
  ))
}

fn solution_decoder() -> decode.Decoder(CbrSolution) {
  use approach <- decode.field(
    "approach",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use agents_used <- decode.field(
    "agents_used",
    decode.optional(decode.list(decode.string))
      |> decode.map(option.unwrap(_, [])),
  )
  use tools_used <- decode.field(
    "tools_used",
    decode.optional(decode.list(decode.string))
      |> decode.map(option.unwrap(_, [])),
  )
  use steps <- decode.field(
    "steps",
    decode.optional(decode.list(decode.string))
      |> decode.map(option.unwrap(_, [])),
  )
  decode.success(CbrSolution(approach:, agents_used:, tools_used:, steps:))
}

fn outcome_decoder() -> decode.Decoder(CbrOutcome) {
  use status <- decode.field(
    "status",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "success")),
  )
  use confidence <- decode.field(
    "confidence",
    decode.optional(decode.float) |> decode.map(option.unwrap(_, 0.0)),
  )
  use assessment <- decode.field(
    "assessment",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use pitfalls <- decode.field(
    "pitfalls",
    decode.optional(decode.list(decode.string))
      |> decode.map(option.unwrap(_, [])),
  )
  decode.success(CbrOutcome(status:, confidence:, assessment:, pitfalls:))
}
