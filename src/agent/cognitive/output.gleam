//// Cycle-terminal output — the helpers that replace every bare
//// `process.send(reply_to, CognitiveReply(...))` call. The legacy
//// `reply_to` path remains active while Frontdoor is being wired in,
//// and the Frontdoor publish runs in parallel when both the output
//// channel and a live cycle_id are present.
////
//// Once every external caller has migrated to Frontdoor (Phase 5),
//// the legacy arm is removed and the reply_to parameter is replaced
//// with cycle_id.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/cognitive_state.{type CognitiveState}
import agent/types.{type CognitiveReply, CognitiveReply}
import frontdoor/types as frontdoor_types
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, Some}
import llm/types as llm_types

/// Send a terminal reply for the current cycle. Always sends to the
/// legacy `reply_to` subject; also publishes a CognitiveReplyOutput to
/// Frontdoor when the channel is wired and a cycle_id is known.
pub fn send_reply(
  state: CognitiveState,
  reply_to: Subject(CognitiveReply),
  response: String,
  model: String,
  usage: Option(llm_types.Usage),
  tools_fired: List(String),
) -> Nil {
  process.send(
    reply_to,
    CognitiveReply(response:, model:, usage:, tools_fired:),
  )
  publish_reply_to_frontdoor(state, response, model, usage, tools_fired)
}

fn publish_reply_to_frontdoor(
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
