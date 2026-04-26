// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

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
  let assert Ok(protocol.UserMessage(text:, client_msg_id:, attachments:)) =
    result
  text |> should.equal("hello")
  // Legacy-shape message — no client_msg_id supplied.
  client_msg_id |> should.equal(None)
  // Legacy-shape message — no attachments supplied, defaults to empty list.
  attachments |> should.equal([])
}

pub fn decode_user_message_with_client_msg_id_test() {
  let json =
    "{\"type\": \"user_message\", \"text\": \"hi\", \"client_msg_id\": \"abc-123\"}"
  let result = protocol.decode_client_message(json)
  result |> should.be_ok
  let assert Ok(protocol.UserMessage(text:, client_msg_id:, attachments:)) =
    result
  text |> should.equal("hi")
  client_msg_id |> should.equal(Some("abc-123"))
  attachments |> should.equal([])
}

pub fn decode_user_message_with_attachments_test() {
  let json =
    "{\"type\":\"user_message\",\"text\":\"see attached\",\"attachments\":["
    <> "{\"filename\":\"notes.pdf\",\"doc_id\":\"doc-abc\",\"slug\":\"notes\",\"title\":\"Notes\"}"
    <> "]}"
  let result = protocol.decode_client_message(json)
  result |> should.be_ok
  let assert Ok(protocol.UserMessage(text:, client_msg_id: _, attachments:)) =
    result
  text |> should.equal("see attached")
  let assert [att] = attachments
  att.filename |> should.equal("notes.pdf")
  att.doc_id |> should.equal("doc-abc")
  att.slug |> should.equal("notes")
  att.title |> should.equal("Notes")
}

