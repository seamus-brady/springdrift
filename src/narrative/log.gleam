//// Append-only narrative log — JSON-L files in prime-narrative/ directory.
////
//// Each day gets its own file (YYYY-MM-DD.jsonl). Entries are encoded as
//// self-contained JSON objects, one per line. Never modify or delete existing
//// entries — corrections are appended as amendments.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import narrative/types.{
  type Entities, type NarrativeEntry, type ThreadIndex, type ThreadState,
  Amendment, Clarification, Comparison, Conversation, DataPoint, DataQuery,
  DataReport, Decision, DelegationStep, Entities, ErrorSeverity, Exploration,
  Failure, Info, Intent, Metrics, MonitoringCheck, Narrative, NarrativeEntry,
  Observation, ObservationEntry, Outcome, Partial, Source, Success, Summary,
  SystemCommand, Thread, ThreadIndex, ThreadState, TrendAnalysis, Warning,
}
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

/// Append a NarrativeEntry to the day's log file.
pub fn append(dir: String, entry: NarrativeEntry) -> Nil {
  let date = get_date()
  let path = dir <> "/" <> date <> ".jsonl"
  let json_str = json.to_string(encode_entry(entry))
  let _ = simplifile.create_directory_all(dir)
  case simplifile.append(path, json_str <> "\n") {
    Ok(_) ->
      slog.debug(
        "narrative/log",
        "append",
        "Appended entry for cycle " <> entry.cycle_id,
        Some(entry.cycle_id),
      )
    Error(e) ->
      slog.log_error(
        "narrative/log",
        "append",
        "Failed to append: " <> simplifile.describe_error(e),
        Some(entry.cycle_id),
      )
  }
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

/// Load all narrative entries from a specific date file.
pub fn load_date(dir: String, date: String) -> List(NarrativeEntry) {
  let path = dir <> "/" <> date <> ".jsonl"
  case simplifile.read(path) {
    Error(_) -> []
    Ok(content) -> parse_jsonl(content)
  }
}

/// Load entries for a date range (inclusive). Dates as "YYYY-MM-DD".
pub fn load_entries(
  dir: String,
  from: String,
  to: String,
) -> List(NarrativeEntry) {
  case simplifile.read_directory(dir) {
    Error(_) -> []
    Ok(files) -> {
      let jsonl_files =
        files
        |> list.filter(fn(f) { string.ends_with(f, ".jsonl") })
        |> list.filter(fn(f) {
          let date = string.drop_end(f, 6)
          case string.compare(date, from), string.compare(date, to) {
            order.Lt, _ -> False
            _, order.Gt -> False
            _, _ -> True
          }
        })
        |> list.sort(string.compare)
      list.flat_map(jsonl_files, fn(f) {
        let date = string.drop_end(f, 6)
        load_date(dir, date)
      })
    }
  }
}

/// Load all entries for a specific thread.
pub fn load_thread(dir: String, thread_id: String) -> List(NarrativeEntry) {
  let all = load_all(dir)
  list.filter(all, fn(entry) {
    case entry.thread {
      Some(t) -> t.thread_id == thread_id
      None -> False
    }
  })
}

/// Search entries by keyword (case-insensitive match against summary + keywords).
pub fn search(dir: String, keyword: String) -> List(NarrativeEntry) {
  let lower_keyword = string.lowercase(keyword)
  let all = load_all(dir)
  list.filter(all, fn(entry) {
    let in_summary =
      string.contains(string.lowercase(entry.summary), lower_keyword)
    let in_keywords =
      list.any(entry.keywords, fn(k) {
        string.contains(string.lowercase(k), lower_keyword)
      })
    in_summary || in_keywords
  })
}

/// Load all entries from all date files in the directory.
pub fn load_all(dir: String) -> List(NarrativeEntry) {
  case simplifile.read_directory(dir) {
    Error(_) -> []
    Ok(files) -> {
      let jsonl_files =
        files
        |> list.filter(fn(f) { string.ends_with(f, ".jsonl") })
        |> list.sort(string.compare)
      list.flat_map(jsonl_files, fn(f) {
        let date = string.drop_end(f, 6)
        load_date(dir, date)
      })
    }
  }
}

/// Get the latest entry for each active thread.
pub fn thread_heads(dir: String) -> List(NarrativeEntry) {
  let all = load_all(dir)
  let threaded =
    list.filter(all, fn(entry: NarrativeEntry) { option.is_some(entry.thread) })
  // Group by thread_id, keep last entry per thread
  list.fold(threaded, [], fn(acc: List(NarrativeEntry), entry: NarrativeEntry) {
    let tid = case entry.thread {
      Some(t) -> t.thread_id
      None -> ""
    }
    let exists =
      list.any(acc, fn(e: NarrativeEntry) {
        case e.thread {
          Some(t) -> t.thread_id == tid
          None -> False
        }
      })
    case exists {
      True ->
        list.map(acc, fn(e: NarrativeEntry) {
          case e.thread {
            Some(t) if t.thread_id == tid -> entry
            _ -> e
          }
        })
      False -> [entry, ..acc]
    }
  })
}

// ---------------------------------------------------------------------------
// Thread index
// ---------------------------------------------------------------------------

/// Load the thread index from disk.
pub fn load_thread_index(dir: String) -> ThreadIndex {
  let path = dir <> "/thread_index.json"
  case simplifile.read(path) {
    Error(_) -> ThreadIndex(threads: [])
    Ok(content) ->
      case json.parse(content, thread_index_decoder()) {
        Ok(idx) -> idx
        Error(_) -> ThreadIndex(threads: [])
      }
  }
}

/// Save the thread index to disk (atomic write via temp file).
pub fn save_thread_index(dir: String, index: ThreadIndex) -> Nil {
  let path = dir <> "/thread_index.json"
  let _ = simplifile.create_directory_all(dir)
  let json_str = json.to_string(encode_thread_index(index))
  let tmp = path <> ".tmp"
  case simplifile.write(tmp, json_str) {
    Ok(_) -> {
      let _ = simplifile.rename(tmp, path)
      Nil
    }
    Error(_) -> Nil
  }
}

// ---------------------------------------------------------------------------
// JSON encoding — NarrativeEntry
// ---------------------------------------------------------------------------

pub fn encode_entry(entry: NarrativeEntry) -> json.Json {
  json.object([
    #("schema_version", json.int(entry.schema_version)),
    #("cycle_id", json.string(entry.cycle_id)),
    #("parent_cycle_id", encode_optional_string(entry.parent_cycle_id)),
    #("timestamp", json.string(entry.timestamp)),
    #("type", json.string(entry_type_to_string(entry.entry_type))),
    #("summary", json.string(entry.summary)),
    #("intent", encode_intent(entry.intent)),
    #("outcome", encode_outcome(entry.outcome)),
    #("delegation_chain", json.array(entry.delegation_chain, encode_delegation)),
    #("decisions", json.array(entry.decisions, encode_decision)),
    #("keywords", json.array(entry.keywords, json.string)),
    #("entities", encode_entities(entry.entities)),
    #("sources", json.array(entry.sources, encode_source)),
    #("thread", case entry.thread {
      Some(t) -> encode_thread(t)
      None -> json.null()
    }),
    #("metrics", encode_metrics(entry.metrics)),
    #("observations", json.array(entry.observations, encode_observation)),
  ])
}

