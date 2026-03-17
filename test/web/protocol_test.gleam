import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import llm/types.{Usage}
import slog
import web/protocol

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// decode_client_message
// ---------------------------------------------------------------------------

pub fn decode_user_message_test() {
  let json = "{\"type\": \"user_message\", \"text\": \"hello\"}"
  let result = protocol.decode_client_message(json)
  result |> should.be_ok
  let assert Ok(protocol.UserMessage(text:)) = result
  text |> should.equal("hello")
}

pub fn decode_user_answer_test() {
  let json = "{\"type\": \"user_answer\", \"text\": \"yes\"}"
  let result = protocol.decode_client_message(json)
  result |> should.be_ok
  let assert Ok(protocol.UserAnswer(text:)) = result
  text |> should.equal("yes")
}

pub fn decode_unknown_type_returns_error_test() {
  let json = "{\"type\": \"unknown\", \"text\": \"foo\"}"
  protocol.decode_client_message(json) |> should.be_error
}

pub fn decode_invalid_json_returns_error_test() {
  protocol.decode_client_message("not json") |> should.be_error
}

pub fn decode_missing_text_returns_error_test() {
  let json = "{\"type\": \"user_message\"}"
  protocol.decode_client_message(json) |> should.be_error
}

// ---------------------------------------------------------------------------
// encode_server_message — AssistantMessage
// ---------------------------------------------------------------------------

pub fn encode_assistant_message_with_usage_test() {
  let msg =
    protocol.AssistantMessage(
      text: "hi",
      model: "test-model",
      usage: Some(Usage(input_tokens: 10, output_tokens: 20, thinking_tokens: 0)),
    )
  let json_str = protocol.encode_server_message(msg)
  // Round-trip: the JSON string should contain the expected fields
  json_str |> should_contain("\"type\":\"assistant_message\"")
  json_str |> should_contain("\"text\":\"hi\"")
  json_str |> should_contain("\"model\":\"test-model\"")
  json_str |> should_contain("\"input\":10")
  json_str |> should_contain("\"output\":20")
}

pub fn encode_assistant_message_no_usage_test() {
  let msg = protocol.AssistantMessage(text: "hi", model: "m", usage: None)
  let json_str = protocol.encode_server_message(msg)
  json_str |> should_contain("\"type\":\"assistant_message\"")
  json_str |> should_contain("\"usage\":null")
}

// ---------------------------------------------------------------------------
// encode_server_message — Thinking
// ---------------------------------------------------------------------------

pub fn encode_thinking_test() {
  let json_str = protocol.encode_server_message(protocol.Thinking)
  json_str |> should_contain("\"type\":\"thinking\"")
}

// ---------------------------------------------------------------------------
// encode_server_message — Question
// ---------------------------------------------------------------------------

pub fn encode_question_cognitive_test() {
  let msg = protocol.Question(text: "What do you want?", source: "cognitive")
  let json_str = protocol.encode_server_message(msg)
  json_str |> should_contain("\"type\":\"question\"")
  json_str |> should_contain("\"source\":\"cognitive\"")
}

pub fn encode_question_agent_test() {
  let msg =
    protocol.Question(text: "Need more info", source: "agent:researcher")
  let json_str = protocol.encode_server_message(msg)
  json_str |> should_contain("\"source\":\"agent:researcher\"")
}

// ---------------------------------------------------------------------------
// encode_server_message — Notifications
// ---------------------------------------------------------------------------

pub fn encode_tool_notification_test() {
  let msg = protocol.ToolNotification(name: "read_file")
  let json_str = protocol.encode_server_message(msg)
  json_str |> should_contain("\"kind\":\"tool_calling\"")
  json_str |> should_contain("\"name\":\"read_file\"")
}

pub fn encode_save_notification_test() {
  let msg = protocol.SaveNotification(message: "Save failed")
  let json_str = protocol.encode_server_message(msg)
  json_str |> should_contain("\"kind\":\"save_warning\"")
  json_str |> should_contain("\"message\":\"Save failed\"")
}

// ---------------------------------------------------------------------------
// Source helpers
// ---------------------------------------------------------------------------

pub fn cognitive_source_test() {
  protocol.cognitive_source() |> should.equal("cognitive")
}

