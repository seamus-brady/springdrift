////
//// Backward-compatibility tests: NarrativeEntry + CbrCase JSONL written
//// before Phase A's `strategy_used` / `strategy_id` fields existed must
//// still decode cleanly. The decoders default the new fields to None.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import cbr/log as cbr_log
import gleam/json
import gleam/option.{None}
import gleeunit/should
import narrative/log as narrative_log

pub fn old_narrative_entry_decodes_with_strategy_used_none_test() {
  // A pre-Phase-A NarrativeEntry — no strategy_used field.
  let raw =
    "{\"schema_version\":1,\"cycle_id\":\"abc\",\"timestamp\":\"2026-04-17T10:00:00Z\","
    <> "\"type\":\"narrative\",\"summary\":\"hello\","
    <> "\"intent\":{\"classification\":\"conversation\",\"description\":\"\",\"domain\":\"general\"},"
    <> "\"outcome\":{\"status\":\"success\",\"confidence\":0.9,\"assessment\":\"\"},"
    <> "\"metrics\":{\"total_duration_ms\":0,\"input_tokens\":0,\"output_tokens\":0,"
    <> "\"thinking_tokens\":0,\"tool_calls\":0,\"agent_delegations\":0,"
    <> "\"dprime_evaluations\":0,\"model_used\":\"mock\"}}"
  case json.parse(raw, narrative_log.entry_decoder()) {
    Ok(entry) -> entry.strategy_used |> should.equal(None)
    Error(_) -> should.fail()
  }
}

pub fn old_cbr_case_decodes_with_strategy_id_none_test() {
  let raw =
    "{\"case_id\":\"c1\",\"timestamp\":\"2026-04-17T10:00:00Z\",\"schema_version\":1,"
    <> "\"problem\":{\"user_input\":\"u\",\"intent\":\"i\",\"domain\":\"d\","
    <> "\"entities\":[],\"keywords\":[],\"query_complexity\":\"simple\"},"
    <> "\"solution\":{\"approach\":\"a\",\"agents_used\":[],\"tools_used\":[],\"steps\":[]},"
    <> "\"outcome\":{\"status\":\"success\",\"confidence\":0.8,\"assessment\":\"\",\"pitfalls\":[]},"
    <> "\"source_narrative_id\":\"abc\",\"profile\":null,\"redacted\":false,"
    <> "\"category\":null,\"usage_stats\":null}"
  case json.parse(raw, cbr_log.case_decoder()) {
    Ok(c) -> c.strategy_id |> should.equal(None)
    Error(_) -> should.fail()
  }
}

pub fn new_narrative_entry_round_trips_strategy_used_test() {
  let raw =
    "{\"schema_version\":1,\"cycle_id\":\"abc\",\"timestamp\":\"2026-04-18T10:00:00Z\","
    <> "\"type\":\"narrative\",\"summary\":\"hello\","
    <> "\"intent\":{\"classification\":\"conversation\",\"description\":\"\",\"domain\":\"general\"},"
    <> "\"outcome\":{\"status\":\"success\",\"confidence\":0.9,\"assessment\":\"\"},"
    <> "\"metrics\":{\"total_duration_ms\":0,\"input_tokens\":0,\"output_tokens\":0,"
    <> "\"thinking_tokens\":0,\"tool_calls\":0,\"agent_delegations\":0,"
    <> "\"dprime_evaluations\":0,\"model_used\":\"mock\"},"
    <> "\"strategy_used\":\"delegate-then-synth\"}"
  case json.parse(raw, narrative_log.entry_decoder()) {
    Ok(entry) -> {
      let assert option.Some(id) = entry.strategy_used
      id |> should.equal("delegate-then-synth")
    }
    Error(_) -> should.fail()
  }
}