fn encode_optional_string(opt: Option(String)) -> json.Json {
  case opt {
    Some(s) -> json.string(s)
    None -> json.null()
  }
}

fn entry_type_to_string(t: types.EntryType) -> String {
  case t {
    Narrative -> "narrative"
    Amendment -> "amendment"
    Summary -> "summary"
    ObservationEntry -> "observation"
  }
}

fn encode_intent(intent: types.Intent) -> json.Json {
  json.object([
    #(
      "classification",
      json.string(classification_to_string(intent.classification)),
    ),
    #("description", json.string(intent.description)),
    #("domain", json.string(intent.domain)),
  ])
}

fn classification_to_string(c: types.IntentClassification) -> String {
  case c {
    DataReport -> "data_report"
    DataQuery -> "data_query"
    Comparison -> "comparison"
    TrendAnalysis -> "trend_analysis"
    MonitoringCheck -> "monitoring_check"
    Exploration -> "exploration"
    Clarification -> "clarification"
    SystemCommand -> "system_command"
    Conversation -> "conversation"
  }
}

fn encode_outcome(outcome: types.Outcome) -> json.Json {
  json.object([
    #(
      "status",
      json.string(case outcome.status {
        Success -> "success"
        Partial -> "partial"
        Failure -> "failure"
      }),
    ),
    #("confidence", json.float(outcome.confidence)),
    #("assessment", json.string(outcome.assessment)),
  ])
}

