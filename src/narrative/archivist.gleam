//// Archivist — generates NarrativeEntry from cycle context via LLM.
////
//// Runs asynchronously after the reply is sent to the user. If it fails,
//// the cycle completes normally — the Archivist is never visible to the user.
//// Produces a complete NarrativeEntry JSON response in a single LLM call.

import agent/types as agent_types
import cbr/log as cbr_log
import cbr/types as cbr_types
import embedding/client as embedding_client
import embedding/types as embedding_types
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import llm/provider.{type Provider}
import llm/request
import llm/response
import narrative/curator.{type CuratorMessage}
import narrative/librarian.{type LibrarianMessage}
import narrative/log as narrative_log
import narrative/threading
import narrative/types.{
  type Entities, type NarrativeEntry, Conversation, Entities, Failure, Intent,
  Metrics, Narrative, NarrativeEntry, Outcome, Success,
}
import slog

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

// ---------------------------------------------------------------------------
// Archivist context — everything the Archivist needs
// ---------------------------------------------------------------------------

pub type ArchivistContext {
  ArchivistContext(
    cycle_id: String,
    parent_cycle_id: Option(String),
    user_input: String,
    final_response: String,
    agent_completions: List(agent_types.AgentCompletionRecord),
    model_used: String,
    classification: String,
    total_input_tokens: Int,
    total_output_tokens: Int,
    tool_calls: Int,
    dprime_decisions: List(String),
    thread_index_json: String,
  )
}

// ---------------------------------------------------------------------------
// Generate
// ---------------------------------------------------------------------------

/// Generate a NarrativeEntry from the Archivist context.
/// Returns None if the LLM call fails (silent failure).
pub fn generate(
  ctx: ArchivistContext,
  provider: Provider,
  model: String,
  max_tokens: Int,
  _verbose: Bool,
) -> Option(NarrativeEntry) {
  let prompt = build_prompt(ctx)
  let req =
    request.new(model, max_tokens)
    |> request.with_system(archivist_system_prompt())
    |> request.with_user_message(prompt)

  case provider.chat(req) {
    Ok(resp) -> {
      let text = response.text(resp)
      case parse_narrative_entry(text, ctx) {
        Ok(entry) -> {
          slog.info(
            "narrative/archivist",
            "generate",
            "Generated narrative for cycle " <> ctx.cycle_id,
            Some(ctx.cycle_id),
          )
          Some(entry)
        }
        Error(_) -> {
          slog.warn(
            "narrative/archivist",
            "generate",
            "Archivist JSON parse failed (falling back). Raw response: "
              <> string.slice(text, 0, 300),
            Some(ctx.cycle_id),
          )
          // Fall back to a minimal entry with context
          Some(fallback_entry(ctx))
        }
      }
    }
    Error(_) -> {
      slog.warn(
        "narrative/archivist",
        "generate",
        "LLM call failed, skipping narrative",
        Some(ctx.cycle_id),
      )
      None
    }
  }
}

/// Enrich a NarrativeEntry with LLM-generated topic phrases.
/// Falls back to the existing entry unchanged on any failure.
fn enrich_topics(
  entry: NarrativeEntry,
  ctx: ArchivistContext,
  provider: Provider,
  model: String,
) -> NarrativeEntry {
  case generate_topics(ctx, provider, model) {
    [] -> entry
    topics -> NarrativeEntry(..entry, topics:)
  }
}

/// Generate 3-5 topic phrases from cycle context via a cheap LLM call.
/// Returns empty list on failure (silent — never affects the user).
fn generate_topics(
  ctx: ArchivistContext,
  provider: Provider,
  model: String,
) -> List(String) {
  let prompt =
    "USER INPUT:\n"
    <> string.slice(ctx.user_input, 0, 500)
    <> "\n\nRESPONSE SUMMARY:\n"
    <> string.slice(ctx.final_response, 0, 500)
  let req =
    request.new(model, 256)
    |> request.with_system(
      "Extract 3-5 topic phrases from this conversation cycle. Each topic should be 2-5 words describing a specific subject discussed (e.g. \"Brave Search API errors\", \"web UI sidebar layout\", \"cycle log persistence\"). Return ONLY a JSON array of strings, no other text.",
    )
    |> request.with_user_message(prompt)

  case provider.chat(req) {
    Ok(resp) -> {
      let text = response.text(resp)
      let cleaned =
        text
        |> string.trim
        |> strip_markdown_fences
      case json.parse(cleaned, decode.list(decode.string)) {
        Ok(topics) -> list.take(topics, 7)
        Error(_) -> {
          slog.debug(
            "narrative/archivist",
            "generate_topics",
            "Topic parse failed: " <> string.slice(text, 0, 100),
            Some(ctx.cycle_id),
          )
          []
        }
      }
    }
    Error(_) -> []
  }
}

