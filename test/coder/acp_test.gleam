// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import coder/acp
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

// ─── Body builders ────────────────────────────────────────────────────────

pub fn build_initialize_includes_protocol_version_test() {
  let body = acp.build_initialize(1)
  body |> string.contains("\"jsonrpc\":\"2.0\"") |> should.be_true
  body |> string.contains("\"method\":\"initialize\"") |> should.be_true
  body |> string.contains("\"protocolVersion\":1") |> should.be_true
  body |> string.contains("\"clientInfo\"") |> should.be_true
  body |> string.contains("\"name\":\"springdrift\"") |> should.be_true
}

pub fn build_session_new_includes_cwd_test() {
  let body = acp.build_session_new(2, "/workspace/project")
  body |> string.contains("\"method\":\"session/new\"") |> should.be_true
  body |> string.contains("\"cwd\":\"/workspace/project\"") |> should.be_true
  body |> string.contains("\"mcpServers\":[]") |> should.be_true
}

pub fn build_session_prompt_includes_session_id_and_text_test() {
  let body = acp.build_session_prompt(3, "ses_abc", "say pong")
  body |> string.contains("\"method\":\"session/prompt\"") |> should.be_true
  body |> string.contains("\"sessionId\":\"ses_abc\"") |> should.be_true
  body |> string.contains("\"type\":\"text\"") |> should.be_true
  body |> string.contains("say pong") |> should.be_true
}

pub fn build_session_cancel_is_minimal_test() {
  let body = acp.build_session_cancel(4, "ses_abc")
  body |> string.contains("\"method\":\"session/cancel\"") |> should.be_true
  body |> string.contains("\"sessionId\":\"ses_abc\"") |> should.be_true
}

// ─── Initialize response decoder ──────────────────────────────────────────
//
// Real shape from the ACP probe against OpenCode 1.14.25 — pinning
// what we actually saw on the wire so a decoder regression is caught.