pub fn decode_user_message_attachment_title_optional_test() {
  // title is optional in the attachment decoder — older clients or
  // partially-processed uploads may omit it.
  let json =
    "{\"type\":\"user_message\",\"text\":\"x\",\"attachments\":["
    <> "{\"filename\":\"a.txt\",\"doc_id\":\"d\",\"slug\":\"a\"}"
    <> "]}"
  let result = protocol.decode_client_message(json)
  result |> should.be_ok
  let assert Ok(protocol.UserMessage(attachments:, ..)) = result
  let assert [att] = attachments
  att.title |> should.equal("")
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
      usage: Some(Usage(
        input_tokens: 10,
        output_tokens: 20,
        thinking_tokens: 0,
        cache_creation_tokens: 0,
        cache_read_tokens: 0,
      )),
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

pub fn encode_agent_progress_notification_test() {
  let msg =
    protocol.AgentProgressNotification(
      agent_name: "researcher",
      turn: 2,
      max_turns: 8,
      tokens: 4200,
      current_tool: Some("brave_answer"),
      elapsed_ms: 12_400,
    )
  let json_str = protocol.encode_server_message(msg)
  json_str |> should_contain("\"kind\":\"agent_progress\"")
  json_str |> should_contain("\"agent_name\":\"researcher\"")
  json_str |> should_contain("\"turn\":2")
  json_str |> should_contain("\"max_turns\":8")
  json_str |> should_contain("\"tokens\":4200")
  json_str |> should_contain("\"current_tool\":\"brave_answer\"")
  json_str |> should_contain("\"elapsed_ms\":12400")
}

pub fn encode_agent_progress_notification_no_tool_test() {
  let msg =
    protocol.AgentProgressNotification(
      agent_name: "writer",
      turn: 1,
      max_turns: 5,
      tokens: 800,
      current_tool: None,
      elapsed_ms: 2100,
    )
  let json_str = protocol.encode_server_message(msg)
  json_str |> should_contain("\"current_tool\":null")
}

pub fn encode_status_transition_test() {
  let msg =
    protocol.StatusTransition(status: "thinking", detail: Some("claude-haiku"))
  let json_str = protocol.encode_server_message(msg)
  json_str |> should_contain("\"kind\":\"status_transition\"")
  json_str |> should_contain("\"status\":\"thinking\"")
  json_str |> should_contain("\"detail\":\"claude-haiku\"")
}

pub fn encode_status_transition_no_detail_test() {
  let msg = protocol.StatusTransition(status: "idle", detail: None)
  let json_str = protocol.encode_server_message(msg)
  json_str |> should_contain("\"status\":\"idle\"")
  json_str |> should_contain("\"detail\":null")
}

pub fn encode_affect_tick_test() {
  let msg =
    protocol.AffectTick(
      desperation: 12.5,
      calm: 72.0,
      confidence: 65.5,
      frustration: 18.0,
      pressure: 35.0,
      trend: "rising",
      status: "thinking",
    )
  let json_str = protocol.encode_server_message(msg)
  json_str |> should_contain("\"kind\":\"affect_tick\"")
  json_str |> should_contain("\"desperation\":12.5")
  json_str |> should_contain("\"calm\":72.0")
  json_str |> should_contain("\"confidence\":65.5")
  json_str |> should_contain("\"frustration\":18.0")
  json_str |> should_contain("\"pressure\":35.0")
  json_str |> should_contain("\"trend\":\"rising\"")
  json_str |> should_contain("\"status\":\"thinking\"")
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
    Some(Usage(
      input_tokens: 100,
      output_tokens: 50,
      thinking_tokens: 0,
      cache_creation_tokens: 0,
      cache_read_tokens: 0,
    ))
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
// decode_client_message — Documents tab messages (PR 8)
// ---------------------------------------------------------------------------

pub fn decode_request_document_list_test() {
  let json = "{\"type\": \"request_document_list\"}"
  let result = protocol.decode_client_message(json)
  result |> should.be_ok
  let assert Ok(protocol.RequestDocumentList) = result
}

pub fn decode_request_document_view_test() {
  let json = "{\"type\": \"request_document_view\", \"doc_id\": \"doc-123\"}"
  let result = protocol.decode_client_message(json)
  result |> should.be_ok
  let assert Ok(protocol.RequestDocumentView(doc_id:)) = result
  doc_id |> should.equal("doc-123")
}

pub fn decode_request_search_library_full_test() {
  let json =
    "{\"type\": \"request_search_library\", \"query\": \"recursion\", \"mode\": \"reasoning\", \"include_pending\": true}"
  let result = protocol.decode_client_message(json)
  result |> should.be_ok
  let assert Ok(protocol.RequestSearchLibrary(query:, mode:, include_pending:)) =
    result
  query |> should.equal("recursion")
  mode |> should.equal("reasoning")
  include_pending |> should.be_true
}

pub fn decode_request_search_library_defaults_mode_and_include_test() {
  // mode + include_pending are optional → mode defaults to "embedding",
  // include_pending defaults to False
  let json = "{\"type\": \"request_search_library\", \"query\": \"q\"}"
  let result = protocol.decode_client_message(json)
  result |> should.be_ok
  let assert Ok(protocol.RequestSearchLibrary(query:, mode:, include_pending:)) =
    result
  query |> should.equal("q")
  mode |> should.equal("embedding")
  include_pending |> should.be_false
}

pub fn decode_request_approve_export_test() {
  let json =
    "{\"type\": \"request_approve_export\", \"slug\": \"my-report\", \"note\": \"looks good\"}"
  let result = protocol.decode_client_message(json)
  result |> should.be_ok
  let assert Ok(protocol.RequestApproveExport(slug:, note:)) = result
  slug |> should.equal("my-report")
  note |> should.equal("looks good")
}

pub fn decode_request_approve_export_optional_note_test() {
  let json = "{\"type\": \"request_approve_export\", \"slug\": \"my-report\"}"
  let result = protocol.decode_client_message(json)
  result |> should.be_ok
  let assert Ok(protocol.RequestApproveExport(slug:, note:)) = result
  slug |> should.equal("my-report")
  note |> should.equal("")
}

pub fn decode_request_reject_export_test() {
  let json =
    "{\"type\": \"request_reject_export\", \"slug\": \"my-report\", \"reason\": \"unsourced claims\"}"
  let result = protocol.decode_client_message(json)
  result |> should.be_ok
  let assert Ok(protocol.RequestRejectExport(slug:, reason:)) = result
  slug |> should.equal("my-report")
  reason |> should.equal("unsourced claims")
}

pub fn decode_request_reject_export_missing_reason_errors_test() {
  // reason is required (not optional) — missing field must fail decode
  let json = "{\"type\": \"request_reject_export\", \"slug\": \"my-report\"}"
  protocol.decode_client_message(json) |> should.be_error
}

// ---------------------------------------------------------------------------
// encode_server_message — Documents tab messages (PR 8)
// ---------------------------------------------------------------------------

pub fn encode_document_list_data_test() {
  let msg =
    protocol.DocumentListData(
      documents_json: "[{\"doc_id\":\"a\",\"title\":\"A\"}]",
    )
  let json_str = protocol.encode_server_message(msg)
  json_str |> should_contain("\"type\":\"document_list_data\"")
  json_str
  |> should_contain("\"documents\":[{\"doc_id\":\"a\",\"title\":\"A\"}]")
}

pub fn encode_document_view_data_test() {
  let msg =
    protocol.DocumentViewData(
      doc_id: "doc-1",
      document_json: "{\"meta\":{},\"tree\":{}}",
    )
  let json_str = protocol.encode_server_message(msg)
  json_str |> should_contain("\"type\":\"document_view_data\"")
  json_str |> should_contain("\"doc_id\":\"doc-1\"")
  json_str |> should_contain("\"document\":{\"meta\":{},\"tree\":{}}")
}

pub fn encode_document_view_data_escapes_doc_id_test() {
  // doc_id is a user-controlled string and goes through json.string for escaping
  let msg =
    protocol.DocumentViewData(
      doc_id: "with \"quotes\" and \\slashes",
      document_json: "{}",
    )
  let json_str = protocol.encode_server_message(msg)
  // Quotes inside doc_id must be JSON-escaped
  json_str |> should_contain("\\\"quotes\\\"")
}

pub fn encode_search_results_data_test() {
  let msg =
    protocol.SearchResultsData(
      query: "test query",
      results_json: "[{\"score\":0.9}]",
    )
  let json_str = protocol.encode_server_message(msg)
  json_str |> should_contain("\"type\":\"search_results_data\"")
  json_str |> should_contain("\"query\":\"test query\"")
  json_str |> should_contain("\"results\":[{\"score\":0.9}]")
}

pub fn encode_approval_result_ok_test() {
  let msg =
    protocol.ApprovalResult(
      slug: "report-2026-04",
      status: "ok",
      message: "Approved",
    )
  let json_str = protocol.encode_server_message(msg)
  json_str |> should_contain("\"type\":\"approval_result\"")
  json_str |> should_contain("\"slug\":\"report-2026-04\"")
  json_str |> should_contain("\"status\":\"ok\"")
  json_str |> should_contain("\"message\":\"Approved\"")
}

pub fn encode_approval_result_escapes_message_test() {
  let msg =
    protocol.ApprovalResult(
      slug: "x",
      status: "error",
      message: "broke: \"oops\"",
    )
  let json_str = protocol.encode_server_message(msg)
  // The user-visible message goes through json.string so quotes get escaped
  json_str |> should_contain("\\\"oops\\\"")
}

// ---------------------------------------------------------------------------
// Seq field — Phase 6b observability
// ---------------------------------------------------------------------------

pub fn encode_includes_seq_field_test() {
  let json_str = protocol.encode_server_message(protocol.Thinking)
  json_str |> should_contain("\"seq\":")
  // seq must appear BEFORE type so the JSON remains well-formed and the
  // client can read it without parsing the full body.
  case string.split_once(json_str, "\"seq\":") {
    Ok(#(before, _)) -> before |> should.equal("{")
    Error(_) -> should.fail()
  }
}

pub fn seq_passes_through_explicit_value_test() {
  // Per-client seq is assigned by the outbox registry (see
  // web/client_registry.gleam) and threaded through
  // encode_server_message_with_seq. The protocol module just splices
  // whatever value the caller hands it. Confirm the round-trip:
  // pass seq=42, pull seq=42 back out.
  let a = protocol.encode_server_message_with_seq(42, protocol.Thinking)
  let b = protocol.encode_server_message_with_seq(43, protocol.Thinking)
  extract_seq(a) |> should.equal(42)
  extract_seq(b) |> should.equal(43)
}

fn extract_seq(json_str: String) -> Int {
  // Parse "seq":N out of the JSON string. Assumes the format is
  // {"seq":N,"type":...
  case string.split_once(json_str, "\"seq\":") {
    Ok(#(_, rest)) ->
      case string.split_once(rest, ",") {
        Ok(#(n_str, _)) ->
          case int.parse(string.trim(n_str)) {
            Ok(n) -> n
            Error(_) -> -1
          }
        Error(_) -> -1
      }
    Error(_) -> -1
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

import gleam/int
import gleam/string

fn should_contain(haystack: String, needle: String) -> Nil {
  string.contains(haystack, needle) |> should.be_true
}