fn encode_delegation(step: types.DelegationStep) -> json.Json {
  json.object([
    #("agent", json.string(step.agent)),
    #("agent_id", json.string(step.agent_id)),
    #("agent_human_name", json.string(step.agent_human_name)),
    #("agent_cycle_id", json.string(step.agent_cycle_id)),
    #("instruction", json.string(step.instruction)),
    #("outcome", json.string(step.outcome)),
    #("contribution", json.string(step.contribution)),
    #("tools_used", json.array(step.tools_used, json.string)),
    #("sources_accessed", json.int(step.sources_accessed)),
    #("input_tokens", json.int(step.input_tokens)),
    #("output_tokens", json.int(step.output_tokens)),
    #("duration_ms", json.int(step.duration_ms)),
  ])
}

fn encode_decision(d: types.Decision) -> json.Json {
  json.object([
    #("point", json.string(d.point)),
    #("choice", json.string(d.choice)),
    #("rationale", json.string(d.rationale)),
    #("score", case d.score {
      Some(s) -> json.float(s)
      None -> json.null()
    }),
  ])
}

fn encode_entities(e: Entities) -> json.Json {
  json.object([
    #("locations", json.array(e.locations, json.string)),
    #("organisations", json.array(e.organisations, json.string)),
    #("data_points", json.array(e.data_points, encode_data_point)),
    #("temporal_references", json.array(e.temporal_references, json.string)),
  ])
}

fn encode_data_point(dp: types.DataPoint) -> json.Json {
  json.object([
    #("label", json.string(dp.label)),
    #("value", json.string(dp.value)),
    #("unit", json.string(dp.unit)),
    #("period", json.string(dp.period)),
    #("source", json.string(dp.source)),
  ])
}

fn encode_source(s: types.Source) -> json.Json {
  json.object([
    #("type", json.string(s.source_type)),
    #("url", encode_optional_string(s.url)),
    #("path", encode_optional_string(s.path)),
    #("name", json.string(s.name)),
    #("accessed_at", encode_optional_string(s.accessed_at)),
    #("data_date", encode_optional_string(s.data_date)),
  ])
}

fn encode_thread(t: types.Thread) -> json.Json {
  json.object([
    #("thread_id", json.string(t.thread_id)),
    #("thread_name", json.string(t.thread_name)),
    #("position", json.int(t.position)),
    #("previous_cycle_id", encode_optional_string(t.previous_cycle_id)),
    #("continuity_note", json.string(t.continuity_note)),
  ])
}

fn encode_metrics(m: types.Metrics) -> json.Json {
  json.object([
    #("total_duration_ms", json.int(m.total_duration_ms)),
    #("input_tokens", json.int(m.input_tokens)),
    #("output_tokens", json.int(m.output_tokens)),
    #("thinking_tokens", json.int(m.thinking_tokens)),
    #("tool_calls", json.int(m.tool_calls)),
    #("agent_delegations", json.int(m.agent_delegations)),
    #("dprime_evaluations", json.int(m.dprime_evaluations)),
    #("model_used", json.string(m.model_used)),
  ])
}

fn encode_observation(o: types.Observation) -> json.Json {
  json.object([
    #("type", json.string(o.observation_type)),
    #(
      "severity",
      json.string(case o.severity {
        Info -> "info"
        Warning -> "warning"
        ErrorSeverity -> "error"
      }),
    ),
    #("detail", json.string(o.detail)),
  ])
}

