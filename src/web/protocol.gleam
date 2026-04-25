//// WebSocket JSON protocol for the web chat GUI.
////
//// Client → Server:
////   { "type": "user_message", "text": "..." }
////   { "type": "user_answer", "text": "..." }
////
//// Server → Client:
////   { "type": "assistant_message", "text": "...", "model": "...", "usage": { "input": N, "output": N } }
////   { "type": "thinking" }
////   { "type": "question", "text": "...", "source": "cognitive" | "agent:NAME" }
////   { "type": "notification", "kind": "tool_calling", "name": "..." }
////   { "type": "notification", "kind": "save_warning", "message": "..." }

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/types.{type Usage, Usage}
import slog

/// Monotonic positive integer — tagged onto every outbound ServerMessage
/// JSON as a `seq` field so the client can detect reordering / gaps.
@external(erlang, "springdrift_ffi", "monotonic_seq")
fn monotonic_seq() -> Int

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type ClientMessage {
  UserMessage(text: String)
  UserAnswer(text: String)
  RequestLogData
  RequestRewind(index: Int)
  RequestNarrativeData
  RequestSchedulerData
  RequestSchedulerCycles
  RequestPlannerData
  RequestDprimeData
  RequestDprimeConfig
  RequestCommsData
  RequestAffectData
  /// List of dated JSONL files in the narrative dir, each with cycle
  /// counts + last activity. Drives the chat-history sidebar.
  RequestHistoryIndex
  /// Load all narrative entries for a given YYYY-MM-DD date. Drives
  /// the read-only day view in the chat-history sidebar.
  RequestHistoryDay(date: String)
  /// Load raw user/assistant message pairs for a given YYYY-MM-DD date.
  /// Reads from the cycle log directly — the actual chat, not the
  /// Archivist's narrative summary.
  RequestChatHistoryDay(date: String)
  /// Read-only skills audit panel — discover skills, read per-skill
  /// metrics, load recent proposal-log events.
  RequestSkillsData
  /// Read-only memory tab — list Remembrancer consolidation runs from
  /// .springdrift/memory/consolidation/. Drives the admin Memory tab.
  RequestMemoryData
  /// List all documents in the knowledge library. Drives the
  /// Documents tab's main list view.
  RequestDocumentList
  /// Load a single document's tree + metadata for the section viewer.
  RequestDocumentView(doc_id: String)
  /// Search the library. Mode is "keyword" / "embedding" / "reasoning";
  /// include_pending opts in to Promoted (un-approved) exports.
  RequestSearchLibrary(query: String, mode: String, include_pending: Bool)
  /// Operator approves a Promoted export. note is optional context.
  RequestApproveExport(slug: String, note: String)
  /// Operator rejects a Promoted export. reason is required.
  RequestRejectExport(slug: String, reason: String)
}

pub type ServerMessage {
  AssistantMessage(text: String, model: String, usage: Option(Usage))
  Thinking
  Question(text: String, source: String)
  ToolNotification(name: String)
  SaveNotification(message: String)
  SafetyNotification(decision: String, score: Float, explanation: String)
  QueueNotification(position: Int, queue_size: Int)
  QueueFullNotification(queue_cap: Int)
  LogData(entries: List(slog.LogEntry))
  NarrativeData(entries_json: String)
  SchedulerData(jobs_json: String)
  SchedulerCyclesData(cycles_json: String)
  PlannerData(tasks_json: String, endeavours_json: String)
  DprimeData(gates_json: String)
  DprimeConfigData(config_json: String)
  SessionHistory(messages_json: String)
  CommsData(messages_json: String)
  AffectData(snapshots_json: String)
  /// Live progress update from a delegated agent — emitted every react turn.
  /// Surfaces in the chat tab's status strip so the operator sees what's
  /// actually happening instead of an opaque "thinking" spinner.
  AgentProgressNotification(
    agent_name: String,
    turn: Int,
    max_turns: Int,
    tokens: Int,
    current_tool: Option(String),
    elapsed_ms: Int,
  )
  /// Cognitive loop status transition. Drives the status strip's label and
  /// the inline status bubble's step list.
  /// status: "idle" | "thinking" | "classifying" | "waiting_for_agents"
  ///       | "waiting_for_user" | "evaluating_safety"
  StatusTransition(status: String, detail: Option(String))
  /// Per-cycle affect snapshot, fans out to the web UI once per cycle.
  /// Drives the ambient background: hue from pressure, saturation from
  /// calm, opacity from confidence, breathing rhythm from status.
  AffectTick(
    desperation: Float,
    calm: Float,
    confidence: Float,
    frustration: Float,
    pressure: Float,
    trend: String,
    status: String,
  )
  /// Day-grouped list of past conversations. One entry per day that
  /// has a narrative JSONL file, newest first.
  HistoryIndex(days_json: String)
  /// Full narrative entries for a specific day, chronological order.
  HistoryDay(date: String, entries_json: String)
  /// Raw user/assistant chat pairs for a specific day, chronological order.
  /// Each pair: {timestamp, user_text, assistant_text}.
  ChatHistoryDay(date: String, pairs_json: String)
  /// Skills audit data — every discovered skill with metadata, usage
  /// counts, last-used timestamp, and proposal-log events.
  SkillsData(skills_json: String, log_json: String)
  /// Memory tab data — Remembrancer consolidation runs (date, period,
  /// counts, report path) for read-only audit.
  MemoryData(runs_json: String)
  /// Documents tab — list of all docs with metadata.
  DocumentListData(documents_json: String)
  /// Documents tab — single doc's tree + metadata for section viewer.
  DocumentViewData(doc_id: String, document_json: String)
  /// Documents tab — search results with citation strings.
  SearchResultsData(query: String, results_json: String)
  /// Documents tab — toast feedback for approve/reject actions.
  /// status: "ok" | "error". slug + message for display.
  ApprovalResult(slug: String, status: String, message: String)
}