/// Spawn the Archivist asynchronously. Does not block the caller.
/// If a Librarian is available, it is notified after the entry is written.
/// After the NarrativeEntry, a second LLM call generates a CbrCase.
pub fn spawn(
  ctx: ArchivistContext,
  provider: Provider,
  model: String,
  max_tokens: Int,
  narrative_dir: String,
  cbr_dir: String,
  verbose: Bool,
  lib: Option(Subject(LibrarianMessage)),
  embed_config: embedding_types.EmbeddingConfig,
  cur: Option(Subject(CuratorMessage)),
  threading_config: threading.ThreadingConfig,
) -> Nil {
  let _ =
    process.spawn_unlinked(fn() {
      case generate(ctx, provider, model, max_tokens, verbose) {
        Some(entry) -> {
          // Generate topic phrases via a cheap LLM call
          let with_topics = enrich_topics(entry, ctx, provider, model)
          let threaded =
            threading.assign_thread(
              with_topics,
              narrative_dir,
              lib,
              threading_config,
            )
          narrative_log.append(narrative_dir, threaded)
          // Notify the Librarian to index the new entry
          case lib {
            Some(l) -> {
              librarian.notify_new_entry(l, threaded)
              // Also update the thread index in the Librarian
              let idx = narrative_log.load_thread_index(narrative_dir)
              librarian.notify_thread_index(l, idx)
            }
            None -> Nil
          }

          // Push constitution update to Curator
          case cur {
            Some(c) -> {
              let today_entries =
                narrative_log.load_entries(
                  narrative_dir,
                  get_date(),
                  get_date(),
                )
              let total = list.length(today_entries)
              let successes =
                list.count(today_entries, fn(e) { e.outcome.status == Success })
              let rate = case total > 0 {
                True -> int.to_float(successes) /. int.to_float(total)
                False -> 0.0
              }
              curator.update_constitution(c, total, rate, "")
            }
            None -> Nil
          }

          // Step 2: Generate CBR case from the narrative entry
          case generate_cbr_case(ctx, threaded, provider, model) {
            Some(cbr_case) -> {
              // Embed the case before persisting
              let embedded = embed_cbr_case(cbr_case, embed_config)
              cbr_log.append(cbr_dir, embedded)
              case lib {
                Some(l) -> librarian.notify_new_case(l, embedded)
                None -> Nil
              }
            }
            None -> Nil
          }
        }
        None -> Nil
      }
    })
  Nil
}

// ---------------------------------------------------------------------------
// Prompt
// ---------------------------------------------------------------------------

fn archivist_system_prompt() -> String {
  "You are the Archivist for an AI agent called Springdrift. Your job is to write a first-person narrative record of what just happened in a conversation cycle.

RULES:
- Write in first person, past tense: 'I was asked...', 'I delegated...', 'I found...'
- Be honest about confidence and limitations
- Use the controlled vocabulary for intent classification
- Extract entities, keywords, and sources from the context
- Respond with ONLY valid JSON matching the NarrativeEntry schema. No preamble, no markdown.

INTENT CLASSIFICATIONS: data_report, data_query, comparison, trend_analysis, monitoring_check, exploration, clarification, system_command, conversation

OUTCOME STATUS: success, partial, failure

JSON SCHEMA (respond with exactly this structure):
{
  \"cycle_id\": \"<copy from CYCLE ID above>\",
  \"timestamp\": \"<copy from TIMESTAMP above>\",
  \"summary\": \"First-person 2-5 sentence narrative\",
  \"intent\": {\"classification\": \"...\", \"description\": \"...\", \"domain\": \"...\"},
  \"outcome\": {\"status\": \"...\", \"confidence\": 0.0-1.0, \"assessment\": \"...\"},
  \"delegation_chain\": [{\"agent\": \"...\", \"instruction\": \"...\", \"outcome\": \"...\", \"contribution\": \"...\"}],
  \"decisions\": [{\"point\": \"...\", \"choice\": \"...\", \"rationale\": \"...\"}],
  \"keywords\": [\"...\"],
  \"entities\": {\"locations\": [], \"organisations\": [], \"data_points\": [], \"temporal_references\": []},
  \"sources\": [{\"type\": \"...\", \"name\": \"...\"}],
  \"metrics\": {\"total_duration_ms\": 0, \"input_tokens\": 0, \"output_tokens\": 0, \"thinking_tokens\": 0, \"tool_calls\": 0, \"agent_delegations\": 0, \"dprime_evaluations\": 0, \"model_used\": \"...\"},
  \"observations\": [{\"type\": \"...\", \"severity\": \"info|warning|error\", \"detail\": \"...\"}]
}"
}

fn build_prompt(ctx: ArchivistContext) -> String {
  let agents_text = case ctx.agent_completions {
    [] -> "No agents were delegated to."
    completions ->
      "AGENT DELEGATIONS:\n"
      <> string.join(
        list.map(completions, fn(c) {
          let tool_lines = case c.tool_call_details {
            [] -> ""
            details ->
              "\n"
              <> string.join(
                list.map(details, fn(d: agent_types.ToolCallDetail) {
                  "    Tool: "
                  <> d.name
                  <> " → "
                  <> string.slice(d.output_summary, 0, 150)
                  <> " ["
                  <> case d.success {
                    True -> "SUCCESS"
                    False -> "FAILED"
                  }
                  <> "]"
                }),
                "\n",
              )
          }
          "- "
          <> c.agent_human_name
          <> " (id: "
          <> c.agent_id
          <> "): "
          <> case c.result {
            Ok(r) -> "SUCCESS — " <> string.slice(r, 0, 1000)
            Error(e) -> "FAILED — " <> e
          }
          <> " [tokens: "
          <> int.to_string(c.input_tokens)
          <> "+"
          <> int.to_string(c.output_tokens)
          <> ", "
          <> int.to_string(c.duration_ms)
          <> "ms]"
          <> tool_lines
        }),
        "\n",
      )
  }

  let dprime_text = case ctx.dprime_decisions {
    [] -> "No D' evaluations."
    decisions -> "D' DECISIONS:\n" <> string.join(decisions, "\n")
  }

  let timestamp = get_datetime()
  "CYCLE ID: "
  <> ctx.cycle_id
  <> "\nTIMESTAMP: "
  <> timestamp
  <> "\nMODEL: "
  <> ctx.model_used
  <> "\nCLASSIFICATION: "
  <> ctx.classification
  <> "\n\nUSER INPUT:\n"
  <> ctx.user_input
  <> "\n\nFINAL RESPONSE:\n"
  <> string.slice(ctx.final_response, 0, 2000)
  <> "\n\n"
  <> agents_text
  <> "\n\n"
  <> dprime_text
  <> "\n\nTOTAL TOKENS: "
  <> int.to_string(ctx.total_input_tokens)
  <> " in + "
  <> int.to_string(ctx.total_output_tokens)
  <> " out"
  <> "\nTOOL CALLS: "
  <> int.to_string(ctx.tool_calls)
}