pub fn decode_initialize_real_shape_test() {
  let body =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{"
    <> "\"protocolVersion\":1,"
    <> "\"agentCapabilities\":{"
    <> "\"loadSession\":true,"
    <> "\"sessionCapabilities\":{\"fork\":{},\"list\":{},\"resume\":{}}"
    <> "},"
    <> "\"agentInfo\":{\"name\":\"OpenCode\",\"version\":\"1.14.25\"}"
    <> "}}"
  case acp.decode_initialize(body) {
    Ok(caps) -> {
      caps.protocol_version |> should.equal(1)
      caps.can_load_session |> should.be_true
      caps.can_fork |> should.be_true
      caps.can_list |> should.be_true
      caps.can_resume |> should.be_true
      caps.agent_name |> should.equal("OpenCode")
      caps.agent_version |> should.equal("1.14.25")
    }
    Error(e) -> {
      should.equal(Ok(""), Error(e))
      Nil
    }
  }
}

pub fn decode_initialize_tolerates_missing_optional_fields_test() {
  // Older / minimal agents may omit sessionCapabilities. Decoder
  // defaults to all-False rather than crashing.
  let body =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{"
    <> "\"protocolVersion\":1,"
    <> "\"agentInfo\":{\"name\":\"x\",\"version\":\"y\"}"
    <> "}}"
  case acp.decode_initialize(body) {
    Ok(caps) -> {
      caps.can_fork |> should.be_false
      caps.can_list |> should.be_false
      caps.can_resume |> should.be_false
    }
    Error(_) -> {
      should.fail()
      Nil
    }
  }
}

// ─── session/new response decoder ─────────────────────────────────────────

pub fn decode_session_new_extracts_session_id_test() {
  let body =
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{"
    <> "\"sessionId\":\"ses_236224851ffei3hR12A4PWYIL5\","
    <> "\"configOptions\":[],\"models\":{},\"modes\":{}"
    <> "}}"
  acp.decode_session_new(body)
  |> should.equal(Ok("ses_236224851ffei3hR12A4PWYIL5"))
}

pub fn decode_session_new_fails_when_missing_test() {
  case acp.decode_session_new("{\"result\":{}}") {
    Error(_) -> Nil
    Ok(_) -> {
      should.fail()
      Nil
    }
  }
}

// ─── session/prompt response decoder ──────────────────────────────────────

pub fn decode_prompt_result_real_shape_test() {
  // Real shape from the probe.
  let body =
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{"
    <> "\"stopReason\":\"end_turn\","
    <> "\"usage\":{\"totalTokens\":10808,\"inputTokens\":8930,"
    <> "\"outputTokens\":38,\"cachedReadTokens\":1840},"
    <> "\"_meta\":{}"
    <> "}}"
  case acp.decode_prompt_result(body) {
    Ok(r) -> {
      r.stop_reason |> should.equal(acp.StopEndTurn)
      r.total_tokens |> should.equal(10_808)
      r.input_tokens |> should.equal(8930)
      r.output_tokens |> should.equal(38)
      r.cached_read_tokens |> should.equal(1840)
    }
    Error(e) -> {
      should.equal(Ok(""), Error(e))
      Nil
    }
  }
}

pub fn decode_prompt_result_handles_cancelled_test() {
  let body =
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"stopReason\":\"cancelled\"}}"
  case acp.decode_prompt_result(body) {
    Ok(r) -> r.stop_reason |> should.equal(acp.StopCancelled)
    Error(_) -> {
      should.fail()
      Nil
    }
  }
}

pub fn stop_reason_from_string_known_values_test() {
  acp.stop_reason_from_string("end_turn") |> should.equal(acp.StopEndTurn)
  acp.stop_reason_from_string("max_tokens") |> should.equal(acp.StopMaxTokens)
  acp.stop_reason_from_string("max_turn_requests")
  |> should.equal(acp.StopMaxTurnRequests)
  acp.stop_reason_from_string("refusal") |> should.equal(acp.StopRefusal)
  acp.stop_reason_from_string("cancelled") |> should.equal(acp.StopCancelled)
}

pub fn stop_reason_unknown_preserves_raw_test() {
  case acp.stop_reason_from_string("invented_in_v2") {
    acp.StopUnknown(raw: r) -> r |> should.equal("invented_in_v2")
    other -> {
      should.equal(other, acp.StopUnknown("invented_in_v2"))
      Nil
    }
  }
}

// ─── session/update event decoder ─────────────────────────────────────────
//
// Each test pins one of the real event shapes captured from the ACP
// probe transcript on 1.14.25.

pub fn decode_event_agent_message_chunk_test() {
  let body =
    "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{"
    <> "\"sessionId\":\"ses_abc\",\"update\":{"
    <> "\"sessionUpdate\":\"agent_message_chunk\","
    <> "\"messageId\":\"msg_xyz\","
    <> "\"content\":{\"type\":\"text\",\"text\":\"\\n\\npong\"}"
    <> "}}}"
  case acp.decode_event(body) {
    acp.AcpMessageChunk(message_id: id, text: t) -> {
      id |> should.equal("msg_xyz")
      t |> string.contains("pong") |> should.be_true
    }
    other -> {
      should.equal(other, acp.AcpMessageChunk("msg_xyz", "pong"))
      Nil
    }
  }
}

pub fn decode_event_agent_thought_chunk_test() {
  let body =
    "{\"method\":\"session/update\",\"params\":{"
    <> "\"sessionId\":\"ses_abc\",\"update\":{"
    <> "\"sessionUpdate\":\"agent_thought_chunk\","
    <> "\"messageId\":\"msg_xyz\","
    <> "\"content\":{\"type\":\"text\",\"text\":\"thinking...\"}"
    <> "}}}"
  case acp.decode_event(body) {
    acp.AcpThoughtChunk(message_id: id, text: t) -> {
      id |> should.equal("msg_xyz")
      t |> should.equal("thinking...")
    }
    other -> {
      should.equal(other, acp.AcpThoughtChunk("msg_xyz", "thinking..."))
      Nil
    }
  }
}

pub fn decode_event_usage_update_test() {
  let body =
    "{\"method\":\"session/update\",\"params\":{"
    <> "\"sessionId\":\"ses_abc\",\"update\":{"
    <> "\"sessionUpdate\":\"usage_update\","
    <> "\"used\":10770,\"size\":200000,"
    <> "\"cost\":{\"amount\":0.0042,\"currency\":\"USD\"}"
    <> "}}}"
  case acp.decode_event(body) {
    acp.AcpUsageUpdate(used_tokens: u, total_size: s, cost_usd: c) -> {
      u |> should.equal(10_770)
      s |> should.equal(200_000)
      c |> should.equal(0.0042)
    }
    other -> {
      should.equal(other, acp.AcpUsageUpdate(0, 0, 0.0))
      Nil
    }
  }
}

pub fn decode_event_usage_update_handles_int_zero_cost_test() {
  // OpenCode emits cost.amount as JSON int 0 when zero, float when
  // non-zero. Our permissive number decoder handles both.
  let body =
    "{\"method\":\"session/update\",\"params\":{"
    <> "\"sessionId\":\"ses_abc\",\"update\":{"
    <> "\"sessionUpdate\":\"usage_update\","
    <> "\"used\":50,\"size\":200000,"
    <> "\"cost\":{\"amount\":0,\"currency\":\"USD\"}"
    <> "}}}"
  case acp.decode_event(body) {
    acp.AcpUsageUpdate(cost_usd: c, ..) -> c |> should.equal(0.0)
    other -> {
      should.equal(other, acp.AcpUsageUpdate(0, 0, 0.0))
      Nil
    }
  }
}

pub fn decode_event_unknown_type_preserves_raw_test() {
  let body =
    "{\"method\":\"session/update\",\"params\":{"
    <> "\"sessionId\":\"ses_abc\",\"update\":{"
    <> "\"sessionUpdate\":\"some_future_event_type\","
    <> "\"data\":\"whatever\""
    <> "}}}"
  case acp.decode_event(body) {
    acp.AcpUnknown(raw_json: raw) -> raw |> should.equal(body)
    other -> {
      should.equal(other, acp.AcpUnknown(""))
      Nil
    }
  }
}

pub fn decode_event_malformed_json_preserves_raw_test() {
  case acp.decode_event("not json at all") {
    acp.AcpUnknown(raw_json: _) -> Nil
    other -> {
      should.equal(other, acp.AcpUnknown(""))
      Nil
    }
  }
}

// ─── Response/notification distinction ────────────────────────────────────

pub fn extract_response_id_finds_id_test() {
  let body = "{\"jsonrpc\":\"2.0\",\"id\":42,\"result\":{}}"
  acp.extract_response_id(body) |> should.equal(Some(42))
}

pub fn extract_response_id_misses_notification_test() {
  let body = "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{}}"
  acp.extract_response_id(body) |> should.equal(None)
}

pub fn extract_rpc_error_finds_error_test() {
  let body =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{"
    <> "\"code\":-32601,\"message\":\"Method not found\"}}"
  case acp.extract_rpc_error(body) {
    Some(acp.AcpRpcError(code: c, message: m, data: _)) -> {
      c |> should.equal(-32_601)
      m |> should.equal("Method not found")
    }
    other -> {
      should.equal(other, Some(acp.AcpRpcError(0, "", None)))
      Nil
    }
  }
}

pub fn extract_rpc_error_misses_success_test() {
  let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"
  acp.extract_rpc_error(body) |> should.equal(None)
}

// ─── format_error roundtrip ───────────────────────────────────────────────

pub fn format_error_open_failed_test() {
  let msg = acp.format_error(acp.AcpOpenFailed(reason: "podman not found"))
  msg |> string.contains("podman not found") |> should.be_true
  msg |> string.contains("subprocess") |> should.be_true
}

pub fn format_error_subprocess_exit_test() {
  let msg = acp.format_error(acp.AcpSubprocessExit(status: 137))
  msg |> string.contains("137") |> should.be_true
}

pub fn format_error_timeout_includes_op_and_ms_test() {
  let msg =
    acp.format_error(acp.AcpTimeout(operation: "session/prompt", ms: 600_000))
  msg |> string.contains("session/prompt") |> should.be_true
  msg |> string.contains("600000") |> should.be_true
}
