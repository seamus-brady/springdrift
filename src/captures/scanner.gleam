//// Post-cycle capture scanner.
////
//// After each cycle, this module spawns an unlinked worker that asks
//// `task_model` (typically Haiku) to extract commitment-shaped statements
//// from the cycle's input + response. The LLM is instructed to ignore
//// rhetoric, negation, conditionals that didn't fire, and already-delivered
//// commitments. Empty `<captures/>` is the common and acceptable case.
////
//// Results run through a deterministic sanity filter before landing in the
//// JSONL log: max count per cycle, length bound, prompt-echo rejection.
//// The filter is an extraction-quality gate, not a D' gate.
////
//// Failure is benign: if the LLM call fails, captures for the cycle are
//// missed; the scanner never blocks the user.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import captures/log as captures_log
import captures/types.{
  type Capture, type CaptureSource, AgentSelf, Capture, Created, InboundComms,
  OperatorAsk, Pending,
}
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/provider.{type Provider}
import narrative/librarian.{type LibrarianMessage}
import paths
import slog
import xstructor
import xstructor/schemas

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_uuid() -> String

// ---------------------------------------------------------------------------
// Context + config
// ---------------------------------------------------------------------------

pub type ScannerContext {
  ScannerContext(cycle_id: String, user_input: String, final_response: String)
}

pub type ScannerConfig {
  ScannerConfig(enabled: Bool, max_per_cycle: Int, captures_dir: String)
}

pub const default_max_per_cycle: Int = 10

pub const default_max_text_length: Int = 500

// ---------------------------------------------------------------------------
// Public entry — fire-and-forget spawn
// ---------------------------------------------------------------------------

/// Spawn a scanner worker asynchronously. Does not block the caller.
/// No-op when `config.enabled` is False.
pub fn spawn(
  ctx: ScannerContext,
  cfg: ScannerConfig,
  provider: Provider,
  model: String,
  max_tokens: Int,
  lib: Option(Subject(LibrarianMessage)),
) -> Nil {
  case cfg.enabled {
    False -> Nil
    True -> {
      let _ =
        process.spawn_unlinked(fn() {
          scan_and_persist(ctx, cfg, provider, model, max_tokens, lib)
        })
      Nil
    }
  }
}

// ---------------------------------------------------------------------------
// Core — one cycle's worth of scanning
// ---------------------------------------------------------------------------

