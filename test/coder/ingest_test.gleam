// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import cbr/types as cbr_types
import coder/ingest
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

// ── build_case/5: chronological ordering + provenance ─────────────────────

pub fn build_case_uses_first_chronological_prompt_as_brief_test() {
  // Manager passes already-reversed list (chronological), so the first
  // pair is the initial brief. Pin this contract.
  let chronological = [
    #("Add a docstring to foo.gleam", "Done."),
    #("Run the tests", "All pass."),
  ]
  let c =
    ingest.build_case("ses_abc123", chronological, [], "claude-sonnet-4", 5000)

  c.problem.user_input
  |> string.contains("docstring")
  |> should.be_true

  c.problem.user_input
  |> string.contains("Run the tests")
  |> should.be_false
}

pub fn build_case_id_is_prefixed_with_coder_test() {
  let chronological = [#("foo", "bar")]
  let c =
    ingest.build_case("ses_xyz", chronological, [], "claude-sonnet-4", 1000)
  c.case_id |> should.equal("coder-ses_xyz")
  c.source_narrative_id |> should.equal("ses_xyz")
}

pub fn build_case_category_is_code_pattern_test() {
  // Pin: coder sessions go in as CodePattern. Phase 4.x may distinguish
  // Strategy / Troubleshooting / Pitfall based on outcome, but for now
  // all coder sessions categorise the same way.
  let chronological = [#("foo", "bar")]
  let c = ingest.build_case("ses_xyz", chronological, [], "model", 1000)
  c.category |> should.equal(Some(cbr_types.CodePattern))
}

pub fn build_case_problem_intent_and_domain_are_code_test() {
  let chronological = [#("hello", "world")]
  let c = ingest.build_case("ses_xyz", chronological, [], "model", 1000)
  c.problem.intent |> should.equal("code")
  c.problem.domain |> should.equal("code")
}

// ── solution.steps: chronological turn-by-turn ────────────────────────────

pub fn build_case_solution_steps_match_turn_count_test() {
  let chronological = [
    #("turn one prompt", "turn one response"),
    #("turn two prompt", "turn two response"),
    #("turn three prompt", "turn three response"),
  ]
  let c = ingest.build_case("ses_xyz", chronological, [], "model", 1000)
  list.length(c.solution.steps) |> should.equal(3)
}

pub fn build_case_solution_steps_chronological_test() {
  let chronological = [
    #("first prompt", "first response"),
    #("second prompt", "second response"),
  ]
  let c = ingest.build_case("ses_xyz", chronological, [], "model", 1000)
  case c.solution.steps {
    [step1, step2] -> {
      step1
      |> string.contains("turn 1")
      |> should.be_true
      step1
      |> string.contains("first prompt")
      |> should.be_true
      step2
      |> string.contains("turn 2")
      |> should.be_true
      step2
      |> string.contains("second prompt")
      |> should.be_true
    }
    _ -> {
      should.fail()
      Nil
    }
  }
}

pub fn build_case_solution_credits_coder_agent_test() {
  let chronological = [#("foo", "bar")]
  let c = ingest.build_case("ses_xyz", chronological, [], "model", 1000)
  c.solution.agents_used |> should.equal(["coder"])
}

pub fn build_case_solution_approach_names_the_model_test() {
  let chronological = [#("foo", "bar")]
  let c =
    ingest.build_case("ses_xyz", chronological, [], "claude-sonnet-4-foo", 1000)
  c.solution.approach
  |> string.contains("claude-sonnet-4-foo")
  |> should.be_true
}

// ── tool_titles propagate into Solution.tools_used (R7) ───────────────────
//
// The manager tracks distinct OpenCode tool names invoked during a
// session via AcpToolCall events and threads them into ingest. CBR
// retrieval clusters on tools_used, so this is the load-bearing bit:
// "previous session that used Read+Edit+Bash" is a strong match
// signal for new code-edit briefs.

pub fn build_case_solution_tools_used_uses_actual_tool_titles_test() {
  let chronological = [#("edit foo.gleam", "Done.")]
  let c =
    ingest.build_case(
      "ses_xyz",
      chronological,
      ["Read", "Edit", "Bash"],
      "model",
      1000,
    )
  c.solution.tools_used |> should.equal(["Read", "Edit", "Bash"])
}

pub fn build_case_solution_tools_used_falls_back_when_no_tools_test() {
  // Pure-chat session (no tool calls) — fall back to a sentinel so
  // retrieval still has something to match on instead of empty list.
  let chronological = [#("explain X", "X is...")]
  let c = ingest.build_case("ses_xyz", chronological, [], "model", 1000)
  c.solution.tools_used |> should.equal(["coder_dispatch"])
}

pub fn build_case_outcome_mentions_tool_count_when_tools_used_test() {
  let chronological = [#("a", "b")]
  let c =
    ingest.build_case("ses_xyz", chronological, ["Read", "Edit"], "model", 1000)
  c.outcome.assessment
  |> string.contains("2 distinct tool")
  |> should.be_true
}

pub fn build_case_outcome_omits_tool_count_when_no_tools_test() {
  let chronological = [#("a", "b")]
  let c = ingest.build_case("ses_xyz", chronological, [], "model", 1000)
  c.outcome.assessment
  |> string.contains("distinct tool")
  |> should.be_false
}

// ── outcome: structural placeholder for Phase 4 minimum ───────────────────

pub fn build_case_outcome_records_turn_count_and_duration_test() {
  let chronological = [#("a", "b"), #("c", "d"), #("e", "f")]
  let c = ingest.build_case("ses_xyz", chronological, [], "model", 12_000)

  c.outcome.assessment
  |> string.contains("3 turn")
  |> should.be_true

  c.outcome.assessment
  |> string.contains("12s")
  |> should.be_true
}

pub fn build_case_outcome_status_is_completed_test() {
  // Phase 4 minimum — outcome.status is always "completed". Phase 4.x
  // ties this to host-side run_tests/run_build verdicts.
  let chronological = [#("a", "b")]
  let c = ingest.build_case("ses_xyz", chronological, [], "model", 1000)
  c.outcome.status |> should.equal("completed")
}

pub fn build_case_outcome_confidence_neutral_test() {
  // Without Phase 4.x verification feedback, confidence stays neutral.
  let chronological = [#("a", "b")]
  let c = ingest.build_case("ses_xyz", chronological, [], "model", 1000)
  c.outcome.confidence |> should.equal(0.5)
}

// ── usage_stats start empty ───────────────────────────────────────────────

pub fn build_case_usage_stats_starts_empty_test() {
  let chronological = [#("a", "b")]
  let c = ingest.build_case("ses_xyz", chronological, [], "model", 1000)
  c.usage_stats |> should.equal(None)
}

// ── strategy_id is None for unstrategised coder sessions ──────────────────

pub fn build_case_strategy_id_is_none_test() {
  let chronological = [#("a", "b")]
  let c = ingest.build_case("ses_xyz", chronological, [], "model", 1000)
  c.strategy_id |> should.equal(None)
}
