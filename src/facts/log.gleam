//// Append-only MemoryFact log — daily JSONL files in .springdrift/memory/facts/.
////
//// Facts use daily rotation (YYYY-MM-DD-facts.jsonl) like narrative and CBR.
//// All fact files are always loaded at startup (no max_files windowing) because
//// fact history must be fully introspectable for memory_trace_fact and
//// inspect_cycle. Supersession semantics work correctly: index_fact replays
//// all files chronologically, so later Writes override earlier entries.

import facts/types.{
  type FactDerivation, type FactOp, type FactProvenance, type FactScope,
  type MemoryFact, Clear, DirectObservation, Ephemeral, FactProvenance,
  MemoryFact, OperatorProvided, Persistent, Session, Superseded, Synthesis,
  Unknown, Write,
}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import simplifile
import slog

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

// ---------------------------------------------------------------------------
// Append
// ---------------------------------------------------------------------------

/// Append a MemoryFact to a dated JSONL file (YYYY-MM-DD-facts.jsonl).
pub fn append(dir: String, fact: MemoryFact) -> Nil {
  let date = get_date()
  let path = dir <> "/" <> date <> "-facts.jsonl"
  let json_str = json.to_string(encode_fact(fact))
  let _ = simplifile.create_directory_all(dir)
  case simplifile.append(path, json_str <> "\n") {
    Ok(_) ->
      slog.debug(
        "facts/log",
        "append",
        "Appended fact " <> fact.key <> " (" <> fact.fact_id <> ")",
        Some(fact.cycle_id),
      )
    Error(e) ->
      slog.log_error(
        "facts/log",
        "append",
        "Failed to append: " <> simplifile.describe_error(e),
        Some(fact.fact_id),
      )
  }
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

/// Load facts for a specific date from YYYY-MM-DD-facts.jsonl.
pub fn load_date(dir: String, date: String) -> List(MemoryFact) {
  let path = dir <> "/" <> date <> "-facts.jsonl"
  case simplifile.read(path) {
    Error(_) -> []
    Ok(content) -> parse_jsonl(content)
  }
}

/// Load all facts from all dated JSONL files, in chronological order.
/// Also loads from legacy facts.jsonl if present (for backward compat).
pub fn load_all(dir: String) -> List(MemoryFact) {
  case simplifile.read_directory(dir) {
    Error(_) -> []
    Ok(files) -> {
      // Legacy single-file facts
      let legacy = case list.contains(files, "facts.jsonl") {
        True ->
          case simplifile.read(dir <> "/facts.jsonl") {
            Ok(content) -> parse_jsonl(content)
            Error(_) -> []
          }
        False -> []
      }

      // Dated fact files, sorted chronologically
      let dated_facts =
        files
        |> list.filter(fn(f) { string.ends_with(f, "-facts.jsonl") })
        |> list.sort(string.compare)
        |> list.flat_map(fn(f) {
          let date = string.drop_end(f, 12)
          load_date(dir, date)
        })

      list.append(legacy, dated_facts)
    }
  }
}

/// Resolve the current state of facts: replay the log and return only
/// the latest non-superseded, non-cleared facts per key.
/// Optionally filter by scope.
pub fn resolve_current(
  dir: String,
  scope_filter: Option(FactScope),
) -> List(MemoryFact) {
  let all = load_all(dir)
  resolve_from_list(all, scope_filter)
}

/// Resolve current facts from an in-memory list (for testing/reuse).
pub fn resolve_from_list(
  facts: List(MemoryFact),
  scope_filter: Option(FactScope),
) -> List(MemoryFact) {
  // Process in order: later entries supersede earlier ones for the same key
  let current =
    list.fold(facts, [], fn(acc: List(MemoryFact), fact: MemoryFact) {
      case fact.operation {
        Write -> {
          // Remove any existing fact with the same key, add this one
          let without_key =
            list.filter(acc, fn(f: MemoryFact) { f.key != fact.key })
          [fact, ..without_key]
        }
        Clear -> {
          // Remove the fact with this key
          list.filter(acc, fn(f: MemoryFact) { f.key != fact.key })
        }
        Superseded -> {
          // Remove the superseded fact
          case fact.supersedes {
            Some(old_id) ->
              list.filter(acc, fn(f: MemoryFact) { f.fact_id != old_id })
            None -> acc
          }
        }
      }
    })

  // Apply scope filter if provided
  case scope_filter {
    None -> current
    Some(scope) -> list.filter(current, fn(f) { f.scope == scope })
  }
}

/// Get the full history of a key (all versions, including superseded).
pub fn trace_key(dir: String, key: String) -> List(MemoryFact) {
  let all = load_all(dir)
  list.filter(all, fn(f) { f.key == key })
}

// ---------------------------------------------------------------------------
// Legacy migration
// ---------------------------------------------------------------------------

/// If legacy facts.jsonl exists, distribute its records into dated files
/// based on each record's timestamp field. Renames facts.jsonl to
/// facts.jsonl.migrated on completion. Silent no-op if already migrated.
pub fn migrate_legacy(dir: String) -> Nil {
  let legacy_path = dir <> "/facts.jsonl"
  case simplifile.is_file(legacy_path) {
    Ok(True) -> {
      case simplifile.read(legacy_path) {
        Ok(content) -> {
          let facts = parse_jsonl(content)
          // Group facts by date (from timestamp field)
          list.each(facts, fn(fact) {
            let date = string.slice(fact.timestamp, 0, 10)
            // Use a valid date or fallback to "unknown"
            let date_str = case string.length(date) == 10 {
              True -> date
              False -> "unknown"
            }
            let dated_path = dir <> "/" <> date_str <> "-facts.jsonl"
            let json_str = json.to_string(encode_fact(fact))
            let _ = simplifile.append(dated_path, json_str <> "\n")
            Nil
          })
          // Rename legacy file
          let _ = simplifile.rename(legacy_path, legacy_path <> ".migrated")
          slog.info(
            "facts/log",
            "migrate_legacy",
            "Migrated legacy facts.jsonl ("
              <> string.inspect(list.length(facts))
              <> " facts)",
            None,
          )
        }
        Error(_) -> Nil
      }
    }
    _ -> Nil
  }
}

// ---------------------------------------------------------------------------
// JSONL parsing
// ---------------------------------------------------------------------------

fn parse_jsonl(content: String) -> List(MemoryFact) {
  content
  |> string.split("\n")
  |> list.filter(fn(line) { string.trim(line) != "" })
  |> list.filter_map(fn(line) {
    case json.parse(line, fact_decoder()) {
      Ok(fact) -> Ok(fact)
      Error(_) -> Error(Nil)
    }
  })
}

// ---------------------------------------------------------------------------
// JSON encoding
// ---------------------------------------------------------------------------

pub fn encode_fact(f: MemoryFact) -> json.Json {
  json.object([
    #("schema_version", json.int(f.schema_version)),
    #("fact_id", json.string(f.fact_id)),
    #("timestamp", json.string(f.timestamp)),
    #("cycle_id", json.string(f.cycle_id)),
    #("agent_id", case f.agent_id {
      Some(id) -> json.string(id)
      None -> json.null()
    }),
    #("key", json.string(f.key)),
    #("value", json.string(f.value)),
    #("scope", json.string(encode_scope(f.scope))),
    #("operation", json.string(encode_op(f.operation))),
    #("supersedes", case f.supersedes {
      Some(id) -> json.string(id)
      None -> json.null()
    }),
    #("confidence", json.float(f.confidence)),
    #("source", json.string(f.source)),
    #("provenance", encode_provenance(f.provenance)),
  ])
}

