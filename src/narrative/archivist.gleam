//// Archivist — generates NarrativeEntry from cycle context via LLM.
////
//// Runs asynchronously after the reply is sent to the user. If it fails,
//// the cycle completes normally — the Archivist is never visible to the user.
//// Uses XStructor XML-validated generation for structured output.

import agent/types as agent_types
import cbr/log as cbr_log
import cbr/types as cbr_types
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/provider.{type Provider}
import llm/request
import llm/response
import narrative/curator.{type CuratorMessage}
import narrative/librarian.{type LibrarianMessage}
import narrative/log as narrative_log
import narrative/redactor
import narrative/threading
import narrative/types.{
  type Entities, type NarrativeEntry, Conversation, Entities, Failure, Intent,
  Metrics, Narrative, NarrativeEntry, Outcome, Success,
}
import paths
import slog
import xstructor
import xstructor/schemas

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
  let schema_dir = paths.schemas_dir()
  case
    xstructor.compile_schema(
      schema_dir,
      "narrative_entry.xsd",
      schemas.narrative_entry_xsd,
    )
  {
    Error(e) -> {
      slog.warn(
        "narrative/archivist",
        "generate",
        "Schema compile failed: " <> e <> " (falling back)",
        Some(ctx.cycle_id),
      )
      Some(fallback_entry(ctx))
    }
    Ok(schema) -> {
      let system =
        schemas.build_system_prompt(
          archivist_system_prompt_base(),
          schemas.narrative_entry_xsd,
          schemas.narrative_entry_example,
        )
      let config =
        xstructor.XStructorConfig(
          schema: schema,
          system_prompt: system,
          xml_example: schemas.narrative_entry_example,
          max_retries: 3,
          max_tokens: max_tokens,
        )
      case xstructor.generate(config, prompt, provider, model) {
        Ok(result) -> {
          slog.info(
            "narrative/archivist",
            "generate",
            "Generated narrative for cycle " <> ctx.cycle_id,
            Some(ctx.cycle_id),
          )
          Some(extract_narrative_entry(result.elements, ctx))
        }
        Error(e) -> {
          // Distinguish LLM errors (return None) from validation errors (fallback)
          case string.starts_with(e, "LLM error:") {
            True -> {
              slog.warn(
                "narrative/archivist",
                "generate",
                "LLM call failed, skipping narrative",
                Some(ctx.cycle_id),
              )
              None
            }
            False -> {
              slog.warn(
                "narrative/archivist",
                "generate",
                "XStructor generation failed: "
                  <> string.slice(e, 0, 300)
                  <> " (falling back)",
                Some(ctx.cycle_id),
              )
              Some(fallback_entry(ctx))
            }
          }
        }
      }
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
        |> xstructor.clean_response
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
  cur: Option(Subject(CuratorMessage)),
  threading_config: threading.ThreadingConfig,
  redact_secrets: Bool,
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
          // Redact secrets before persisting
          let final_entry = case redact_secrets {
            False -> threaded
            True ->
              NarrativeEntry(
                ..threaded,
                summary: redactor.redact(threaded.summary),
                observations: list.map(threaded.observations, fn(obs) {
                  types.Observation(..obs, detail: redactor.redact(obs.detail))
                }),
                decisions: list.map(threaded.decisions, fn(d) {
                  types.Decision(..d, rationale: redactor.redact(d.rationale))
                }),
                redacted: True,
              )
          }
          narrative_log.append(narrative_dir, final_entry)
          // Notify the Librarian to index the new entry
          case lib {
            Some(l) -> {
              librarian.notify_new_entry(l, final_entry)
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
          case generate_cbr_case(ctx, final_entry, provider, model) {
            Some(raw_case) -> {
              let cbr_case = case redact_secrets {
                False -> raw_case
                True ->
                  cbr_types.CbrCase(
                    ..raw_case,
                    problem: cbr_types.CbrProblem(
                      ..raw_case.problem,
                      user_input: redactor.redact(raw_case.problem.user_input),
                    ),
                    solution: cbr_types.CbrSolution(
                      ..raw_case.solution,
                      approach: redactor.redact(raw_case.solution.approach),
                    ),
                    outcome: cbr_types.CbrOutcome(
                      ..raw_case.outcome,
                      assessment: redactor.redact(raw_case.outcome.assessment),
                    ),
                    redacted: True,
                  )
              }
              // Persist to JSONL and notify Librarian (which encodes into CaseBase)
              cbr_log.append(cbr_dir, cbr_case)
              case lib {
                Some(l) -> librarian.notify_new_case(l, cbr_case)
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

fn archivist_system_prompt_base() -> String {
  "You are the Archivist for an AI agent called Springdrift. Your job is to write a first-person narrative record of what just happened in a conversation cycle.

RULES:
- Write in first person, past tense: 'I was asked...', 'I delegated...', 'I found...'
- Be honest about confidence and limitations
- Use the controlled vocabulary for intent classification

INTENT CLASSIFICATIONS: data_report, data_query, comparison, trend_analysis, monitoring_check, exploration, clarification, system_command, conversation

OUTCOME STATUS: success, partial, failure"
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
// Extract NarrativeEntry from XStructor elements dict
// ---------------------------------------------------------------------------

fn extract_narrative_entry(
  elements: Dict(String, String),
  ctx: ArchivistContext,
) -> NarrativeEntry {
  let summary = get_or(elements, "narrative_entry.summary", "")
  let classification =
    get_or(elements, "narrative_entry.intent.classification", "conversation")
  let description = get_or(elements, "narrative_entry.intent.description", "")
  let domain = get_or(elements, "narrative_entry.intent.domain", "")
  let status = get_or(elements, "narrative_entry.outcome.status", "success")
  let confidence =
    parse_float_or(
      get_or(elements, "narrative_entry.outcome.confidence", "0.5"),
      0.5,
    )
  let assessment = get_or(elements, "narrative_entry.outcome.assessment", "")

  NarrativeEntry(
    schema_version: 1,
    cycle_id: ctx.cycle_id,
    parent_cycle_id: ctx.parent_cycle_id,
    timestamp: get_datetime(),
    entry_type: Narrative,
    summary: summary,
    intent: Intent(
      classification: parse_classification(classification),
      description: description,
      domain: domain,
    ),
    outcome: Outcome(
      status: parse_status(status),
      confidence: confidence,
      assessment: assessment,
    ),
    delegation_chain: extract_delegation_chain(elements),
    decisions: extract_decisions(elements),
    keywords: extract_string_list(elements, "narrative_entry.keywords.keyword"),
    topics: [],
    entities: extract_entities(elements),
    sources: extract_sources(elements),
    thread: None,
    metrics: extract_metrics(elements),
    observations: extract_observations(elements),
    redacted: False,
  )
}

// ---------------------------------------------------------------------------
// Element extraction helpers
// ---------------------------------------------------------------------------

fn get_or(
  elements: Dict(String, String),
  key: String,
  default: String,
) -> String {
  case dict.get(elements, key) {
    Ok(v) -> v
    Error(_) -> default
  }
}

fn parse_float_or(text: String, default: Float) -> Float {
  case float.parse(text) {
    Ok(f) -> f
    Error(_) -> {
      // Try parsing as int and converting
      case int.parse(text) {
        Ok(i) -> int.to_float(i)
        Error(_) -> default
      }
    }
  }
}

fn parse_int_or_zero(text: String) -> Int {
  case int.parse(text) {
    Ok(i) -> i
    Error(_) -> 0
  }
}

fn parse_classification(text: String) -> types.IntentClassification {
  case string.lowercase(text) {
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
}

fn parse_status(text: String) -> types.OutcomeStatus {
  case string.lowercase(text) {
    "partial" -> types.Partial
    "failure" -> Failure
    _ -> Success
  }
}

/// Extract a list of strings from elements. Handles both indexed form
/// (prefix.0, prefix.1, ...) for multiple items and bare form (prefix)
/// for a single item (xmerl only uses indices when count > 1).
fn extract_string_list(
  elements: Dict(String, String),
  prefix: String,
) -> List(String) {
  case xstructor.extract_list(elements, prefix) {
    [] -> {
      // Try bare key for single-element case
      case dict.get(elements, prefix) {
        Ok(v) ->
          case v {
            "" -> []
            _ -> [v]
          }
        Error(_) -> []
      }
    }
    items -> items
  }
}

fn extract_delegation_chain(
  elements: Dict(String, String),
) -> List(types.DelegationStep) {
  extract_indexed_loop(
    elements,
    "narrative_entry.delegation_chain.step",
    0,
    [],
    fn(elems, prefix) {
      types.DelegationStep(
        agent: get_or(elems, prefix <> ".agent", ""),
        agent_id: "",
        agent_human_name: "",
        agent_cycle_id: "",
        instruction: get_or(elems, prefix <> ".instruction", ""),
        outcome: get_or(elems, prefix <> ".outcome", ""),
        contribution: get_or(elems, prefix <> ".contribution", ""),
        tools_used: [],
        sources_accessed: 0,
        input_tokens: 0,
        output_tokens: 0,
        duration_ms: 0,
      )
    },
  )
}

fn extract_decisions(elements: Dict(String, String)) -> List(types.Decision) {
  extract_indexed_loop(
    elements,
    "narrative_entry.decisions.decision",
    0,
    [],
    fn(elems, prefix) {
      types.Decision(
        point: get_or(elems, prefix <> ".point", ""),
        choice: get_or(elems, prefix <> ".choice", ""),
        rationale: get_or(elems, prefix <> ".rationale", ""),
        score: None,
      )
    },
  )
}

fn extract_entities(elements: Dict(String, String)) -> Entities {
  let locations =
    extract_string_list(elements, "narrative_entry.entities.locations.location")
  let organisations =
    extract_string_list(
      elements,
      "narrative_entry.entities.organisations.organisation",
    )
  let data_points =
    extract_indexed_loop(
      elements,
      "narrative_entry.entities.data_points.data_point",
      0,
      [],
      fn(elems, prefix) {
        types.DataPoint(
          label: get_or(elems, prefix <> ".label", ""),
          value: get_or(elems, prefix <> ".value", ""),
          unit: get_or(elems, prefix <> ".unit", ""),
          period: get_or(elems, prefix <> ".period", ""),
          source: get_or(elems, prefix <> ".source", ""),
        )
      },
    )
  let temporal_references =
    extract_string_list(
      elements,
      "narrative_entry.entities.temporal_references.reference",
    )
  Entities(locations:, organisations:, data_points:, temporal_references:)
}

fn extract_sources(elements: Dict(String, String)) -> List(types.Source) {
  extract_indexed_loop(
    elements,
    "narrative_entry.sources.source",
    0,
    [],
    fn(elems, prefix) {
      types.Source(
        source_type: get_or(elems, prefix <> ".type", ""),
        url: None,
        path: None,
        name: get_or(elems, prefix <> ".name", ""),
        accessed_at: None,
        data_date: None,
      )
    },
  )
}

fn extract_metrics(elements: Dict(String, String)) -> types.Metrics {
  Metrics(
    total_duration_ms: parse_int_or_zero(get_or(
      elements,
      "narrative_entry.metrics.total_duration_ms",
      "0",
    )),
    input_tokens: parse_int_or_zero(get_or(
      elements,
      "narrative_entry.metrics.input_tokens",
      "0",
    )),
    output_tokens: parse_int_or_zero(get_or(
      elements,
      "narrative_entry.metrics.output_tokens",
      "0",
    )),
    thinking_tokens: parse_int_or_zero(get_or(
      elements,
      "narrative_entry.metrics.thinking_tokens",
      "0",
    )),
    tool_calls: parse_int_or_zero(get_or(
      elements,
      "narrative_entry.metrics.tool_calls",
      "0",
    )),
    agent_delegations: parse_int_or_zero(get_or(
      elements,
      "narrative_entry.metrics.agent_delegations",
      "0",
    )),
    dprime_evaluations: parse_int_or_zero(get_or(
      elements,
      "narrative_entry.metrics.dprime_evaluations",
      "0",
    )),
    model_used: get_or(elements, "narrative_entry.metrics.model_used", ""),
  )
}

fn extract_observations(
  elements: Dict(String, String),
) -> List(types.Observation) {
  extract_indexed_loop(
    elements,
    "narrative_entry.observations.observation",
    0,
    [],
    fn(elems, prefix) {
      let severity_str = get_or(elems, prefix <> ".severity", "info")
      let severity = case severity_str {
        "warning" -> types.Warning
        "error" -> types.ErrorSeverity
        _ -> types.Info
      }
      types.Observation(
        observation_type: get_or(elems, prefix <> ".type", ""),
        severity: severity,
        detail: get_or(elems, prefix <> ".detail", ""),
      )
    },
  )
}

/// Generic indexed loop for extracting repeated complex elements.
/// The xmerl FFI only uses numeric indexing (prefix.0, prefix.1, ...) when
/// there are multiple children with the same name. A single child uses the
/// bare path (prefix.child) with no index. This function checks both forms.
fn extract_indexed_loop(
  elements: Dict(String, String),
  prefix: String,
  idx: Int,
  acc: List(a),
  extractor: fn(Dict(String, String), String) -> a,
) -> List(a) {
  let indexed_prefix = prefix <> "." <> int.to_string(idx)
  // Check if any key starts with the indexed prefix (e.g. prefix.0.child)
  let has_indexed =
    dict.keys(elements)
    |> list.any(fn(k) { string.starts_with(k, indexed_prefix) })
  case has_indexed {
    True -> {
      let item = extractor(elements, indexed_prefix)
      extract_indexed_loop(elements, prefix, idx + 1, [item, ..acc], extractor)
    }
    False -> {
      // If idx == 0 and no indexed keys found, check for bare (non-indexed) prefix.
      // This handles the single-element case where xmerl doesn't add indices.
      case idx == 0 {
        True -> {
          let has_bare =
            dict.keys(elements)
            |> list.any(fn(k) {
              string.starts_with(k, prefix <> ".") && !is_indexed_key(k, prefix)
            })
          case has_bare {
            True -> {
              let item = extractor(elements, prefix)
              [item]
            }
            False -> list.reverse(acc)
          }
        }
        False -> list.reverse(acc)
      }
    }
  }
}

/// Check if a key after the prefix starts with a digit (indicating indexing).
fn is_indexed_key(key: String, prefix: String) -> Bool {
  let after = string.drop_start(key, string.length(prefix) + 1)
  case string.first(after) {
    Ok("0")
    | Ok("1")
    | Ok("2")
    | Ok("3")
    | Ok("4")
    | Ok("5")
    | Ok("6")
    | Ok("7")
    | Ok("8")
    | Ok("9") -> True
    _ -> False
  }
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
  let schema_dir = paths.schemas_dir()
  case
    xstructor.compile_schema(schema_dir, "cbr_case.xsd", schemas.cbr_case_xsd)
  {
    Error(e) -> {
      slog.warn(
        "narrative/archivist",
        "generate_cbr",
        "CBR schema compile failed: " <> e,
        Some(ctx.cycle_id),
      )
      None
    }
    Ok(schema) -> {
      let system =
        schemas.build_system_prompt(
          cbr_system_prompt_base(),
          schemas.cbr_case_xsd,
          schemas.cbr_case_example,
        )
      let config =
        xstructor.XStructorConfig(
          schema: schema,
          system_prompt: system,
          xml_example: schemas.cbr_case_example,
          max_retries: 3,
          max_tokens: 1024,
        )
      case xstructor.generate(config, prompt, provider, model) {
        Ok(result) -> {
          slog.info(
            "narrative/archivist",
            "generate_cbr",
            "Generated CBR case for cycle " <> ctx.cycle_id,
            Some(ctx.cycle_id),
          )
          Some(extract_cbr_case(result.elements, ctx, entry))
        }
        Error(e) -> {
          slog.warn(
            "narrative/archivist",
            "generate_cbr",
            "CBR XStructor generation failed: " <> string.slice(e, 0, 200),
            Some(ctx.cycle_id),
          )
          None
        }
      }
    }
  }
}

fn cbr_system_prompt_base() -> String {
  "You are the Archivist extracting a Case-Based Reasoning record from a completed cognitive cycle. Your goal is to produce a structured problem/solution/outcome record optimised for future retrieval.

RULES:
- Focus on retrievability: use clear, specific terms in problem descriptors
- Capture the approach, not just the result
- Document pitfalls and what went wrong"
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

// ---------------------------------------------------------------------------
// Extract CbrCase from XStructor elements dict
// ---------------------------------------------------------------------------

fn extract_cbr_case(
  elements: Dict(String, String),
  ctx: ArchivistContext,
  entry: NarrativeEntry,
) -> cbr_types.CbrCase {
  let problem =
    cbr_types.CbrProblem(
      user_input: get_or(elements, "cbr_case.problem.user_input", ""),
      intent: get_or(elements, "cbr_case.problem.intent", ""),
      domain: get_or(elements, "cbr_case.problem.domain", ""),
      entities: extract_string_list(
        elements,
        "cbr_case.problem.entities.entity",
      ),
      keywords: extract_string_list(
        elements,
        "cbr_case.problem.keywords.keyword",
      ),
      query_complexity: get_or(
        elements,
        "cbr_case.problem.query_complexity",
        "simple",
      ),
    )
  let solution =
    cbr_types.CbrSolution(
      approach: get_or(elements, "cbr_case.solution.approach", ""),
      agents_used: extract_string_list(
        elements,
        "cbr_case.solution.agents_used.agent",
      ),
      tools_used: extract_string_list(
        elements,
        "cbr_case.solution.tools_used.tool",
      ),
      steps: extract_string_list(elements, "cbr_case.solution.steps.step"),
    )
  let outcome =
    cbr_types.CbrOutcome(
      status: get_or(elements, "cbr_case.outcome.status", "success"),
      confidence: parse_float_or(
        get_or(elements, "cbr_case.outcome.confidence", "0.5"),
        0.5,
      ),
      assessment: get_or(elements, "cbr_case.outcome.assessment", ""),
      pitfalls: extract_string_list(
        elements,
        "cbr_case.outcome.pitfalls.pitfall",
      ),
    )
  cbr_types.CbrCase(
    case_id: ctx.cycle_id,
    timestamp: entry.timestamp,
    schema_version: 1,
    problem: problem,
    solution: solution,
    outcome: outcome,
    source_narrative_id: ctx.cycle_id,
    profile: None,
    redacted: False,
  )
}

// ---------------------------------------------------------------------------
// Fallback entry
// ---------------------------------------------------------------------------

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
    redacted: False,
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
