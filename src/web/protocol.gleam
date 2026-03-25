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

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import llm/types.{type Usage, Usage}
import slog

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

pub fn encode_server_message(msg: ServerMessage) -> String {
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