// ---------------------------------------------------------------------------
// Thread index encoding
// ---------------------------------------------------------------------------

fn encode_thread_index(idx: ThreadIndex) -> json.Json {
  json.object([
    #("threads", json.array(idx.threads, encode_thread_state)),
  ])
}

fn encode_thread_state(ts: ThreadState) -> json.Json {
  json.object([
    #("thread_id", json.string(ts.thread_id)),
    #("thread_name", json.string(ts.thread_name)),
    #("created_at", json.string(ts.created_at)),
    #("last_cycle_id", json.string(ts.last_cycle_id)),
    #("last_cycle_at", json.string(ts.last_cycle_at)),
    #("cycle_count", json.int(ts.cycle_count)),
    #("locations", json.array(ts.locations, json.string)),
    #("domains", json.array(ts.domains, json.string)),
    #("keywords", json.array(ts.keywords, json.string)),
    #("last_data_points", json.array(ts.last_data_points, encode_data_point)),
  ])
}

// ---------------------------------------------------------------------------
// JSON decoding — NarrativeEntry
// ---------------------------------------------------------------------------

pub fn entry_decoder() -> decode.Decoder(NarrativeEntry) {
  use schema_version <- decode.optional_field("schema_version", 1, decode.int)
  use cycle_id <- decode.field("cycle_id", decode.string)
  use parent_cycle_id <- decode.optional_field(
    "parent_cycle_id",
    None,
    decode.optional(decode.string),
  )
  use timestamp <- decode.field("timestamp", decode.string)
  use type_str <- decode.optional_field("type", "narrative", decode.string)
  use summary <- decode.field("summary", decode.string)
  use intent <- decode.field("intent", intent_decoder())
  use outcome <- decode.field("outcome", outcome_decoder())
  use delegation_chain <- decode.optional_field(
    "delegation_chain",
    [],
    decode.list(delegation_decoder()),
  )
  use decisions <- decode.optional_field(
    "decisions",
    [],
    decode.list(decision_decoder()),
  )
  use keywords <- decode.optional_field(
    "keywords",
    [],
    decode.list(decode.string),
  )
  use entities <- decode.optional_field(
    "entities",
    empty_entities(),
    entities_decoder(),
  )
  use sources <- decode.optional_field(
    "sources",
    [],
    decode.list(source_decoder()),
  )
  use thread <- decode.optional_field(
    "thread",
    None,
    decode.optional(thread_decoder()),
  )
  use metrics <- decode.field("metrics", metrics_decoder())
  use observations <- decode.optional_field(
    "observations",
    [],
    decode.list(observation_decoder()),
  )
  decode.success(NarrativeEntry(
    schema_version:,
    cycle_id:,
    parent_cycle_id:,
    timestamp:,
    entry_type: parse_entry_type(type_str),
    summary:,
    intent:,
    outcome:,
    delegation_chain:,
    decisions:,
    keywords:,
    entities:,
    sources:,
    thread:,
    metrics:,
    observations:,
  ))
}

fn parse_entry_type(s: String) -> types.EntryType {
  case s {
    "amendment" -> Amendment
    "summary" -> Summary
    "observation" -> ObservationEntry
    _ -> Narrative
  }
}

fn intent_decoder() -> decode.Decoder(types.Intent) {
  use classification_str <- decode.field("classification", decode.string)
  use description <- decode.optional_field("description", "", decode.string)
  use domain <- decode.optional_field("domain", "", decode.string)
  decode.success(Intent(
    classification: parse_classification(classification_str),
    description:,
    domain:,
  ))
}

fn parse_classification(s: String) -> types.IntentClassification {
  case s {
    "data_report" -> DataReport
    "data_query" -> DataQuery
    "comparison" -> Comparison
    "trend_analysis" -> TrendAnalysis
    "monitoring_check" -> MonitoringCheck
    "exploration" -> Exploration
    "clarification" -> Clarification
    "system_command" -> SystemCommand
    _ -> Conversation
  }
}