fn scan_and_persist(
  ctx: ScannerContext,
  cfg: ScannerConfig,
  provider: Provider,
  model: String,
  max_tokens: Int,
  lib: Option(Subject(LibrarianMessage)),
) -> Nil {
  case extract(ctx, provider, model, max_tokens) {
    Error(e) -> {
      slog.debug(
        "captures/scanner",
        "scan_and_persist",
        "Extraction failed: " <> string.slice(e, 0, 200),
        Some(ctx.cycle_id),
      )
      Nil
    }
    Ok(raw) -> {
      let filtered = sanity_filter(raw, cfg.max_per_cycle, ctx.cycle_id)
      list.each(filtered, fn(c) {
        captures_log.append(cfg.captures_dir, Created(c))
        case lib {
          Some(l) -> librarian.notify_new_capture(l, c)
          None -> Nil
        }
      })
      case filtered != [] {
        True ->
          slog.info(
            "captures/scanner",
            "scan_and_persist",
            "Persisted "
              <> int.to_string(list.length(filtered))
              <> " capture(s) for cycle",
            Some(ctx.cycle_id),
          )
        False -> Nil
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Extraction — LLM call + XStructor
// ---------------------------------------------------------------------------

/// Extract raw captures from a scanner context. Returns a list of unvalidated
/// Capture records (status=Pending, populated with id and timestamp). Pure in
/// everything except the LLM call.
pub fn extract(
  ctx: ScannerContext,
  provider: Provider,
  model: String,
  max_tokens: Int,
) -> Result(List(Capture), String) {
  let schema_dir = paths.schemas_dir()
  case
    xstructor.compile_schema(schema_dir, "captures.xsd", schemas.captures_xsd)
  {
    Error(e) -> Error("Schema compile failed: " <> e)
    Ok(schema) -> {
      let system =
        schemas.build_system_prompt(
          scanner_system_prompt(),
          schemas.captures_xsd,
          schemas.captures_example,
        )
      let prompt = build_prompt(ctx)
      let config =
        xstructor.XStructorConfig(
          schema: schema,
          system_prompt: system,
          xml_example: schemas.captures_example,
          max_retries: 2,
          max_tokens: max_tokens,
        )
      case xstructor.generate(config, prompt, provider, model) {
        Error(e) -> Error(string.slice(e, 0, 400))
        Ok(result) -> Ok(extract_captures(result.elements, ctx))
      }
    }
  }
}

fn scanner_system_prompt() -> String {
  "You are a commitment detector. You read one cycle's user input and agent
response, and extract any commitment or promise that implies future work.

A commitment is a specific future action someone says they will take.

Examples to capture:
- Agent self-promise: \"I will check the scheduler logs after the research run\"
- Operator ask: \"remind me to review the pull request tomorrow\"
- Deferred work: \"check the logs tomorrow morning\"

Do NOT capture:
- Rhetorical uses of future tense (\"I will bet\", \"I will have what she is having\")
- Negations (\"I will never delete that\", \"we won't do X\")
- Conditional promises whose condition has already failed
- Actions the agent or operator has already completed in this cycle
- General statements of preference or opinion

For each genuine commitment, output a <capture> with:
  - text: the commitment phrased as a concrete future action (rewrite the
    conversational form if needed, but do not invent new content)
  - source: one of agent_self, operator_ask, inbound_comms
  - due_hint: a short, raw time hint if present (\"tomorrow\", \"after the research\",
    \"next week\"); omit entirely if no time hint

Output an empty <captures/> if there are no genuine commitments — this is
the common and correct case for most cycles."
}

fn build_prompt(ctx: ScannerContext) -> String {
  "=== OPERATOR INPUT ===
" <> ctx.user_input <> "

=== AGENT RESPONSE ===
" <> ctx.final_response <> "

Extract any commitments or promises implied by the exchange above."
}

fn extract_captures(
  elements: dict.Dict(String, String),
  ctx: ScannerContext,
) -> List(Capture) {
  extract_indexed(elements, ctx, 0, [])
}

fn extract_indexed(
  elements: dict.Dict(String, String),
  ctx: ScannerContext,
  idx: Int,
  acc: List(Capture),
) -> List(Capture) {
  let base = "captures.capture." <> int.to_string(idx)
  case dict.get(elements, base <> ".text") {
    Error(_) -> list.reverse(acc)
    Ok(text) -> {
      let source_str = case dict.get(elements, base <> ".source") {
        Ok(s) -> s
        Error(_) -> "agent_self"
      }
      let due_hint = case dict.get(elements, base <> ".due_hint") {
        Ok(h) ->
          case string.trim(h) {
            "" -> None
            trimmed -> Some(trimmed)
          }
        Error(_) -> None
      }
      let capture =
        Capture(
          schema_version: 1,
          id: "cap-" <> short_id(),
          created_at: get_datetime(),
          source_cycle_id: ctx.cycle_id,
          text: string.trim(text),
          source: parse_source(source_str),
          due_hint: due_hint,
          status: Pending,
        )
      extract_indexed(elements, ctx, idx + 1, [capture, ..acc])
    }
  }
}

fn parse_source(s: String) -> CaptureSource {
  case string.lowercase(string.trim(s)) {
    "operator_ask" -> OperatorAsk
    "operatorask" -> OperatorAsk
    "inbound_comms" -> InboundComms
    "inboundcomms" -> InboundComms
    _ -> AgentSelf
  }
}

fn short_id() -> String {
  generate_uuid() |> string.slice(0, 8)
}

// ---------------------------------------------------------------------------
// Sanity filter — extraction-quality gate (app-level, not D')
// ---------------------------------------------------------------------------

/// Filter raw scanner output:
///   1. Cap total count at `max_per_cycle`
///   2. Drop captures whose text is empty or over `default_max_text_length`
///   3. Drop captures whose text looks like a prompt echo (contains enough
///      phrases from the scanner's own instructions)
///
/// Rejected captures are logged via slog and silently dropped.
pub fn sanity_filter(
  captures: List(Capture),
  max_per_cycle: Int,
  cycle_id: String,
) -> List(Capture) {
  let filtered =
    captures
    |> list.filter_map(fn(c) {
      case validate(c, cycle_id) {
        Ok(clean) -> Ok(clean)
        Error(_) -> Error(Nil)
      }
    })
  case list.length(filtered) > max_per_cycle {
    True -> {
      slog.warn(
        "captures/scanner",
        "sanity_filter",
        "Truncating "
          <> int.to_string(list.length(filtered))
          <> " captures to "
          <> int.to_string(max_per_cycle),
        Some(cycle_id),
      )
      list.take(filtered, max_per_cycle)
    }
    False -> filtered
  }
}

fn validate(c: Capture, cycle_id: String) -> Result(Capture, String) {
  let trimmed_text = string.trim(c.text)
  let text_length = string.length(trimmed_text)
  case trimmed_text, text_length {
    "", _ -> {
      slog.debug(
        "captures/scanner",
        "validate",
        "Rejected: empty text",
        Some(cycle_id),
      )
      Error("empty")
    }
    _, n if n > default_max_text_length -> {
      slog.debug(
        "captures/scanner",
        "validate",
        "Rejected: text length "
          <> int.to_string(n)
          <> " > "
          <> int.to_string(default_max_text_length),
        Some(cycle_id),
      )
      Error("too_long")
    }
    t, _ ->
      case looks_like_prompt_echo(t) {
        True -> {
          slog.warn(
            "captures/scanner",
            "validate",
            "Rejected: prompt echo detected in capture text",
            Some(cycle_id),
          )
          Error("prompt_echo")
        }
        False -> Ok(Capture(..c, text: xml_escape(t)))
      }
  }
}

/// Reject captures that look like the LLM is echoing the scanner prompt
/// back as a capture. Matches on a few stable phrases from the system
/// prompt — conservative, just catches obvious cases.
fn looks_like_prompt_echo(text: String) -> Bool {
  let lowered = string.lowercase(text)
  let echo_markers = [
    "you are a commitment detector",
    "extract any commitment",
    "rhetorical uses of future tense",
    "examples to capture",
    "do not capture",
    "output an empty",
  ]
  list.any(echo_markers, fn(m) { string.contains(lowered, m) })
}

/// Minimal XML escape so capture text renders safely in the sensorium.
fn xml_escape(s: String) -> String {
  s
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
  |> string.replace("'", "&apos;")
}
