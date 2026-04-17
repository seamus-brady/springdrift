// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

/// AgentLair emitter — async fire-and-forget telemetry to AgentLair API.
import agentlair/types.{
  type AgentLairConfig, type TelemetryEvent, Decision, ExternalRequest, ToolCall,
}
import dprime/types as dprime_types
import gleam/erlang/process
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string
import slog

@external(erlang, "springdrift_ffi", "http_post")
fn http_post(
  url: String,
  headers: List(#(String, String)),
  body: String,
) -> Result(#(Int, String), String)

@external(erlang, "springdrift_ffi", "sha256_hex")
fn sha256_hex(input: String) -> String

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

@external(erlang, "springdrift_ffi", "http_get_with_headers")
fn http_get_with_headers(
  url: String,
  headers: List(#(String, String)),
) -> Result(#(Int, String), String)

pub fn emit_gate_decision(
  config: Option(AgentLairConfig),
  agent_id: String,
  gate_result: dprime_types.GateResult,
  gate_name: String,
  cycle_id: Option(String),
) -> Nil {
  case config {
    None -> Nil
    Some(cfg) if cfg.enabled == False -> Nil
    Some(cfg) -> {
      let action_type = case gate_name {
        "tool" -> ToolCall
        "output" -> Decision
        "input" -> Decision
        "comms" -> ExternalRequest
        _ -> Decision
      }
      let outcome = case gate_result.decision {
        dprime_types.Accept -> types.Success
        dprime_types.Modify -> types.Anomaly
        dprime_types.Reject -> types.Failure
      }
      let decision_str = case gate_result.decision {
        dprime_types.Accept -> "accept"
        dprime_types.Modify -> "modify"
        dprime_types.Reject -> "reject"
      }
      let axiom_content =
        gate_name <> ":" <> decision_str <> ":" <> gate_result.explanation
      let event =
        types.TelemetryEvent(
          event: "axiom.committed",
          agent_id:,
          timestamp: get_datetime(),
          axiom_hash: sha256_hex(axiom_content),
          action_type:,
          outcome:,
          context_ref: cycle_id,
        )
      emit_async(cfg, event)
    }
  }
}

pub fn emit_normative_verdict(
  config: Option(AgentLairConfig),
  agent_id: String,
  verdict_str: String,
  axiom_trail: List(String),
  cycle_id: Option(String),
) -> Nil {
  case config {
    None -> Nil
    Some(cfg) if cfg.enabled == False -> Nil
    Some(cfg) -> {
      let outcome = case verdict_str {
        "flourishing" -> types.Success
        "constrained" -> types.Anomaly
        "prohibited" -> types.Failure
        _ -> types.Success
      }
      let axiom_content =
        "normative:" <> verdict_str <> ":" <> string.join(axiom_trail, ",")
      let event =
        types.TelemetryEvent(
          event: "axiom.committed",
          agent_id:,
          timestamp: get_datetime(),
          axiom_hash: sha256_hex(axiom_content),
          action_type: Decision,
          outcome:,
          context_ref: cycle_id,
        )
      emit_async(cfg, event)
    }
  }
}

fn emit_async(config: AgentLairConfig, event: TelemetryEvent) -> Nil {
  let _ =
    process.spawn_unlinked(fn() {
      let url = config.endpoint_url <> "/v1/telemetry/submit"
      let body = types.encode_event(event)
      let headers = [
        #("Authorization", "Bearer " <> config.api_key),
        #("Content-Type", "application/json"),
      ]
      case http_post(url, headers, body) {
        Ok(#(status, _)) if status >= 200 && status < 300 ->
          slog.debug(
            "agentlair",
            "emit",
            "telemetry submitted (status=" <> int.to_string(status) <> ")",
            None,
          )
        Ok(#(status, resp_body)) ->
          slog.warn(
            "agentlair",
            "emit",
            "telemetry rejected (status="
              <> int.to_string(status)
              <> "): "
              <> string.slice(resp_body, 0, 200),
            None,
          )
        Error(reason) ->
          slog.debug("agentlair", "emit", "telemetry failed: " <> reason, None)
      }
      Nil
    })
  Nil
}

pub fn query_trust(
  config: Option(AgentLairConfig),
  agent_id: String,
) -> Result(String, String) {
  case config {
    None -> Error("AgentLair not configured")
    Some(cfg) if cfg.enabled == False ->
      Error("AgentLair trust query not enabled")
    Some(cfg) if cfg.trust_query == False ->
      Error("AgentLair trust query not enabled")
    Some(cfg) -> {
      let url = cfg.endpoint_url <> "/v1/trust/" <> agent_id
      let headers = [
        #("Authorization", "Bearer " <> cfg.api_key),
        #("Accept", "application/json"),
      ]
      case http_get_with_headers(url, headers) {
        Ok(#(status, body)) if status >= 200 && status < 300 -> Ok(body)
        Ok(#(status, body)) ->
          Error(
            "HTTP "
            <> int.to_string(status)
            <> ": "
            <> string.slice(body, 0, 200),
          )
        Error(reason) -> Error(reason)
      }
    }
  }
}