fn outcome_decoder() -> decode.Decoder(types.Outcome) {
  use status_str <- decode.field("status", decode.string)
  use confidence <- decode.optional_field("confidence", 0.0, decode.float)
  use assessment <- decode.optional_field("assessment", "", decode.string)
  decode.success(Outcome(
    status: case status_str {
      "success" -> Success
      "partial" -> Partial
      _ -> Failure
    },
    confidence:,
    assessment:,
  ))
}

fn delegation_decoder() -> decode.Decoder(types.DelegationStep) {
  use agent <- decode.field("agent", decode.string)
  use agent_id <- decode.optional_field("agent_id", "", decode.string)
  use agent_human_name <- decode.optional_field(
    "agent_human_name",
    "",
    decode.string,
  )
  use agent_cycle_id <- decode.optional_field(
    "agent_cycle_id",
    "",
    decode.string,
  )
  use instruction <- decode.optional_field("instruction", "", decode.string)
  use outcome <- decode.optional_field("outcome", "", decode.string)
  use contribution <- decode.optional_field("contribution", "", decode.string)
  use tools_used <- decode.optional_field(
    "tools_used",
    [],
    decode.list(decode.string),
  )
  use sources_accessed <- decode.optional_field(
    "sources_accessed",
    0,
    decode.int,
  )
  use input_tokens <- decode.optional_field("input_tokens", 0, decode.int)
  use output_tokens <- decode.optional_field("output_tokens", 0, decode.int)
  use duration_ms <- decode.optional_field("duration_ms", 0, decode.int)
  decode.success(DelegationStep(
    agent:,
    agent_id:,
    agent_human_name:,
    agent_cycle_id:,
    instruction:,
    outcome:,
    contribution:,
    tools_used:,
    sources_accessed:,
    input_tokens:,
    output_tokens:,
    duration_ms:,
  ))
}

fn decision_decoder() -> decode.Decoder(types.Decision) {
  use point <- decode.field("point", decode.string)
  use choice <- decode.field("choice", decode.string)
  use rationale <- decode.optional_field("rationale", "", decode.string)
  use score <- decode.optional_field(
    "score",
    None,
    decode.optional(decode.float),
  )
  decode.success(Decision(point:, choice:, rationale:, score:))
}

fn entities_decoder() -> decode.Decoder(Entities) {
  use locations <- decode.optional_field(
    "locations",
    [],
    decode.list(decode.string),
  )
  use organisations <- decode.optional_field(
    "organisations",
    [],
    decode.list(decode.string),
  )
  use data_points <- decode.optional_field(
    "data_points",
    [],
    decode.list(data_point_decoder()),
  )
  use temporal_references <- decode.optional_field(
    "temporal_references",
    [],
    decode.list(decode.string),
  )
  decode.success(Entities(
    locations:,
    organisations:,
    data_points:,
    temporal_references:,
  ))
}

fn empty_entities() -> Entities {
  Entities(
    locations: [],
    organisations: [],
    data_points: [],
    temporal_references: [],
  )
}

fn data_point_decoder() -> decode.Decoder(types.DataPoint) {
  use label <- decode.field("label", decode.string)
  use value <- decode.optional_field("value", "", decode.string)
  use unit <- decode.optional_field("unit", "", decode.string)
  use period <- decode.optional_field("period", "", decode.string)
  use source <- decode.optional_field("source", "", decode.string)
  decode.success(DataPoint(label:, value:, unit:, period:, source:))
}

fn source_decoder() -> decode.Decoder(types.Source) {
  use source_type <- decode.optional_field("type", "", decode.string)
  use url <- decode.optional_field("url", None, decode.optional(decode.string))
  use path <- decode.optional_field(
    "path",
    None,
    decode.optional(decode.string),
  )
  use name <- decode.optional_field("name", "", decode.string)
  use accessed_at <- decode.optional_field(
    "accessed_at",
    None,
    decode.optional(decode.string),
  )
  use data_date <- decode.optional_field(
    "data_date",
    None,
    decode.optional(decode.string),
  )
  decode.success(Source(
    source_type:,
    url:,
    path:,
    name:,
    accessed_at:,
    data_date:,
  ))
}