// ---------------------------------------------------------------------------
// Parse LLM response into NarrativeEntry
// ---------------------------------------------------------------------------

fn parse_narrative_entry(
  text: String,
  ctx: ArchivistContext,
) -> Result(NarrativeEntry, Nil) {
  let stripped = strip_markdown_fences(string.trim(text))
  let extracted = extract_json_object(stripped)
  // Sanitize control characters that LLMs sometimes leave unescaped in JSON strings
  let cleaned = sanitize_json_string(extracted)
  // Try parsing as-is first, then with single-quote repair
  case try_parse_entry(cleaned) {
    Ok(entry) -> apply_overrides(entry, ctx) |> Ok
    Error(_) -> {
      // Try repairing single quotes to double quotes
      let sq_repaired = replace_single_quotes(cleaned)
      let sq_cleaned = sanitize_json_string(sq_repaired)
      case try_parse_entry(sq_cleaned) {
        Ok(entry) -> apply_overrides(entry, ctx) |> Ok
        Error(_) -> {
          // Try repairing truncated JSON on original
          let repaired = repair_truncated_json(cleaned)
          case try_parse_entry(repaired) {
            Ok(entry) -> apply_overrides(entry, ctx) |> Ok
            Error(_) -> Error(Nil)
          }
        }
      }
    }
  }
}

/// Try parsing JSON text into a NarrativeEntry using the lenient decoder.
fn try_parse_entry(text: String) -> Result(NarrativeEntry, Nil) {
  json.parse(text, lenient_entry_decoder())
  |> result.replace_error(Nil)
}

/// Apply archivist overrides (cycle_id, timestamp, schema_version, entry_type).
fn apply_overrides(
  partial: NarrativeEntry,
  ctx: ArchivistContext,
) -> NarrativeEntry {
  NarrativeEntry(
    ..partial,
    schema_version: 1,
    cycle_id: ctx.cycle_id,
    parent_cycle_id: ctx.parent_cycle_id,
    timestamp: case partial.timestamp {
      "" -> get_datetime()
      ts -> ts
    },
    entry_type: Narrative,
  )
}

/// Replace single-quoted JSON keys and string values with double quotes.
/// This is a best-effort repair for LLMs that produce Python-style JSON.
/// Walks the string character by character, swapping ' for " when it appears
/// to be a JSON string delimiter (not inside a double-quoted string, and not
/// an apostrophe in text like "don't").
fn replace_single_quotes(text: String) -> String {
  replace_sq_walk(string.to_graphemes(text), False, False, False, [])
  |> list.reverse
  |> string.join("")
}

fn replace_sq_walk(
  graphemes: List(String),
  in_double: Bool,
  in_single: Bool,
  escaped: Bool,
  acc: List(String),
) -> List(String) {
  case graphemes {
    [] -> acc
    [g, ..rest] ->
      case escaped {
        True -> replace_sq_walk(rest, in_double, in_single, False, [g, ..acc])
        False ->
          case g {
            "\\" ->
              replace_sq_walk(rest, in_double, in_single, True, [g, ..acc])
            "\"" ->
              case in_single {
                // Inside a single-quoted string, keep literal "
                True ->
                  replace_sq_walk(rest, False, True, False, ["\\\"", ..acc])
                False ->
                  replace_sq_walk(rest, !in_double, False, False, ["\"", ..acc])
              }
            "'" ->
              case in_double {
                // Inside a double-quoted string, keep as apostrophe
                True -> replace_sq_walk(rest, True, False, False, ["'", ..acc])
                False ->
                  // Swap single quote for double quote
                  replace_sq_walk(rest, False, !in_single, False, ["\"", ..acc])
              }
            _ ->
              replace_sq_walk(rest, in_double, in_single, escaped, [g, ..acc])
          }
      }
  }
}

/// Sanitize a JSON string by escaping unescaped control characters inside
/// string values. LLMs often produce JSON with literal newlines, tabs, or
/// other control chars inside quoted strings, which breaks JSON parsers.
@external(erlang, "springdrift_ffi", "sanitize_json")
pub fn sanitize_json_string(json_text: String) -> String

