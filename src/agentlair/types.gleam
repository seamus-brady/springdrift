// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

/// AgentLair telemetry types — behavioral trust network integration.
import gleam/json
import gleam/option.{type Option, None, Some}

pub type AgentLairConfig {
  AgentLairConfig(
    enabled: Bool,
    api_key: String,
    endpoint_url: String,
    trust_query: Bool,
  )
}

pub type ActionType {
  ToolCall
  MemoryUpdate
  Decision
  ExternalRequest
}

pub type Outcome {
  Success
  Failure
  Anomaly
}

pub type TelemetryEvent {
  TelemetryEvent(
    event: String,
    agent_id: String,
    timestamp: String,
    axiom_hash: String,
    action_type: ActionType,
    outcome: Outcome,
    context_ref: Option(String),
  )
}

pub type TrustSummary {
  TrustSummary(
    score: Float,
    tier: String,
    evidence_count: Int,
    last_seen: String,
  )
}

pub fn action_type_to_string(at: ActionType) -> String {
  case at {
    ToolCall -> "tool_call"
    MemoryUpdate -> "memory_update"
    Decision -> "decision"
    ExternalRequest -> "external_request"
  }
}

pub fn outcome_to_string(o: Outcome) -> String {
  case o {
    Success -> "success"
    Failure -> "failure"
    Anomaly -> "anomaly"
  }
}

pub fn encode_event(event: TelemetryEvent) -> String {
  json.to_string(
    json.object([
      #("event", json.string(event.event)),
      #("agent_id", json.string(event.agent_id)),
      #("timestamp", json.string(event.timestamp)),
      #("axiom_hash", json.string(event.axiom_hash)),
      #("action_type", json.string(action_type_to_string(event.action_type))),
      #("outcome", json.string(outcome_to_string(event.outcome))),
      #("context_ref", case event.context_ref {
        Some(ref) -> json.string(ref)
        None -> json.null()
      }),
    ]),
  )
}
