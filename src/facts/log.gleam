//// Append-only MemoryFact log — facts.jsonl in .springdrift/memory/facts/.
////
//// Unlike narrative and CBR which are date-sharded, facts use a single
//// facts.jsonl file since the volume is much lower and key-based lookup
//// needs the full history.

import facts/types.{
  type FactOp, type FactScope, type MemoryFact, Clear, Ephemeral, MemoryFact,
  Persistent, Session, Superseded, Write,
}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import simplifile
import slog

// ---------------------------------------------------------------------------
// Append
// ---------------------------------------------------------------------------

/// Append a MemoryFact to facts.jsonl.
pub fn append(dir: String, fact: MemoryFact) -> Nil {
  let path = dir <> "/facts.jsonl"
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

/// Load all facts from facts.jsonl.
pub fn load_all(dir: String) -> List(MemoryFact) {
  let path = dir <> "/facts.jsonl"
  case simplifile.read(path) {
    Error(_) -> []
    Ok(content) -> parse_jsonl(content)
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
  ])
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
  ))
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
