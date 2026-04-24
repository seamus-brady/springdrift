//// Phase 2a tests — refs prefixing on delegation + NEEDS_INPUT detection.
////
//// These are unit tests over the pure helpers in
//// `agent/cognitive/agents.gleam`. No actor startup needed.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/cognitive/agents
import gleam/string
import gleeunit/should

// ---------------------------------------------------------------------------
// is_needs_input — substring detection used to reformat results
// ---------------------------------------------------------------------------

pub fn needs_input_matches_exact_marker_test() {
  agents.is_needs_input(
    "[NEEDS_INPUT: I need the prior draft's artifact_id to continue.]",
  )
  |> should.be_true
}

pub fn needs_input_matches_when_embedded_in_reply_test() {
  // Specialists might preamble with whitespace or a header before the marker.
  let reply =
    "Hello, I checked the instruction.\n\n[NEEDS_INPUT: no artifact_id]"
  agents.is_needs_input(reply) |> should.be_true
}

pub fn needs_input_does_not_match_prose_discussion_test() {
  // Talking about NEEDS_INPUT conceptually shouldn't trigger — but since
  // we're looking for the literal marker with opening bracket, discussion
  // of "needs input" in plain prose won't match.
  agents.is_needs_input(
    "The agent should return NEEDS_INPUT when refs are missing.",
  )
  |> should.be_false
}

pub fn needs_input_empty_string_is_false_test() {
  agents.is_needs_input("") |> should.be_false
}

// ---------------------------------------------------------------------------
// parse_agent_params — refs get prepended as <refs> XML when present
// ---------------------------------------------------------------------------

pub fn parse_agent_params_no_refs_returns_bare_instruction_test() {
  let json = "{\"instruction\": \"write a summary\"}"
  let #(instruction, _ctx) = agents.parse_agent_params(json)
  instruction |> should.equal("write a summary")
}

pub fn parse_agent_params_with_artifact_id_prepends_refs_block_test() {
  let json =
    "{\"instruction\": \"finish the report\", \"artifact_id\": \"art-abc\"}"
  let #(instruction, _ctx) = agents.parse_agent_params(json)
  instruction |> string.contains("<refs>") |> should.be_true
  instruction
  |> string.contains("<artifact_id>art-abc</artifact_id>")
  |> should.be_true
  instruction |> string.contains("finish the report") |> should.be_true
}

pub fn parse_agent_params_with_all_refs_includes_all_test() {
  let json =
    "{\"instruction\": \"do the thing\", \"artifact_id\": \"art-1\", "
    <> "\"task_id\": \"task-2\", \"prior_cycle_id\": \"cyc-3\"}"
  let #(instruction, _ctx) = agents.parse_agent_params(json)
  instruction
  |> string.contains("<artifact_id>art-1</artifact_id>")
  |> should.be_true
  instruction |> string.contains("<task_id>task-2</task_id>") |> should.be_true
  instruction
  |> string.contains("<prior_cycle_id>cyc-3</prior_cycle_id>")
  |> should.be_true
}

pub fn parse_agent_params_empty_ref_strings_are_dropped_test() {
  // Orchestrator passes "" for an unused ref — shouldn't show up.
  let json =
    "{\"instruction\": \"test\", \"artifact_id\": \"\", \"task_id\": \"task-x\"}"
  let #(instruction, _ctx) = agents.parse_agent_params(json)
  instruction |> string.contains("<artifact_id>") |> should.be_false
  instruction |> string.contains("<task_id>task-x</task_id>") |> should.be_true
}

pub fn parse_agent_params_refs_prefix_appears_before_instruction_test() {
  let json = "{\"instruction\": \"finish\", \"artifact_id\": \"art-1\"}"
  let #(instruction, _ctx) = agents.parse_agent_params(json)
  // <refs> block must appear before the instruction text in the final
  // string, so the specialist sees refs before reading the instruction.
  let refs_pos = case string.split_once(instruction, "<refs>") {
    Ok(#(before, _)) -> string.length(before)
    Error(_) -> -1
  }
  let finish_pos = case string.split_once(instruction, "finish") {
    Ok(#(before, _)) -> string.length(before)
    Error(_) -> -1
  }
  let before_finish = refs_pos < finish_pos && refs_pos >= 0
  before_finish |> should.be_true
}