pub type CycleDataJson {
  CycleDataJson(
    cycle_id: String,
    timestamp: String,
    human_input: String,
    tool_names: List(String),
    response_text: String,
    input_tokens: Int,
    output_tokens: Int,
    thinking_tokens: Int,
    complexity: String,
  )
}

// ---------------------------------------------------------------------------
// Decode (client → server)
// ---------------------------------------------------------------------------

pub fn decode_client_message(json_string: String) -> Result(ClientMessage, Nil) {
  let decoder = {
    use type_str <- decode.field("type", decode.string)
    case type_str {
      "user_message" -> {
        use text <- decode.field("text", decode.string)
        decode.success(UserMessage(text:))
      }
      "user_answer" -> {
        use text <- decode.field("text", decode.string)
        decode.success(UserAnswer(text:))
      }
      "request_log_data" -> decode.success(RequestLogData)
      "request_rewind" -> {
        use index <- decode.field("index", decode.int)
        decode.success(RequestRewind(index:))
      }
      "request_narrative_data" -> decode.success(RequestNarrativeData)
      "request_scheduler_data" -> decode.success(RequestSchedulerData)
      "request_scheduler_cycles" -> decode.success(RequestSchedulerCycles)
      "request_planner_data" -> decode.success(RequestPlannerData)
      "request_dprime_data" -> decode.success(RequestDprimeData)
      "request_dprime_config" -> decode.success(RequestDprimeConfig)
      "request_comms_data" -> decode.success(RequestCommsData)
      "request_affect_data" -> decode.success(RequestAffectData)
      "request_history_index" -> decode.success(RequestHistoryIndex)
      "request_history_day" -> {
        use date <- decode.field("date", decode.string)
        decode.success(RequestHistoryDay(date:))
      }
      "request_chat_history_day" -> {
        use date <- decode.field("date", decode.string)
        decode.success(RequestChatHistoryDay(date:))
      }
      "request_skills_data" -> decode.success(RequestSkillsData)
      "request_memory_data" -> decode.success(RequestMemoryData)
      "request_document_list" -> decode.success(RequestDocumentList)
      "request_document_view" -> {
        use doc_id <- decode.field("doc_id", decode.string)
        decode.success(RequestDocumentView(doc_id:))
      }
      "request_search_library" -> {
        use query <- decode.field("query", decode.string)
        use mode <- decode.optional_field("mode", "embedding", decode.string)
        use include_pending <- decode.optional_field(
          "include_pending",
          False,
          decode.bool,
        )
        decode.success(RequestSearchLibrary(query:, mode:, include_pending:))
      }
      "request_approve_export" -> {
        use slug <- decode.field("slug", decode.string)
        use note <- decode.optional_field("note", "", decode.string)
        decode.success(RequestApproveExport(slug:, note:))
      }
      "request_reject_export" -> {
        use slug <- decode.field("slug", decode.string)
        use reason <- decode.field("reason", decode.string)
        decode.success(RequestRejectExport(slug:, reason:))
      }
      _ -> decode.failure(UserMessage(""), "Unknown client message type")
    }
  }
  case json.parse(json_string, decoder) {
    Ok(msg) -> Ok(msg)
    Error(_) -> Error(Nil)
  }
}