pub fn agent_source_test() {
  protocol.agent_source("coder") |> should.equal("agent:coder")
}

pub fn parse_source_cognitive_test() {
  protocol.parse_source("cognitive") |> should.equal("Cognitive")
}

pub fn parse_source_agent_test() {
  protocol.parse_source("agent:researcher") |> should.equal("researcher")
}

pub fn parse_source_unknown_test() {
  protocol.parse_source("other") |> should.equal("other")
}

// ---------------------------------------------------------------------------
// format_usage
// ---------------------------------------------------------------------------

pub fn format_usage_some_test() {
  let usage =
    Some(Usage(input_tokens: 100, output_tokens: 50, thinking_tokens: 0))
  protocol.format_usage(usage) |> should.equal("100 in / 50 out")
}

pub fn format_usage_none_test() {
  protocol.format_usage(None) |> should.equal("")
}

// ---------------------------------------------------------------------------
// decode_client_message — RequestLogData / RequestRewind
// ---------------------------------------------------------------------------

pub fn decode_request_log_data_test() {
  let json = "{\"type\": \"request_log_data\"}"
  let result = protocol.decode_client_message(json)
  result |> should.be_ok
  let assert Ok(protocol.RequestLogData) = result
}

pub fn decode_request_rewind_test() {
  let json = "{\"type\": \"request_rewind\", \"index\": 3}"
  let result = protocol.decode_client_message(json)
  result |> should.be_ok
  let assert Ok(protocol.RequestRewind(index:)) = result
  index |> should.equal(3)
}

// ---------------------------------------------------------------------------
// encode_server_message — LogData
// ---------------------------------------------------------------------------

pub fn encode_log_data_test() {
  let entries = [
    slog.LogEntry(
      timestamp: "2026-03-05T10:30:00",
      level: slog.Info,
      module: "test",
      function: "fn",
      message: "hello",
      cycle_id: Some("abc-123"),
    ),
  ]
  let msg = protocol.LogData(entries:)
  let json_str = protocol.encode_server_message(msg)
  json_str |> should_contain("\"type\":\"log_data\"")
  json_str |> should_contain("\"entries\":")
  json_str |> should_contain("\"module\":\"test\"")
  json_str |> should_contain("\"level\":\"info\"")
}

pub fn encode_log_data_empty_test() {
  let msg = protocol.LogData(entries: [])
  let json_str = protocol.encode_server_message(msg)
  json_str |> should_contain("\"type\":\"log_data\"")
  json_str |> should_contain("\"entries\":[]")
}

// ---------------------------------------------------------------------------
// decode_client_message — Scheduler messages
// ---------------------------------------------------------------------------

pub fn decode_request_scheduler_data_test() {
  let json = "{\"type\": \"request_scheduler_data\"}"
  let result = protocol.decode_client_message(json)
  result |> should.be_ok
  let assert Ok(protocol.RequestSchedulerData) = result
}

pub fn decode_request_scheduler_cycles_test() {
  let json = "{\"type\": \"request_scheduler_cycles\"}"
  let result = protocol.decode_client_message(json)
  result |> should.be_ok
  let assert Ok(protocol.RequestSchedulerCycles) = result
}

// ---------------------------------------------------------------------------
// encode_server_message — Scheduler messages
// ---------------------------------------------------------------------------

pub fn encode_scheduler_data_test() {
  let msg = protocol.SchedulerData(jobs_json: "[{\"name\":\"test\"}]")
  let json_str = protocol.encode_server_message(msg)
  json_str |> should_contain("\"type\":\"scheduler_data\"")
  json_str |> should_contain("\"jobs\":[{\"name\":\"test\"}]")
}

pub fn encode_scheduler_cycles_data_test() {
  let msg = protocol.SchedulerCyclesData(cycles_json: "[]")
  let json_str = protocol.encode_server_message(msg)
  json_str |> should_contain("\"type\":\"scheduler_cycles_data\"")
  json_str |> should_contain("\"cycles\":[]")
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

import gleam/string

fn should_contain(haystack: String, needle: String) -> Nil {
  string.contains(haystack, needle) |> should.be_true
}
