// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/team.{
  type ContextScope, DebateAndConsensus, Independent, LeadWithSpecialists,
  MemberResult, ParallelMerge, SharedFacts, TeamMember, TeamPipeline, TeamSpec,
}
import agent/types.{type DispatchStrategy, Parallel, Pipeline, Sequential}
import gleam/list
import gleam/option
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// DispatchStrategy type tests (Level 1)
// ---------------------------------------------------------------------------

pub fn dispatch_strategy_parallel_test() {
  let _strategy: DispatchStrategy = Parallel
  should.be_true(True)
}

pub fn dispatch_strategy_pipeline_test() {
  let _strategy: DispatchStrategy = Pipeline
  should.be_true(True)
}

pub fn dispatch_strategy_sequential_test() {
  let _strategy: DispatchStrategy = Sequential
  should.be_true(True)
}

// ---------------------------------------------------------------------------
// TeamSpec construction tests (Level 2)
// ---------------------------------------------------------------------------

pub fn team_spec_parallel_merge_test() {
  let spec = make_research_team()
  spec.name |> should.equal("deep-research")
  list.length(spec.members) |> should.equal(2)
  case spec.strategy {
    ParallelMerge -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn team_spec_pipeline_test() {
  let spec =
    TeamSpec(
      name: "analysis-pipeline",
      description: "Research then write",
      members: [
        TeamMember(
          agent_name: "researcher",
          role: "data_gatherer",
          perspective: "Gather raw data",
        ),
        TeamMember(
          agent_name: "writer",
          role: "report_author",
          perspective: "Write report from gathered data",
        ),
      ],
      strategy: TeamPipeline,
      context_scope: Independent,
      max_rounds: 2,
      synthesis_model: "mock-model",
      synthesis_max_tokens: 1024,
    )
  spec.name |> should.equal("analysis-pipeline")
  case spec.strategy {
    TeamPipeline -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn team_spec_debate_test() {
  let spec =
    TeamSpec(
      name: "fact-check",
      description: "Multiple perspectives with debate",
      members: [
        TeamMember(
          agent_name: "researcher",
          role: "analyst_a",
          perspective: "Focus on quantitative evidence",
        ),
        TeamMember(
          agent_name: "researcher",
          role: "analyst_b",
          perspective: "Focus on qualitative evidence",
        ),
        TeamMember(
          agent_name: "observer",
          role: "fact_checker",
          perspective: "Verify claims against available data",
        ),
      ],
      strategy: DebateAndConsensus(max_debate_rounds: 2),
      context_scope: SharedFacts,
      max_rounds: 3,
      synthesis_model: "mock-model",
      synthesis_max_tokens: 2048,
    )
  list.length(spec.members) |> should.equal(3)
  case spec.strategy {
    DebateAndConsensus(max_debate_rounds: 2) -> should.be_true(True)
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// team_to_tool tests
// ---------------------------------------------------------------------------

pub fn team_to_tool_generates_correct_name_test() {
  let spec = make_research_team()
  let tool = team.team_to_tool(spec)
  tool.name |> should.equal("team_deep-research")
}

pub fn team_to_tool_description_includes_strategy_test() {
  let spec = make_research_team()
  let tool = team.team_to_tool(spec)
  string.contains(option.unwrap(tool.description, ""), "parallel merge")
  |> should.be_true()
}

pub fn team_to_tool_description_includes_members_test() {
  let spec = make_research_team()
  let tool = team.team_to_tool(spec)
  string.contains(option.unwrap(tool.description, ""), "academic_researcher")
  |> should.be_true()
  string.contains(option.unwrap(tool.description, ""), "industry_analyst")
  |> should.be_true()
}

pub fn team_to_tool_pipeline_description_test() {
  let spec =
    TeamSpec(
      name: "pipe",
      description: "Pipeline team",
      members: [
        TeamMember(agent_name: "researcher", role: "r", perspective: "p"),
      ],
      strategy: TeamPipeline,
      context_scope: Independent,
      max_rounds: 1,
      synthesis_model: "mock",
      synthesis_max_tokens: 512,
    )
  let tool = team.team_to_tool(spec)
  string.contains(option.unwrap(tool.description, ""), "sequential pipeline")
  |> should.be_true()
}

pub fn team_spec_lead_with_specialists_test() {
  let spec =
    TeamSpec(
      name: "led-team",
      description: "Lead with specialists",
      members: [
        TeamMember(
          agent_name: "researcher",
          role: "lead",
          perspective: "Coordinate the team",
        ),
        TeamMember(
          agent_name: "writer",
          role: "specialist",
          perspective: "Write the report",
        ),
      ],
      strategy: LeadWithSpecialists(lead: "researcher"),
      context_scope: SharedFacts,
      max_rounds: 2,
      synthesis_model: "mock",
      synthesis_max_tokens: 1024,
    )
  case spec.strategy {
    LeadWithSpecialists(lead: "researcher") -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn team_to_tool_lead_description_test() {
  let spec =
    TeamSpec(
      name: "led",
      description: "Led team",
      members: [],
      strategy: LeadWithSpecialists(lead: "planner"),
      context_scope: SharedFacts,
      max_rounds: 2,
      synthesis_model: "mock",
      synthesis_max_tokens: 512,
    )
  let tool = team.team_to_tool(spec)
  string.contains(option.unwrap(tool.description, ""), "lead (planner)")
  |> should.be_true()
}

pub fn team_to_tool_debate_description_test() {
  let spec =
    TeamSpec(
      name: "debate",
      description: "Debate team",
      members: [],
      strategy: DebateAndConsensus(max_debate_rounds: 3),
      context_scope: SharedFacts,
      max_rounds: 4,
      synthesis_model: "mock",
      synthesis_max_tokens: 512,
    )
  let tool = team.team_to_tool(spec)
  string.contains(option.unwrap(tool.description, ""), "debate and consensus")
  |> should.be_true()
  string.contains(option.unwrap(tool.description, ""), "max 3 rounds")
  |> should.be_true()
}

// ---------------------------------------------------------------------------
// TeamResult structure tests
// ---------------------------------------------------------------------------

pub fn team_result_construction_test() {
  let result =
    team.TeamResult(
      synthesis: "Combined findings",
      per_agent_results: [
        #("researcher", "Found X"),
        #("analyst", "Analysed Y"),
      ],
      rounds_used: 1,
      consensus_reached: True,
      total_input_tokens: 1000,
      total_output_tokens: 500,
      total_duration_ms: 5000,
    )
  result.consensus_reached |> should.be_true()
  result.rounds_used |> should.equal(1)
  list.length(result.per_agent_results) |> should.equal(2)
}

// ---------------------------------------------------------------------------
// MemberResult construction test
// ---------------------------------------------------------------------------

pub fn member_result_construction_test() {
  let mr =
    MemberResult(
      agent: "researcher",
      role: "lead",
      result: "Found important data",
      input_tokens: 500,
      output_tokens: 200,
    )
  mr.agent |> should.equal("researcher")
  mr.role |> should.equal("lead")
}

// ---------------------------------------------------------------------------
// Context scope tests
// ---------------------------------------------------------------------------

pub fn context_scope_shared_facts_test() {
  let _scope: ContextScope = SharedFacts
  should.be_true(True)
}

pub fn context_scope_independent_test() {
  let _scope: ContextScope = Independent
  should.be_true(True)
}

// ---------------------------------------------------------------------------
// TeamContext construction test
// ---------------------------------------------------------------------------

pub fn team_context_fields_test() {
  // Just verify the type can be constructed with all fields
  // (actual orchestration tested via integration)
  let spec = make_research_team()
  spec.synthesis_model |> should.equal("mock-model")
  spec.synthesis_max_tokens |> should.equal(2048)
  spec.max_rounds |> should.equal(3)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_research_team() -> team.TeamSpec {
  TeamSpec(
    name: "deep-research",
    description: "Multi-perspective research team",
    members: [
      TeamMember(
        agent_name: "researcher",
        role: "academic_researcher",
        perspective: "Focus on peer-reviewed papers and arxiv preprints",
      ),
      TeamMember(
        agent_name: "researcher",
        role: "industry_analyst",
        perspective: "Focus on industry reports and market data",
      ),
    ],
    strategy: ParallelMerge,
    context_scope: SharedFacts,
    max_rounds: 3,
    synthesis_model: "mock-model",
    synthesis_max_tokens: 2048,
  )
}