// ---------------------------------------------------------------------------
// Encode (server → client)
// ---------------------------------------------------------------------------

/// Encode a server message as JSON with a monotonic `seq` field injected
/// as the first key. The seq is a per-node monotonic integer so a client
/// can detect reordering or gaps in delivered frames.
pub fn encode_server_message(msg: ServerMessage) -> String {
  with_seq(encode_body(msg))
}

/// Inject a `"seq": N,` field at the start of the JSON object. All body
/// encoders produce an object starting with `{` — we splice between the
/// `{` and the first existing field so the resulting JSON stays valid.
fn with_seq(body: String) -> String {
  "{\"seq\":"
  <> int.to_string(monotonic_seq())
  <> ","
  <> string.drop_start(body, 1)
}

fn encode_body(msg: ServerMessage) -> String {
  case msg {
    AssistantMessage(text:, model:, usage:) ->
      json.object([
        #("type", json.string("assistant_message")),
        #("text", json.string(text)),
        #("model", json.string(model)),
        #("usage", encode_usage(usage)),
      ])
      |> json.to_string

    Thinking ->
      json.object([#("type", json.string("thinking"))])
      |> json.to_string

    Question(text:, source:) ->
      json.object([
        #("type", json.string("question")),
        #("text", json.string(text)),
        #("source", json.string(source)),
      ])
      |> json.to_string

    ToolNotification(name:) ->
      json.object([
        #("type", json.string("notification")),
        #("kind", json.string("tool_calling")),
        #("name", json.string(name)),
      ])
      |> json.to_string

    SaveNotification(message:) ->
      json.object([
        #("type", json.string("notification")),
        #("kind", json.string("save_warning")),
        #("message", json.string(message)),
      ])
      |> json.to_string

    SafetyNotification(decision:, score:, explanation:) ->
      json.object([
        #("type", json.string("notification")),
        #("kind", json.string("safety")),
        #("decision", json.string(decision)),
        #("score", json.float(score)),
        #("explanation", json.string(explanation)),
      ])
      |> json.to_string

    QueueNotification(position:, queue_size:) ->
      json.object([
        #("type", json.string("notification")),
        #("kind", json.string("input_queued")),
        #("position", json.int(position)),
        #("queue_size", json.int(queue_size)),
      ])
      |> json.to_string

    QueueFullNotification(queue_cap:) ->
      json.object([
        #("type", json.string("notification")),
        #("kind", json.string("queue_full")),
        #("queue_cap", json.int(queue_cap)),
      ])
      |> json.to_string

    LogData(entries:) ->
      json.object([
        #("type", json.string("log_data")),
        #(
          "entries",
          json.array(entries, fn(entry) {
            json.object([
              #("timestamp", json.string(entry.timestamp)),
              #("level", json.string(slog.level_to_string(entry.level))),
              #("module", json.string(entry.module)),
              #("function", json.string(entry.function)),
              #("message", json.string(entry.message)),
              #("cycle_id", case entry.cycle_id {
                None -> json.null()
                Some(id) -> json.string(id)
              }),
            ])
          }),
        ),
      ])
      |> json.to_string

    NarrativeData(entries_json:) ->
      "{\"type\":\"narrative_data\",\"entries\":" <> entries_json <> "}"

    SchedulerData(jobs_json:) ->
      "{\"type\":\"scheduler_data\",\"jobs\":" <> jobs_json <> "}"

    SchedulerCyclesData(cycles_json:) ->
      "{\"type\":\"scheduler_cycles_data\",\"cycles\":" <> cycles_json <> "}"

    PlannerData(tasks_json:, endeavours_json:) ->
      "{\"type\":\"planner_data\",\"tasks\":"
      <> tasks_json
      <> ",\"endeavours\":"
      <> endeavours_json
      <> "}"

    DprimeData(gates_json:) ->
      "{\"type\":\"dprime_data\",\"gates\":" <> gates_json <> "}"

    DprimeConfigData(config_json:) ->
      "{\"type\":\"dprime_config_data\",\"config\":" <> config_json <> "}"

    SessionHistory(messages_json:) ->
      "{\"type\":\"session_history\",\"messages\":" <> messages_json <> "}"
    CommsData(messages_json:) ->
      "{\"type\":\"comms_data\",\"messages\":" <> messages_json <> "}"
    AffectData(snapshots_json:) ->
      "{\"type\":\"affect_data\",\"snapshots\":" <> snapshots_json <> "}"

    AgentProgressNotification(
      agent_name:,
      turn:,
      max_turns:,
      tokens:,
      current_tool:,
      elapsed_ms:,
    ) ->
      json.object([
        #("type", json.string("notification")),
        #("kind", json.string("agent_progress")),
        #("agent_name", json.string(agent_name)),
        #("turn", json.int(turn)),
        #("max_turns", json.int(max_turns)),
        #("tokens", json.int(tokens)),
        #("current_tool", case current_tool {
          None -> json.null()
          Some(t) -> json.string(t)
        }),
        #("elapsed_ms", json.int(elapsed_ms)),
      ])
      |> json.to_string

    StatusTransition(status:, detail:) ->
      json.object([
        #("type", json.string("notification")),
        #("kind", json.string("status_transition")),
        #("status", json.string(status)),
        #("detail", case detail {
          None -> json.null()
          Some(d) -> json.string(d)
        }),
      ])
      |> json.to_string

    AffectTick(
      desperation:,
      calm:,
      confidence:,
      frustration:,
      pressure:,
      trend:,
      status:,
    ) ->
      json.object([
        #("type", json.string("notification")),
        #("kind", json.string("affect_tick")),
        #("desperation", json.float(desperation)),
        #("calm", json.float(calm)),
        #("confidence", json.float(confidence)),
        #("frustration", json.float(frustration)),
        #("pressure", json.float(pressure)),
        #("trend", json.string(trend)),
        #("status", json.string(status)),
      ])
      |> json.to_string

    HistoryIndex(days_json:) ->
      "{\"type\":\"history_index\",\"days\":" <> days_json <> "}"

    HistoryDay(date:, entries_json:) ->
      "{\"type\":\"history_day\",\"date\":\""
      <> date
      <> "\",\"entries\":"
      <> entries_json
      <> "}"

    ChatHistoryDay(date:, pairs_json:) ->
      "{\"type\":\"chat_history_day\",\"date\":\""
      <> date
      <> "\",\"pairs\":"
      <> pairs_json
      <> "}"
    SkillsData(skills_json:, log_json:) ->
      "{\"type\":\"skills_data\",\"skills\":"
      <> skills_json
      <> ",\"log\":"
      <> log_json
      <> "}"
    MemoryData(runs_json:) ->
      "{\"type\":\"memory_data\",\"runs\":" <> runs_json <> "}"

    DocumentListData(documents_json:) ->
      "{\"type\":\"document_list_data\",\"documents\":" <> documents_json <> "}"

    DocumentViewData(doc_id:, document_json:) ->
      "{\"type\":\"document_view_data\",\"doc_id\":"
      <> json.to_string(json.string(doc_id))
      <> ",\"document\":"
      <> document_json
      <> "}"

    SearchResultsData(query:, results_json:) ->
      "{\"type\":\"search_results_data\",\"query\":"
      <> json.to_string(json.string(query))
      <> ",\"results\":"
      <> results_json
      <> "}"

    ApprovalResult(slug:, status:, message:) ->
      json.object([
        #("type", json.string("approval_result")),
        #("slug", json.string(slug)),
        #("status", json.string(status)),
        #("message", json.string(message)),
      ])
      |> json.to_string
  }
}

fn encode_usage(usage: Option(Usage)) -> json.Json {
  case usage {
    None -> json.null()
    Some(Usage(input_tokens:, output_tokens:, ..)) ->
      json.object([
        #("input", json.int(input_tokens)),
        #("output", json.int(output_tokens)),
      ])
  }
}

// ---------------------------------------------------------------------------
// Helpers for building source strings
// ---------------------------------------------------------------------------

pub fn cognitive_source() -> String {
  "cognitive"
}

pub fn agent_source(name: String) -> String {
  "agent:" <> name
}

// ---------------------------------------------------------------------------
// Parse source string back to components (for display)
// ---------------------------------------------------------------------------

pub fn parse_source(source: String) -> String {
  case source {
    "cognitive" -> "Cognitive"
    "agent:" <> name -> name
    other -> other
  }
}

// ---------------------------------------------------------------------------
// Format usage for display
// ---------------------------------------------------------------------------

pub fn format_usage(usage: Option(Usage)) -> String {
  case usage {
    None -> ""
    Some(Usage(input_tokens:, output_tokens:, ..)) ->
      int.to_string(input_tokens)
      <> " in / "
      <> int.to_string(output_tokens)
      <> " out"
  }
}