fn encode_provenance(prov: Option(FactProvenance)) -> json.Json {
  case prov {
    None -> json.null()
    Some(p) ->
      json.object([
        #("source_cycle_id", json.string(p.source_cycle_id)),
        #("source_tool", json.string(p.source_tool)),
        #("source_agent", json.string(p.source_agent)),
        #("derivation", json.string(encode_derivation(p.derivation))),
      ])
  }
}

fn encode_derivation(d: FactDerivation) -> String {
  case d {
    DirectObservation -> "direct_observation"
    Synthesis -> "synthesis"
    OperatorProvided -> "operator_provided"
    Unknown -> "unknown"
  }
}

fn encode_scope(scope: FactScope) -> String {
  case scope {
    Persistent -> "persistent"
    Session -> "session"
    Ephemeral -> "ephemeral"
  }
}

fn encode_op(op: FactOp) -> String {
  case op {
    Write -> "write"
    Clear -> "clear"
    Superseded -> "superseded"
  }
}

// ---------------------------------------------------------------------------
// JSON decoding — lenient with defaults
// ---------------------------------------------------------------------------

pub fn fact_decoder() -> decode.Decoder(MemoryFact) {
  use schema_version <- decode.field(
    "schema_version",
    decode.optional(decode.int) |> decode.map(option.unwrap(_, 1)),
  )
  use fact_id <- decode.field("fact_id", decode.string)
  use timestamp <- decode.field("timestamp", decode.string)
  use cycle_id <- decode.field(
    "cycle_id",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use agent_id <- decode.field("agent_id", decode.optional(decode.string))
  use key <- decode.field("key", decode.string)
  use value <- decode.field(
    "value",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use scope <- decode.field(
    "scope",
    decode.optional(decode.string)
      |> decode.map(fn(s) { decode_scope(option.unwrap(s, "session")) }),
  )
  use operation <- decode.field(
    "operation",
    decode.optional(decode.string)
      |> decode.map(fn(o) { decode_op(option.unwrap(o, "write")) }),
  )
  use supersedes <- decode.field("supersedes", decode.optional(decode.string))
  use confidence <- decode.field(
    "confidence",
    decode.optional(decode.float) |> decode.map(option.unwrap(_, 0.0)),
  )
  use source <- decode.field(
    "source",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use provenance <- decode.optional_field(
    "provenance",
    None,
    decode.optional(provenance_decoder()),
  )
  decode.success(MemoryFact(
    schema_version:,
    fact_id:,
    timestamp:,
    cycle_id:,
    agent_id:,
    key:,
    value:,
    scope:,
    operation:,
    supersedes:,
    confidence:,
    source:,
    provenance:,
  ))
}

fn provenance_decoder() -> decode.Decoder(FactProvenance) {
  use source_cycle_id <- decode.field(
    "source_cycle_id",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use source_tool <- decode.field(
    "source_tool",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use source_agent <- decode.field(
    "source_agent",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use derivation <- decode.field(
    "derivation",
    decode.optional(decode.string)
      |> decode.map(fn(d) { decode_derivation(option.unwrap(d, "unknown")) }),
  )
  decode.success(FactProvenance(
    source_cycle_id:,
    source_tool:,
    source_agent:,
    derivation:,
  ))
}

fn decode_derivation(d: String) -> FactDerivation {
  case d {
    "direct_observation" -> DirectObservation
    "synthesis" -> Synthesis
    "operator_provided" -> OperatorProvided
    _ -> Unknown
  }
}

fn decode_scope(s: String) -> FactScope {
  case s {
    "persistent" -> Persistent
    "ephemeral" -> Ephemeral
    _ -> Session
  }
}

fn decode_op(o: String) -> FactOp {
  case o {
    "clear" -> Clear
    "superseded" -> Superseded
    _ -> Write
  }
}
