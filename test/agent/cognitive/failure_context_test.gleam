//// Pure unit tests for L2 failure-context injection. When an agent
//// is re-dispatched this cycle after a prior failure, the dispatcher
//// prepends a short block describing what failed. Validated here as
//// a pure function — no cognitive state needed.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/cognitive/agents as cognitive_agents
import agent/types.{type AgentCompletionRecord, AgentCompletionRecord}
import gleam/string
import gleeunit/should

fn record(
  agent: String,
  instruction: String,
  result: Result(String, String),
) -> AgentCompletionRecord {
  AgentCompletionRecord(
    agent_id: agent,
    agent_human_name: agent,
    agent_cycle_id: "cyc",
    instruction: instruction,
    result: result,
    tools_used: [],
    tool_call_details: [],
    input_tokens: 0,
    output_tokens: 0,
    duration_ms: 0,
  )
}

// ---------------------------------------------------------------------------
// No prior failures — identity
// ---------------------------------------------------------------------------

pub fn no_completions_returns_instruction_unchanged_test() {
  cognitive_agents.prepend_prior_failures("write a todo app", "coder", [])
  |> should.equal("write a todo app")
}

pub fn prior_success_is_ignored_test() {
  let completions = [record("coder", "earlier task", Ok("fine"))]
  cognitive_agents.prepend_prior_failures(
    "write a todo app",
    "coder",
    completions,
  )
  |> should.equal("write a todo app")
}

pub fn different_agent_failure_is_ignored_test() {
  let completions = [
    record("researcher", "lookup X", Error("timed out")),
  ]
  cognitive_agents.prepend_prior_failures(
    "write a todo app",
    "coder",
    completions,
  )
  |> should.equal("write a todo app")
}

// ---------------------------------------------------------------------------
// Prior failure — block is prepended
// ---------------------------------------------------------------------------

pub fn prior_failure_produces_prelude_test() {
  let completions = [
    record("coder", "serve a todo app", Error("curl not installed")),
  ]
  let out =
    cognitive_agents.prepend_prior_failures(
      "serve a todo app",
      "coder",
      completions,
    )
  string.contains(out, "PRIOR FAILURE") |> should.equal(True)
  string.contains(out, "agent: coder") |> should.equal(True)
  string.contains(out, "curl not installed") |> should.equal(True)
  string.contains(out, "New instruction:") |> should.equal(True)
  string.contains(out, "serve a todo app") |> should.equal(True)
}

pub fn multiple_failures_both_rendered_test() {
  // Most recent is at head (the dispatch path prepends to the list).
  let completions = [
    record("coder", "attempt 2", Error("error B")),
    record("coder", "attempt 1", Error("error A")),
  ]
  let out =
    cognitive_agents.prepend_prior_failures("third try", "coder", completions)
  string.contains(out, "error A") |> should.equal(True)
  string.contains(out, "error B") |> should.equal(True)
  string.contains(out, "attempt 1") |> should.equal(True)
  string.contains(out, "attempt 2") |> should.equal(True)
  string.contains(out, "third try") |> should.equal(True)
}

pub fn older_failures_capped_at_two_most_recent_test() {
  // Four failures; expect only the two most recent in the prelude.
  // 'error oldest' should NOT appear.
  let completions = [
    record("coder", "v4", Error("error newest")),
    record("coder", "v3", Error("error secondnewest")),
    record("coder", "v2", Error("error thirdnewest")),
    record("coder", "v1", Error("error oldest")),
  ]
  let out =
    cognitive_agents.prepend_prior_failures("fifth try", "coder", completions)
  string.contains(out, "error newest") |> should.equal(True)
  string.contains(out, "error secondnewest") |> should.equal(True)
  string.contains(out, "error oldest") |> should.equal(False)
  string.contains(out, "error thirdnewest") |> should.equal(False)
}

// ---------------------------------------------------------------------------
// Truncation
// ---------------------------------------------------------------------------

pub fn long_error_is_truncated_test() {
  let long_err = string.repeat("X", 2000)
  let completions = [record("coder", "task", Error(long_err))]
  let out =
    cognitive_agents.prepend_prior_failures("retry", "coder", completions)
  // Ellipsis marker means the error was truncated.
  string.contains(out, "…") |> should.equal(True)
  // Full 2000-char error string is not present verbatim.
  string.contains(out, long_err) |> should.equal(False)
}