/// Lenient decoder for archivist LLM output — all fields optional with defaults.
fn lenient_entry_decoder() -> decode.Decoder(NarrativeEntry) {
  use cycle_id <- decode.optional_field("cycle_id", "", decode.string)
  use timestamp <- decode.optional_field("timestamp", "", decode.string)
  use summary <- decode.optional_field("summary", "", decode.string)
  use intent <- decode.optional_field(
    "intent",
    Intent(classification: Conversation, description: "", domain: ""),
    lenient_intent_decoder(),
  )
  use outcome <- decode.optional_field(
    "outcome",
    Outcome(status: Success, confidence: 0.5, assessment: ""),
    lenient_outcome_decoder(),
  )
  use delegation_chain <- decode.optional_field(
    "delegation_chain",
    [],
    decode.list(lenient_delegation_decoder()),
  )
  use decisions <- decode.optional_field(
    "decisions",
    [],
    decode.list(lenient_decision_decoder()),
  )
  use keywords <- decode.optional_field(
    "keywords",
    [],
    decode.list(decode.string),
  )
  use entities <- decode.optional_field(
    "entities",
    Entities(
      locations: [],
      organisations: [],
      data_points: [],
      temporal_references: [],
    ),
    lenient_entities_decoder(),
  )
  use sources <- decode.optional_field(
    "sources",
    [],
    decode.list(lenient_source_decoder()),
  )
  use metrics <- decode.optional_field(
    "metrics",
    Metrics(
      total_duration_ms: 0,
      input_tokens: 0,
      output_tokens: 0,
      thinking_tokens: 0,
      tool_calls: 0,
      agent_delegations: 0,
      dprime_evaluations: 0,
      model_used: "",
    ),
    lenient_metrics_decoder(),
  )
  use observations <- decode.optional_field(
    "observations",
    [],
    decode.list(lenient_observation_decoder()),
  )
  decode.success(NarrativeEntry(
    schema_version: 1,
    cycle_id:,
    parent_cycle_id: None,
    timestamp:,
    entry_type: Narrative,
    summary:,
    intent:,
    outcome:,
    delegation_chain:,
    decisions:,
    keywords:,
    topics: [],
    entities:,
    sources:,
    thread: None,
    metrics:,
    observations:,
  ))
}

fn lenient_intent_decoder() -> decode.Decoder(types.Intent) {
  use classification_str <- decode.optional_field(
    "classification",
    "conversation",
    decode.string,
  )
  use description <- decode.optional_field("description", "", decode.string)
  use domain <- decode.optional_field("domain", "", decode.string)
  let classification = case classification_str {
    "data_report" -> types.DataReport
    "data_query" -> types.DataQuery
    "comparison" -> types.Comparison
    "trend_analysis" -> types.TrendAnalysis
    "monitoring_check" -> types.MonitoringCheck
    "exploration" -> types.Exploration
    "clarification" -> types.Clarification
    "system_command" -> types.SystemCommand
    _ -> Conversation
  }
  decode.success(Intent(classification:, description:, domain:))
}

fn lenient_outcome_decoder() -> decode.Decoder(types.Outcome) {
  use status_str <- decode.optional_field("status", "success", decode.string)
  use confidence <- decode.optional_field("confidence", 0.5, decode.float)
  use assessment <- decode.optional_field("assessment", "", decode.string)
  let status = case status_str {
    "partial" -> types.Partial
    "failure" -> Failure
    _ -> Success
  }
  decode.success(Outcome(status:, confidence:, assessment:))
}

