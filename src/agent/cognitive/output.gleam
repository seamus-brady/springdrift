//// Cycle-terminal output — publishes the reply to Frontdoor. All
//// downstream sinks (Web GUI WebSocket, TUI) subscribe by source_id
//// and receive the delivery from there. No direct reply-subject
//// plumbing remains: the legacy `reply_to: Subject(CognitiveReply)`
//// channel was removed in PR #113 after being dead-letter for
//// several releases.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/cognitive_state.{type CognitiveState}
import frontdoor/types as frontdoor_types
import gleam/erlang/process
import gleam/option.{type Option, Some}
import llm/types as llm_types

/// Publish the cycle-terminal reply to Frontdoor. Inert when Frontdoor
/// isn't wired or the cycle_id isn't set (shouldn't happen once
/// classification has run).
pub fn send_reply(
  state: CognitiveState,
  response: String,
  model: String,
  usage: Option(llm_types.Usage),
  tools_fired: List(String),
) -> Nil {
  case state.config.frontdoor, state.cycle_id {
    Some(frontdoor), Some(cycle_id) ->
      process.send(
        frontdoor,
        frontdoor_types.Publish(output: frontdoor_types.CognitiveReplyOutput(
          cycle_id:,
          response:,
          model:,
          usage:,
          tools_fired:,
        )),
      )
    _, _ -> Nil
  }
}

/// Publish a human-question raised inside the current cycle. Frontdoor
/// routes the question to the originating source's sink, or — for
/// scheduler-owned cycles — drops it and synthesises an answer back
/// into cognitive's inbox. Inert when no cycle_id or no Frontdoor.
pub fn publish_human_question(
  state: CognitiveState,
  question: String,
  origin: frontdoor_types.QuestionOrigin,
) -> Nil {
  case state.config.frontdoor, state.cycle_id {
    Some(frontdoor), Some(cycle_id) -> {
      let question_id = generate_uuid()
      process.send(
        frontdoor,
        frontdoor_types.Publish(output: frontdoor_types.HumanQuestionOutput(
          cycle_id:,
          question_id:,
          question:,
          origin:,
        )),
      )
    }
    _, _ -> Nil
  }
}

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_uuid() -> String
