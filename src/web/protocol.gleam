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

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type ClientMessage {
  UserMessage(text: String)
  UserAnswer(text: String)
}

pub type ServerMessage {
  AssistantMessage(text: String, model: String, usage: Option(Usage))
  Thinking
  Question(text: String, source: String)
  ToolNotification(name: String)
  SaveNotification(message: String)
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