fn lenient_delegation_decoder() -> decode.Decoder(types.DelegationStep) {
  use agent <- decode.optional_field("agent", "", decode.string)
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
  decode.success(types.DelegationStep(
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

fn lenient_decision_decoder() -> decode.Decoder(types.Decision) {
  use point <- decode.optional_field("point", "", decode.string)
  use choice <- decode.optional_field("choice", "", decode.string)
  use rationale <- decode.optional_field("rationale", "", decode.string)
  use score <- decode.optional_field(
    "score",
    None,
    decode.optional(decode.float),
  )
  decode.success(types.Decision(point:, choice:, rationale:, score:))
}

fn lenient_entities_decoder() -> decode.Decoder(Entities) {
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
    decode.list(lenient_data_point_decoder()),
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

fn lenient_data_point_decoder() -> decode.Decoder(types.DataPoint) {
  use label <- decode.optional_field("label", "", decode.string)
  use value <- decode.optional_field("value", "", decode.string)
  use unit <- decode.optional_field("unit", "", decode.string)
  use period <- decode.optional_field("period", "", decode.string)
  use source <- decode.optional_field("source", "", decode.string)
  decode.success(types.DataPoint(label:, value:, unit:, period:, source:))
}

fn lenient_source_decoder() -> decode.Decoder(types.Source) {
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
  decode.success(types.Source(
    source_type:,
    url:,
    path:,
    name:,
    accessed_at:,
    data_date:,
  ))
}

fn lenient_metrics_decoder() -> decode.Decoder(types.Metrics) {
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

fn lenient_observation_decoder() -> decode.Decoder(types.Observation) {
  use observation_type <- decode.optional_field("type", "", decode.string)
  use severity_str <- decode.optional_field("severity", "info", decode.string)
  use detail <- decode.optional_field("detail", "", decode.string)
  let severity = case severity_str {
    "warning" -> types.Warning
    "error" -> types.ErrorSeverity
    _ -> types.Info
  }
  decode.success(types.Observation(observation_type:, severity:, detail:))
}

// ---------------------------------------------------------------------------
// CBR case generation
// ---------------------------------------------------------------------------

/// Generate a CbrCase from the NarrativeEntry via a second LLM call.
/// Returns None on failure (silent — CBR is best-effort).
fn generate_cbr_case(
  ctx: ArchivistContext,
  entry: NarrativeEntry,
  provider: Provider,
  model: String,
) -> Option(cbr_types.CbrCase) {
  let prompt = build_cbr_prompt(ctx, entry)
  let req =
    request.new(model, 1024)
    |> request.with_system(cbr_system_prompt())
    |> request.with_user_message(prompt)

  case provider.chat(req) {
    Ok(resp) -> {
      let text = response.text(resp)
      case parse_cbr_case(text, ctx, entry) {
        Ok(cbr_case) -> {
          slog.info(
            "narrative/archivist",
            "generate_cbr",
            "Generated CBR case for cycle " <> ctx.cycle_id,
            Some(ctx.cycle_id),
          )
          Some(cbr_case)
        }
        Error(_) -> {
          slog.warn(
            "narrative/archivist",
            "generate_cbr",
            "CBR case parse failed, skipping. Raw: "
              <> string.slice(text, 0, 200),
            Some(ctx.cycle_id),
          )
          None
        }
      }
    }
    Error(_) -> {
      slog.warn(
        "narrative/archivist",
        "generate_cbr",
        "CBR LLM call failed, skipping",
        Some(ctx.cycle_id),
      )
      None
    }
  }
}

/// Generate an embedding for a CBR case and attach it.
/// Falls back to empty embedding on any error (best-effort).
fn embed_cbr_case(
  cbr_case: cbr_types.CbrCase,
  config: embedding_types.EmbeddingConfig,
) -> cbr_types.CbrCase {
  // Build a text representation for embedding from the case's key fields
  let text =
    cbr_case.problem.intent
    <> " "
    <> cbr_case.problem.domain
    <> " "
    <> string.join(cbr_case.problem.keywords, " ")
    <> " "
    <> cbr_case.problem.user_input
    <> " "
    <> cbr_case.solution.approach
  case embedding_client.embed(config, text) {
    Ok(result) -> {
      slog.info(
        "narrative/archivist",
        "embed_cbr",
        "Embedded CBR case "
          <> cbr_case.case_id
          <> " ("
          <> int.to_string(list.length(result.embedding))
          <> " dims)",
        Some(cbr_case.case_id),
      )
      cbr_types.CbrCase(..cbr_case, embedding: result.embedding)
    }
    Error(_) -> {
      slog.warn(
        "narrative/archivist",
        "embed_cbr",
        "Embedding failed for CBR case " <> cbr_case.case_id <> ", using empty",
        Some(cbr_case.case_id),
      )
      cbr_case
    }
  }
}

fn cbr_system_prompt() -> String {
  "You are the Archivist extracting a Case-Based Reasoning record from a completed cognitive cycle. Your goal is to produce a structured problem/solution/outcome record optimised for future retrieval.

RULES:
- Focus on retrievability: use clear, specific terms in problem descriptors
- Capture the approach, not just the result
- Document pitfalls and what went wrong
- Respond with ONLY valid JSON matching the CbrCase schema. No preamble, no markdown.

JSON SCHEMA:
{
  \"problem\": {
    \"user_input\": \"<original query, truncated to 500 chars>\",
    \"intent\": \"<data_report|data_query|comparison|trend_analysis|monitoring_check|exploration|clarification|system_command|conversation>\",
    \"domain\": \"<domain>\",
    \"entities\": [\"<locations + organisations>\"],
    \"keywords\": [\"<key terms>\"],
    \"query_complexity\": \"<simple|moderate|complex>\"
  },
  \"solution\": {
    \"approach\": \"<1-3 sentence description of how the problem was approached>\",
    \"agents_used\": [\"<agent names>\"],
    \"tools_used\": [\"<tool names>\"],
    \"steps\": [\"<key decision points, in order>\"]
  },
  \"outcome\": {
    \"status\": \"<success|partial|failure>\",
    \"confidence\": 0.0-1.0,
    \"assessment\": \"<brief assessment>\",
    \"pitfalls\": [\"<what went wrong or nearly wrong>\"]
  }
}"
}

fn build_cbr_prompt(ctx: ArchivistContext, entry: NarrativeEntry) -> String {
  let agents_text = case ctx.agent_completions {
    [] -> "No agents used."
    completions ->
      "AGENTS USED:\n"
      <> string.join(
        list.map(completions, fn(c) {
          let tool_lines = case c.tool_call_details {
            [] -> ""
            details ->
              "\n"
              <> string.join(
                list.map(details, fn(d: agent_types.ToolCallDetail) {
                  "    Tool: "
                  <> d.name
                  <> " → "
                  <> string.slice(d.output_summary, 0, 150)
                  <> " ["
                  <> case d.success {
                    True -> "SUCCESS"
                    False -> "FAILED"
                  }
                  <> "]"
                }),
                "\n",
              )
          }
          "- "
          <> c.agent_human_name
          <> ": "
          <> case c.result {
            Ok(r) -> "SUCCESS — " <> string.slice(r, 0, 500)
            Error(e) -> "FAILED — " <> e
          }
          <> tool_lines
        }),
        "\n",
      )
  }

  "CYCLE ID: "
  <> ctx.cycle_id
  <> "\n\nUSER INPUT:\n"
  <> string.slice(ctx.user_input, 0, 500)
  <> "\n\nNARRATIVE SUMMARY:\n"
  <> entry.summary
  <> "\n\nINTENT: "
  <> entry.intent.description
  <> " (domain: "
  <> entry.intent.domain
  <> ")"
  <> "\n\nOUTCOME: "
  <> entry.outcome.assessment
  <> " (confidence: "
  <> string.inspect(entry.outcome.confidence)
  <> ")"
  <> "\n\n"
  <> agents_text
  <> "\n\nKEYWORDS: "
  <> string.join(entry.keywords, ", ")
  <> "\nENTITIES: "
  <> string.join(entry.entities.locations, ", ")
  <> " / "
  <> string.join(entry.entities.organisations, ", ")
}

fn parse_cbr_case(
  text: String,
  ctx: ArchivistContext,
  entry: NarrativeEntry,
) -> Result(cbr_types.CbrCase, Nil) {
  let stripped = strip_markdown_fences(string.trim(text))
  let extracted = extract_json_object(stripped)
  let cleaned = sanitize_json_string(extracted)
  case json.parse(cleaned, lenient_cbr_decoder()) {
    Ok(partial) ->
      Ok(
        cbr_types.CbrCase(
          ..partial,
          case_id: ctx.cycle_id,
          timestamp: entry.timestamp,
          schema_version: 1,
          embedding: [],
          source_narrative_id: ctx.cycle_id,
          profile: option.None,
        ),
      )
    Error(_) -> Error(Nil)
  }
}

fn lenient_cbr_decoder() -> decode.Decoder(cbr_types.CbrCase) {
  use problem <- decode.optional_field(
    "problem",
    cbr_types.CbrProblem(
      user_input: "",
      intent: "",
      domain: "",
      entities: [],
      keywords: [],
      query_complexity: "simple",
    ),
    lenient_cbr_problem_decoder(),
  )
  use solution <- decode.optional_field(
    "solution",
    cbr_types.CbrSolution(
      approach: "",
      agents_used: [],
      tools_used: [],
      steps: [],
    ),
    lenient_cbr_solution_decoder(),
  )
  use outcome <- decode.optional_field(
    "outcome",
    cbr_types.CbrOutcome(
      status: "success",
      confidence: 0.5,
      assessment: "",
      pitfalls: [],
    ),
    lenient_cbr_outcome_decoder(),
  )
  decode.success(cbr_types.CbrCase(
    case_id: "",
    timestamp: "",
    schema_version: 1,
    problem:,
    solution:,
    outcome:,
    embedding: [],
    source_narrative_id: "",
    profile: option.None,
  ))
}

fn lenient_cbr_problem_decoder() -> decode.Decoder(cbr_types.CbrProblem) {
  use user_input <- decode.optional_field("user_input", "", decode.string)
  use intent <- decode.optional_field("intent", "", decode.string)
  use domain <- decode.optional_field("domain", "", decode.string)
  use entities <- decode.optional_field(
    "entities",
    [],
    decode.list(decode.string),
  )
  use keywords <- decode.optional_field(
    "keywords",
    [],
    decode.list(decode.string),
  )
  use query_complexity <- decode.optional_field(
    "query_complexity",
    "simple",
    decode.string,
  )
  decode.success(cbr_types.CbrProblem(
    user_input:,
    intent:,
    domain:,
    entities:,
    keywords:,
    query_complexity:,
  ))
}

fn lenient_cbr_solution_decoder() -> decode.Decoder(cbr_types.CbrSolution) {
  use approach <- decode.optional_field("approach", "", decode.string)
  use agents_used <- decode.optional_field(
    "agents_used",
    [],
    decode.list(decode.string),
  )
  use tools_used <- decode.optional_field(
    "tools_used",
    [],
    decode.list(decode.string),
  )
  use steps <- decode.optional_field("steps", [], decode.list(decode.string))
  decode.success(cbr_types.CbrSolution(
    approach:,
    agents_used:,
    tools_used:,
    steps:,
  ))
}

fn lenient_cbr_outcome_decoder() -> decode.Decoder(cbr_types.CbrOutcome) {
  use status <- decode.optional_field("status", "success", decode.string)
  use confidence <- decode.optional_field("confidence", 0.5, decode.float)
  use assessment <- decode.optional_field("assessment", "", decode.string)
  use pitfalls <- decode.optional_field(
    "pitfalls",
    [],
    decode.list(decode.string),
  )
  decode.success(cbr_types.CbrOutcome(
    status:,
    confidence:,
    assessment:,
    pitfalls:,
  ))
}

fn extract_fallback_domain(text: String) -> String {
  let lower = string.lowercase(text)
  // Check for common domain indicators
  let domains = [
    #("research", "research"),
    #("search", "research"),
    #("find", "research"),
    #("look up", "research"),
    #("code", "software"),
    #("programming", "software"),
    #("bug", "software"),
    #("function", "software"),
    #("write", "creative_work"),
    #("draft", "creative_work"),
    #("poem", "creative_work"),
    #("story", "creative_work"),
    #("data", "data_analysis"),
    #("number", "data_analysis"),
    #("statistic", "data_analysis"),
    #("trend", "data_analysis"),
    #("weather", "environment"),
    #("climate", "environment"),
    #("price", "economics"),
    #("cost", "economics"),
    #("market", "economics"),
    #("cook", "food"),
    #("recipe", "food"),
    #("travel", "travel"),
    #("flight", "travel"),
    #("health", "health"),
    #("medical", "health"),
  ]
  case list.find(domains, fn(pair) { string.contains(lower, pair.0) }) {
    Ok(#(_, domain)) -> domain
    Error(_) -> ""
  }
}

fn extract_fallback_topics(text: String) -> List(String) {
  // Take the first 100 chars, split into rough phrases
  let truncated = string.slice(text, 0, 100)
  let words =
    string.split(truncated, " ")
    |> list.filter(fn(w) { string.length(w) > 2 })
    |> list.take(8)
  // Create 1-2 topic phrases from groups of 2-3 words
  case words {
    [a, b, c, d, ..] -> [a <> " " <> b <> " " <> c, d]
    [a, b, c] -> [a <> " " <> b <> " " <> c]
    [a, b] -> [a <> " " <> b]
    [a] -> [a]
    [] -> []
  }
}

fn fallback_entry(ctx: ArchivistContext) -> NarrativeEntry {
  // Build a factual summary from the cycle context
  let user_part =
    "I was asked: \"" <> truncate_text(ctx.user_input, 200) <> "\"."
  let response_part = case ctx.final_response {
    "" -> " I was unable to produce a response."
    r -> " I responded: \"" <> truncate_text(r, 300) <> "\""
  }
  let agent_part = case ctx.agent_completions {
    [] -> ""
    completions -> {
      let agent_lines =
        list.map(completions, fn(c) {
          c.agent_human_name
          <> " ("
          <> string.join(c.tools_used, ", ")
          <> "): "
          <> case c.result {
            Ok(r) -> "succeeded — " <> truncate_text(r, 100)
            Error(e) -> "failed — " <> truncate_text(e, 100)
          }
        })
      " I delegated to: " <> string.join(agent_lines, "; ") <> "."
    }
  }
  let error_part = case string.contains(ctx.final_response, "[Error:") {
    True -> " (Note: cycle encountered errors.)"
    False -> ""
  }
  let summary = user_part <> response_part <> agent_part <> error_part
  // Determine intent from agent names if possible
  let has_researcher =
    list.any(ctx.agent_completions, fn(c) {
      string.contains(string.lowercase(c.agent_human_name), "research")
    })
  let classification = case has_researcher {
    True -> types.DataQuery
    False -> Conversation
  }
  // Determine outcome from response and agent results
  let any_failure =
    list.any(ctx.agent_completions, fn(c) {
      case c.result {
        Error(_) -> True
        _ -> False
      }
    })
  let status = case ctx.final_response, any_failure {
    "", _ -> Failure
    _, True -> types.Partial
    _, False -> Success
  }
  NarrativeEntry(
    schema_version: 1,
    cycle_id: ctx.cycle_id,
    parent_cycle_id: ctx.parent_cycle_id,
    timestamp: get_datetime(),
    entry_type: Narrative,
    summary: summary,
    intent: Intent(
      classification:,
      description: "",
      domain: extract_fallback_domain(ctx.user_input),
    ),
    outcome: Outcome(
      status:,
      confidence: 0.4,
      assessment: "Reconstructed from cycle context (archivist parse failed)",
    ),
    delegation_chain: list.map(ctx.agent_completions, fn(c) {
      types.DelegationStep(
        agent: c.agent_human_name,
        agent_id: c.agent_id,
        agent_human_name: c.agent_human_name,
        agent_cycle_id: c.agent_cycle_id,
        instruction: truncate_text(c.instruction, 200),
        outcome: case c.result {
          Ok(_) -> "success"
          Error(_) -> "failure"
        },
        contribution: case c.result {
          Ok(r) -> truncate_text(r, 300)
          Error(e) -> "Error: " <> truncate_text(e, 200)
        },
        tools_used: c.tools_used,
        sources_accessed: 0,
        input_tokens: c.input_tokens,
        output_tokens: c.output_tokens,
        duration_ms: c.duration_ms,
      )
    }),
    decisions: [],
    keywords: extract_simple_keywords(ctx.user_input),
    topics: extract_fallback_topics(ctx.user_input),
    entities: Entities(
      locations: [],
      organisations: [],
      data_points: [],
      temporal_references: [],
    ),
    sources: [],
    thread: None,
    metrics: Metrics(
      total_duration_ms: 0,
      input_tokens: ctx.total_input_tokens,
      output_tokens: ctx.total_output_tokens,
      thinking_tokens: 0,
      tool_calls: ctx.tool_calls,
      agent_delegations: list.length(ctx.agent_completions),
      dprime_evaluations: list.length(ctx.dprime_decisions),
      model_used: ctx.model_used,
    ),
    observations: [],
  )
}

/// Truncate text to a maximum length, appending "..." if truncated.
fn truncate_text(text: String, max_len: Int) -> String {
  case string.length(text) > max_len {
    True -> string.slice(text, 0, max_len) <> "..."
    False -> text
  }
}

/// Extract simple keywords by splitting on spaces and filtering short/stop words.
fn extract_simple_keywords(text: String) -> List(String) {
  text
  |> string.lowercase
  |> string.replace(",", " ")
  |> string.replace(".", " ")
  |> string.replace("?", " ")
  |> string.replace("!", " ")
  |> string.replace("\"", " ")
  |> string.split(" ")
  |> list.map(string.trim)
  |> list.filter(fn(w) { string.length(w) > 3 })
  |> list.filter(fn(w) {
    !list.contains(
      [
        "what", "that", "this", "with", "from", "have", "been", "will", "would",
        "could", "should", "about", "there", "their", "which", "when", "where",
        "some", "than", "them", "then", "they", "your", "into", "also", "just",
        "like", "very", "much", "does", "want",
      ],
      w,
    )
  })
  |> list.unique
  |> list.take(10)
}

/// Strip markdown code fences (```json ... ```) from LLM output.
/// Handles: ```json, ```JSON, ``` with whitespace, fences not at start of text,
/// and multiple fenced blocks (takes content from the first one).
fn strip_markdown_fences(text: String) -> String {
  // Try to find a code fence anywhere in the text, not just at the start
  case find_fence_start(string.split(text, "\n"), []) {
    Ok(#(content_lines, _after_close)) -> {
      content_lines
      |> list.reverse
      |> string.join("\n")
      |> string.trim
    }
    Error(_) -> text
  }
}

/// Walk lines looking for an opening fence. When found, collect lines until
/// the closing fence and return the content between them plus remaining lines.
fn find_fence_start(
  lines: List(String),
  skipped: List(String),
) -> Result(#(List(String), List(String)), Nil) {
  case lines {
    [] -> Error(Nil)
    [line, ..rest] -> {
      let trimmed = string.trim(line)
      case is_opening_fence(trimmed) {
        True -> collect_until_close(rest, [])
        False -> find_fence_start(rest, [line, ..skipped])
      }
    }
  }
}

/// Check if a line is an opening code fence: ``` optionally followed by
/// a language tag like json, JSON, jsonc, etc.
fn is_opening_fence(line: String) -> Bool {
  case string.starts_with(line, "```") {
    True -> {
      let after_ticks = string.drop_start(line, 3)
      let tag = string.trim(after_ticks)
      // Opening fence: bare ``` or ``` followed by a simple language tag
      tag == ""
      || {
        !string.contains(tag, " ")
        && !string.contains(tag, "}")
        && !string.contains(tag, "{")
      }
    }
    False -> False
  }
}

/// Collect lines until a closing ``` fence is found.
fn collect_until_close(
  lines: List(String),
  acc: List(String),
) -> Result(#(List(String), List(String)), Nil) {
  case lines {
    // No closing fence found — return what we collected anyway
    [] -> Ok(#(acc, []))
    [line, ..rest] -> {
      case string.trim(line) == "```" {
        True -> Ok(#(acc, rest))
        False -> collect_until_close(rest, [line, ..acc])
      }
    }
  }
}

/// Attempt to repair truncated JSON by closing unclosed strings, arrays,
/// and objects. Best-effort — if the JSON is too broken, returns it unchanged.
fn repair_truncated_json(text: String) -> String {
  let graphemes = string.to_graphemes(text)
  let #(open_braces, open_brackets, in_string) =
    count_open_structures(graphemes, 0, 0, False, False)
  case open_braces > 0 || open_brackets > 0 || in_string {
    False -> text
    True -> {
      // Close unclosed string first
      let base = case in_string {
        True -> text <> "\""
        False -> text
      }
      // Close arrays then objects
      let with_brackets = close_n(base, "]", open_brackets)
      close_n(with_brackets, "}", open_braces)
    }
  }
}

fn count_open_structures(
  graphemes: List(String),
  braces: Int,
  brackets: Int,
  in_string: Bool,
  escaped: Bool,
) -> #(Int, Int, Bool) {
  case graphemes {
    [] -> #(braces, brackets, in_string)
    [g, ..rest] -> {
      case escaped {
        True -> count_open_structures(rest, braces, brackets, in_string, False)
        False ->
          case in_string {
            True ->
              case g {
                "\\" ->
                  count_open_structures(rest, braces, brackets, True, True)
                "\"" ->
                  count_open_structures(rest, braces, brackets, False, False)
                _ -> count_open_structures(rest, braces, brackets, True, False)
              }
            False ->
              case g {
                "\"" ->
                  count_open_structures(rest, braces, brackets, True, False)
                "{" ->
                  count_open_structures(
                    rest,
                    braces + 1,
                    brackets,
                    False,
                    False,
                  )
                "}" ->
                  count_open_structures(
                    rest,
                    int.max(0, braces - 1),
                    brackets,
                    False,
                    False,
                  )
                "[" ->
                  count_open_structures(
                    rest,
                    braces,
                    brackets + 1,
                    False,
                    False,
                  )
                "]" ->
                  count_open_structures(
                    rest,
                    braces,
                    int.max(0, brackets - 1),
                    False,
                    False,
                  )
                _ -> count_open_structures(rest, braces, brackets, False, False)
              }
          }
      }
    }
  }
}

fn close_n(text: String, closer: String, n: Int) -> String {
  case n > 0 {
    True -> close_n(text <> closer, closer, n - 1)
    False -> text
  }
}

/// Extract a JSON object from text that may contain preamble or trailing
/// content. Finds the first '{' and tracks brace depth to find its matching
/// '}', correctly ignoring braces inside JSON string literals.
pub fn extract_json_object(text: String) -> String {
  let graphemes = string.to_graphemes(text)
  // Skip to the first '{' character
  case skip_to_open_brace(graphemes, 0) {
    Error(_) -> text
    Ok(#(start_idx, rest_graphemes)) -> {
      // Track depth starting at 1 (we consumed the opening brace)
      case find_matching_close(rest_graphemes, 1, False, False, start_idx + 1) {
        Error(_) ->
          // No matching close found — return from first brace to end
          string.slice(text, start_idx, string.length(text) - start_idx)
        Ok(end_idx) -> string.slice(text, start_idx, end_idx - start_idx + 1)
      }
    }
  }
}

/// Skip graphemes until the first '{' is found.
/// Returns the index and the remaining graphemes after the '{'.
fn skip_to_open_brace(
  graphemes: List(String),
  idx: Int,
) -> Result(#(Int, List(String)), Nil) {
  case graphemes {
    [] -> Error(Nil)
    [g, ..rest] ->
      case g == "{" {
        True -> Ok(#(idx, rest))
        False -> skip_to_open_brace(rest, idx + 1)
      }
  }
}

/// Walk graphemes tracking brace depth, respecting JSON string literals.
/// Returns the index of the closing '}' that brings depth to 0.
fn find_matching_close(
  graphemes: List(String),
  depth: Int,
  in_string: Bool,
  escaped: Bool,
  idx: Int,
) -> Result(Int, Nil) {
  case graphemes {
    [] -> Error(Nil)
    [g, ..rest] -> {
      case escaped {
        // Previous char was backslash inside a string — skip this char
        True -> find_matching_close(rest, depth, in_string, False, idx + 1)
        False ->
          case in_string {
            True ->
              case g {
                "\\" -> find_matching_close(rest, depth, True, True, idx + 1)
                "\"" -> find_matching_close(rest, depth, False, False, idx + 1)
                _ -> find_matching_close(rest, depth, True, False, idx + 1)
              }
            False ->
              case g {
                "\"" -> find_matching_close(rest, depth, True, False, idx + 1)
                "{" ->
                  find_matching_close(rest, depth + 1, False, False, idx + 1)
                "}" ->
                  case depth - 1 {
                    0 -> Ok(idx)
                    new_depth ->
                      find_matching_close(
                        rest,
                        new_depth,
                        False,
                        False,
                        idx + 1,
                      )
                  }
                _ -> find_matching_close(rest, depth, False, False, idx + 1)
              }
          }
      }
    }
  }
}