fn thread_decoder() -> decode.Decoder(types.Thread) {
  use thread_id <- decode.field("thread_id", decode.string)
  use thread_name <- decode.optional_field("thread_name", "", decode.string)
  use position <- decode.optional_field("position", 0, decode.int)
  use previous_cycle_id <- decode.optional_field(
    "previous_cycle_id",
    None,
    decode.optional(decode.string),
  )
  use continuity_note <- decode.optional_field(
    "continuity_note",
    "",
    decode.string,
  )
  decode.success(Thread(
    thread_id:,
    thread_name:,
    position:,
    previous_cycle_id:,
    continuity_note:,
  ))
}

fn metrics_decoder() -> decode.Decoder(types.Metrics) {
  use total_duration_ms <- decode.optional_field(
    "total_duration_ms",
    0,
    decode.int,
  )
  use input_tokens <- decode.optional_field("input_tokens", 0, decode.int)
  use output_tokens <- decode.optional_field("output_tokens", 0, decode.int)
  use thinking_tokens <- decode.optional_field("thinking_tokens", 0, decode.int)
  use tool_calls <- decode.optional_field("tool_calls", 0, decode.int)
  use agent_delegations <- decode.optional_field(
    "agent_delegations",
    0,
    decode.int,
  )
  use dprime_evaluations <- decode.optional_field(
    "dprime_evaluations",
    0,
    decode.int,
  )
  use model_used <- decode.optional_field("model_used", "", decode.string)
  decode.success(Metrics(
    total_duration_ms:,
    input_tokens:,
    output_tokens:,
    thinking_tokens:,
    tool_calls:,
    agent_delegations:,
    dprime_evaluations:,
    model_used:,
  ))
}

fn observation_decoder() -> decode.Decoder(types.Observation) {
  use observation_type <- decode.optional_field("type", "", decode.string)
  use severity_str <- decode.optional_field("severity", "info", decode.string)
  use detail <- decode.optional_field("detail", "", decode.string)
  decode.success(Observation(
    observation_type:,
    severity: case severity_str {
      "warning" -> Warning
      "error" -> ErrorSeverity
      _ -> Info
    },
    detail:,
  ))
}

fn thread_index_decoder() -> decode.Decoder(ThreadIndex) {
  use threads <- decode.field("threads", decode.list(thread_state_decoder()))
  decode.success(ThreadIndex(threads:))
}

fn thread_state_decoder() -> decode.Decoder(ThreadState) {
  use thread_id <- decode.field("thread_id", decode.string)
  use thread_name <- decode.optional_field("thread_name", "", decode.string)
  use created_at <- decode.optional_field("created_at", "", decode.string)
  use last_cycle_id <- decode.optional_field("last_cycle_id", "", decode.string)
  use last_cycle_at <- decode.optional_field("last_cycle_at", "", decode.string)
  use cycle_count <- decode.optional_field("cycle_count", 0, decode.int)
  use locations <- decode.optional_field(
    "locations",
    [],
    decode.list(decode.string),
  )
  use domains <- decode.optional_field(
    "domains",
    [],
    decode.list(decode.string),
  )
  use keywords <- decode.optional_field(
    "keywords",
    [],
    decode.list(decode.string),
  )
  use last_data_points <- decode.optional_field(
    "last_data_points",
    [],
    decode.list(data_point_decoder()),
  )
  decode.success(ThreadState(
    thread_id:,
    thread_name:,
    created_at:,
    last_cycle_id:,
    last_cycle_at:,
    cycle_count:,
    locations:,
    domains:,
    keywords:,
    last_data_points:,
  ))
}

// ---------------------------------------------------------------------------
// Internal — parse JSON-L
// ---------------------------------------------------------------------------

fn parse_jsonl(content: String) -> List(NarrativeEntry) {
  content
  |> string.split("\n")
  |> list.filter(fn(line) { string.trim(line) != "" })
  |> list.filter_map(fn(line) {
    case json.parse(line, entry_decoder()) {
      Ok(entry) -> Ok(entry)
      Error(_) -> Error(Nil)
    }
  })
}
