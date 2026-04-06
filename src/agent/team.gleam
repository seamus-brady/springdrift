//// Agent Teams — coordinated groups of agents working on the same problem.
////
//// A team is dispatched like a single agent from the cognitive loop's
//// perspective. The team orchestrator spawns as a process, coordinates
//// member agents according to a strategy (ParallelMerge, Pipeline,
//// DebateAndConsensus), synthesises results via an LLM call, and sends
//// AgentComplete back to the cognitive loop.
////
//// Teams are "virtual agents" — they appear as tools (team_<name>) and
//// produce AgentComplete outcomes. The cognitive loop doesn't need to know
//// the internal coordination details.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types.{
  type AgentOutcome, type AgentTask, type CognitiveMessage, AgentComplete,
  AgentFailure, AgentSuccess, AgentTask,
}
import cycle_log
import dag/types as dag_types
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/provider.{type Provider}
import llm/request
import llm/response
import llm/tool
import llm/types as llm_types
import narrative/librarian
import slog

@external(erlang, "springdrift_ffi", "monotonic_now_ms")
fn monotonic_now_ms() -> Int

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

// ---------------------------------------------------------------------------
// Team specification
// ---------------------------------------------------------------------------

/// A team is a coordinated group of agents with a coordination strategy.
pub type TeamSpec {
  TeamSpec(
    name: String,
    description: String,
    members: List(TeamMember),
    strategy: TeamStrategy,
    context_scope: ContextScope,
    max_rounds: Int,
    synthesis_model: String,
    synthesis_max_tokens: Int,
  )
}

/// A team member — references a registered agent by name with a role overlay.
pub type TeamMember {
  TeamMember(agent_name: String, role: String, perspective: String)
}

/// How team members collaborate.
pub type TeamStrategy {
  /// All agents work simultaneously, results merged by synthesis LLM.
  ParallelMerge
  /// Agents work in sequence; each receives the prior agent's output.
  TeamPipeline
  /// Agents produce independent analyses, then debate disagreements.
  DebateAndConsensus(max_debate_rounds: Int)
  /// One lead agent orchestrates, delegating to specialists as needed.
  /// The lead receives all specialist results and produces the final output.
  LeadWithSpecialists(lead: String)
}

/// What context is shared between team members.
pub type ContextScope {
  /// Team members share working memory (default for most teams)
  SharedFacts
  /// No sharing — independent work, merged at synthesis only
  Independent
}

/// Result from a completed team execution.
pub type TeamResult {
  TeamResult(
    synthesis: String,
    per_agent_results: List(#(String, String)),
    rounds_used: Int,
    consensus_reached: Bool,
    total_input_tokens: Int,
    total_output_tokens: Int,
    total_duration_ms: Int,
  )
}

// ---------------------------------------------------------------------------
// Tool generation
// ---------------------------------------------------------------------------

/// Build a Tool definition from a TeamSpec so the LLM can dispatch teams.
pub fn team_to_tool(spec: TeamSpec) -> llm_types.Tool {
  let member_names =
    list.map(spec.members, fn(m) { m.role <> " (" <> m.agent_name <> ")" })
  let member_desc = string.join(member_names, ", ")
  let strategy_desc = case spec.strategy {
    ParallelMerge -> "parallel merge"
    TeamPipeline -> "sequential pipeline"
    DebateAndConsensus(rounds) ->
      "debate and consensus (max " <> int.to_string(rounds) <> " rounds)"
    LeadWithSpecialists(lead) -> "lead (" <> lead <> ") with specialists"
  }
  tool.new("team_" <> spec.name)
  |> tool.with_description(
    spec.description
    <> " [Team: "
    <> member_desc
    <> " | Strategy: "
    <> strategy_desc
    <> "]",
  )
  |> tool.add_string_param("instruction", "Task for the team", True)
  |> tool.add_string_param("context", "Relevant context", False)
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Team orchestrator — spawned process that coordinates member agents
// ---------------------------------------------------------------------------

/// Config guards for team execution — enforced in the orchestrator.
pub type TeamGuards {
  TeamGuards(
    /// Max members per team (default: 5). Prevents runaway cost.
    max_members: Int,
    /// Max tokens across all team member executions + synthesis (default: 200000).
    token_budget: Int,
    /// Max debate rounds for DebateAndConsensus (default: 3). Overrides spec if lower.
    max_debate_rounds: Int,
  )
}

pub fn default_guards() -> TeamGuards {
  TeamGuards(max_members: 5, token_budget: 200_000, max_debate_rounds: 3)
}

/// Context needed to run a team.
pub type TeamContext {
  TeamContext(
    spec: TeamSpec,
    instruction: String,
    context: String,
    task_id: String,
    tool_use_id: String,
    parent_cycle_id: String,
    cognitive: Subject(CognitiveMessage),
    agent_subjects: List(#(String, Subject(AgentTask))),
    provider: Provider,
    depth: Int,
    guards: TeamGuards,
    librarian: Option(Subject(librarian.LibrarianMessage)),
  )
}

/// Start a team orchestrator. Spawns an unlinked process that runs the
/// strategy, synthesises results, and sends AgentComplete to the cognitive loop.
pub fn start(ctx: TeamContext) -> Nil {
  process.spawn_unlinked(fn() { run_team(ctx) })
  Nil
}

fn run_team(ctx: TeamContext) -> Nil {
  let start_ms = monotonic_now_ms()

  // Enforce config guards before running
  let member_count = list.length(ctx.spec.members)
  let result = case member_count > ctx.guards.max_members {
    True ->
      Error(
        "Team "
        <> ctx.spec.name
        <> " has "
        <> int.to_string(member_count)
        <> " members (max "
        <> int.to_string(ctx.guards.max_members)
        <> ")",
      )
    False ->
      case ctx.spec.strategy {
        ParallelMerge -> run_parallel_merge(ctx)
        TeamPipeline -> run_pipeline(ctx)
        DebateAndConsensus(max_rounds) -> {
          // Apply debate round guard — use the lower of spec vs config
          let capped_rounds = case max_rounds > ctx.guards.max_debate_rounds {
            True -> ctx.guards.max_debate_rounds
            False -> max_rounds
          }
          run_debate_and_consensus(ctx, capped_rounds)
        }
        LeadWithSpecialists(lead) -> run_lead_with_specialists(ctx, lead)
      }
  }

  let duration_ms = monotonic_now_ms() - start_ms

  // Send outcome back to cognitive loop
  let outcome = case result {
    Ok(team_result) ->
      AgentSuccess(
        task_id: ctx.task_id,
        agent: "team:" <> ctx.spec.name,
        agent_id: "team_" <> ctx.spec.name,
        agent_human_name: "Team " <> ctx.spec.name,
        agent_cycle_id: ctx.task_id,
        result: team_result.synthesis,
        structured_result: None,
        instruction: ctx.instruction,
        tools_used: list.map(ctx.spec.members, fn(m) {
          "agent_" <> m.agent_name
        }),
        tool_call_details: [],
        tool_errors: [],
        input_tokens: team_result.total_input_tokens,
        output_tokens: team_result.total_output_tokens,
        duration_ms:,
      )
    Error(err) ->
      AgentFailure(
        task_id: ctx.task_id,
        agent: "team:" <> ctx.spec.name,
        agent_id: "team_" <> ctx.spec.name,
        agent_human_name: "Team " <> ctx.spec.name,
        agent_cycle_id: ctx.task_id,
        error: err,
        instruction: ctx.instruction,
        tools_used: [],
        tool_call_details: [],
        input_tokens: 0,
        output_tokens: 0,
        duration_ms:,
      )
  }

  process.send(ctx.cognitive, AgentComplete(outcome:))
}

// ---------------------------------------------------------------------------
// Strategy: ParallelMerge
// ---------------------------------------------------------------------------

fn run_parallel_merge(ctx: TeamContext) -> Result(TeamResult, String) {
  let self: Subject(CognitiveMessage) = process.new_subject()

  // Dispatch all member agents simultaneously
  let dispatched =
    dispatch_members(ctx, self, ctx.spec.members, ctx.instruction, ctx.context)

  // Collect all results
  let results =
    collect_results(self, list.length(dispatched), ctx.spec.max_rounds * 30_000)

  case results {
    Error(e) -> Error(e)
    Ok(member_results) -> {
      let #(tokens_in, tokens_out) = sum_tokens(member_results)
      // Synthesise
      let synthesis =
        synthesise_results(ctx, member_results, "parallel_merge", 1)
      case synthesis {
        Error(e) -> Error("Synthesis failed: " <> e)
        Ok(#(text, syn_in, syn_out)) ->
          Ok(TeamResult(
            synthesis: text,
            per_agent_results: list.map(member_results, fn(r) {
              #(r.agent, r.result)
            }),
            rounds_used: 1,
            consensus_reached: True,
            total_input_tokens: tokens_in + syn_in,
            total_output_tokens: tokens_out + syn_out,
            total_duration_ms: 0,
          ))
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Strategy: Pipeline
// ---------------------------------------------------------------------------

fn run_pipeline(ctx: TeamContext) -> Result(TeamResult, String) {
  let self: Subject(CognitiveMessage) = process.new_subject()

  // Dispatch members one at a time, chaining results
  run_pipeline_step(ctx, self, ctx.spec.members, ctx.context, [], 0, 0)
}

fn run_pipeline_step(
  ctx: TeamContext,
  self: Subject(CognitiveMessage),
  remaining: List(TeamMember),
  accumulated_context: String,
  results: List(MemberResult),
  tokens_in: Int,
  tokens_out: Int,
) -> Result(TeamResult, String) {
  case remaining {
    [] -> {
      // All pipeline stages complete — synthesise
      let synthesis = synthesise_results(ctx, results, "pipeline", 1)
      case synthesis {
        Error(e) -> Error("Pipeline synthesis failed: " <> e)
        Ok(#(text, syn_in, syn_out)) ->
          Ok(TeamResult(
            synthesis: text,
            per_agent_results: list.map(results, fn(r) { #(r.agent, r.result) }),
            rounds_used: list.length(results),
            consensus_reached: True,
            total_input_tokens: tokens_in + syn_in,
            total_output_tokens: tokens_out + syn_out,
            total_duration_ms: 0,
          ))
      }
    }
    [member, ..rest] -> {
      // Dispatch single member with accumulated context
      let enriched_instruction =
        ctx.instruction
        <> case accumulated_context {
          "" -> ""
          ctx_text ->
            "\n\n<prior_stage_output>\n"
            <> ctx_text
            <> "\n</prior_stage_output>"
        }

      let dispatched =
        dispatch_members(ctx, self, [member], enriched_instruction, ctx.context)

      case list.length(dispatched) {
        0 -> Error("Pipeline: agent " <> member.agent_name <> " not available")
        _ -> {
          let collected = collect_results(self, 1, 120_000)
          case collected {
            Error(e) -> Error("Pipeline stage failed: " <> e)
            Ok(stage_results) -> {
              let stage_result = case stage_results {
                [r, ..] -> r
                [] ->
                  MemberResult(
                    agent: member.agent_name,
                    role: member.role,
                    result: "[no result]",
                    input_tokens: 0,
                    output_tokens: 0,
                  )
              }
              let new_context = stage_result.result
              run_pipeline_step(
                ctx,
                self,
                rest,
                new_context,
                list.append(results, [stage_result]),
                tokens_in + stage_result.input_tokens,
                tokens_out + stage_result.output_tokens,
              )
            }
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Strategy: DebateAndConsensus
// ---------------------------------------------------------------------------

fn run_debate_and_consensus(
  ctx: TeamContext,
  max_rounds: Int,
) -> Result(TeamResult, String) {
  let self: Subject(CognitiveMessage) = process.new_subject()

  // Round 1: independent analysis from all members
  let dispatched =
    dispatch_members(ctx, self, ctx.spec.members, ctx.instruction, ctx.context)
  let initial_results =
    collect_results(self, list.length(dispatched), ctx.spec.max_rounds * 30_000)

  case initial_results {
    Error(e) -> Error("Debate round 1 failed: " <> e)
    Ok(round1) -> {
      // Check for consensus or run debate rounds
      run_debate_rounds(ctx, self, round1, 1, max_rounds)
    }
  }
}

fn run_debate_rounds(
  ctx: TeamContext,
  self: Subject(CognitiveMessage),
  current_results: List(MemberResult),
  round: Int,
  max_rounds: Int,
) -> Result(TeamResult, String) {
  // Check if we've exhausted debate rounds
  case round >= max_rounds {
    True -> {
      // Force synthesis — no more debate
      let #(tokens_in, tokens_out) = sum_tokens(current_results)
      let synthesis =
        synthesise_results(ctx, current_results, "debate_final", round)
      case synthesis {
        Error(e) -> Error("Debate synthesis failed: " <> e)
        Ok(#(text, syn_in, syn_out)) ->
          Ok(TeamResult(
            synthesis: text,
            per_agent_results: list.map(current_results, fn(r) {
              #(r.agent, r.result)
            }),
            rounds_used: round,
            consensus_reached: False,
            total_input_tokens: tokens_in + syn_in,
            total_output_tokens: tokens_out + syn_out,
            total_duration_ms: 0,
          ))
      }
    }
    False -> {
      // Build debate context from all current results
      let debate_context = build_debate_context(current_results, round)

      // Re-dispatch all members with debate context
      let debate_instruction =
        ctx.instruction
        <> "\n\n<debate_round round=\""
        <> int.to_string(round + 1)
        <> "\">\n"
        <> debate_context
        <> "\nReview the other perspectives above. Revise your analysis if warranted, "
        <> "or explain why you maintain your position. Focus on areas of disagreement.\n"
        <> "</debate_round>"

      let dispatched =
        dispatch_members(
          ctx,
          self,
          ctx.spec.members,
          debate_instruction,
          ctx.context,
        )
      let round_results =
        collect_results(
          self,
          list.length(dispatched),
          ctx.spec.max_rounds * 30_000,
        )

      case round_results {
        Error(e) ->
          Error("Debate round " <> int.to_string(round + 1) <> " failed: " <> e)
        Ok(new_results) -> {
          // Check for convergence: if results are similar enough, synthesise
          let converged = check_convergence(new_results)
          case converged {
            True -> {
              let #(tokens_in, tokens_out) = sum_tokens(new_results)
              let synthesis =
                synthesise_results(
                  ctx,
                  new_results,
                  "debate_consensus",
                  round + 1,
                )
              case synthesis {
                Error(e) -> Error("Consensus synthesis failed: " <> e)
                Ok(#(text, syn_in, syn_out)) ->
                  Ok(TeamResult(
                    synthesis: text,
                    per_agent_results: list.map(new_results, fn(r) {
                      #(r.agent, r.result)
                    }),
                    rounds_used: round + 1,
                    consensus_reached: True,
                    total_input_tokens: tokens_in + syn_in,
                    total_output_tokens: tokens_out + syn_out,
                    total_duration_ms: 0,
                  ))
              }
            }
            False ->
              run_debate_rounds(ctx, self, new_results, round + 1, max_rounds)
          }
        }
      }
    }
  }
}

fn build_debate_context(results: List(MemberResult), round: Int) -> String {
  let _ = round
  list.map(results, fn(r) {
    "<perspective role=\""
    <> r.role
    <> "\" agent=\""
    <> r.agent
    <> "\">\n"
    <> r.result
    <> "\n</perspective>"
  })
  |> string.join("\n\n")
}

// Simple convergence check: if all results share >60% of their significant words.
// ---------------------------------------------------------------------------
// Strategy: LeadWithSpecialists
// ---------------------------------------------------------------------------

fn run_lead_with_specialists(
  ctx: TeamContext,
  lead_name: String,
) -> Result(TeamResult, String) {
  let self: Subject(CognitiveMessage) = process.new_subject()

  // Separate lead from specialists
  let specialists =
    list.filter(ctx.spec.members, fn(m) { m.agent_name != lead_name })

  // Step 1: dispatch all specialists in parallel
  let dispatched =
    dispatch_members(ctx, self, specialists, ctx.instruction, ctx.context)

  // Step 2: collect specialist results
  let specialist_results =
    collect_results(self, list.length(dispatched), ctx.spec.max_rounds * 30_000)

  case specialist_results {
    Error(e) -> Error("Specialist phase failed: " <> e)
    Ok(spec_results) -> {
      // Step 3: dispatch lead with all specialist results as context
      let specialist_context =
        list.map(spec_results, fn(r) {
          "<specialist role=\""
          <> r.role
          <> "\" agent=\""
          <> r.agent
          <> "\">\n"
          <> r.result
          <> "\n</specialist>"
        })
        |> string.join("\n\n")

      let lead_instruction =
        ctx.instruction
        <> "\n\n<specialist_results>\n"
        <> specialist_context
        <> "\n</specialist_results>\n\n"
        <> "You are the lead. Synthesise the specialist findings above into "
        <> "a comprehensive response. Use their work as inputs to your analysis."

      let lead_members =
        list.filter(ctx.spec.members, fn(m) { m.agent_name == lead_name })
      let lead_dispatched =
        dispatch_members(ctx, self, lead_members, lead_instruction, ctx.context)

      case list.length(lead_dispatched) {
        0 -> Error("Lead agent " <> lead_name <> " not available")
        _ -> {
          let lead_result = collect_results(self, 1, 120_000)
          case lead_result {
            Error(e) -> Error("Lead phase failed: " <> e)
            Ok(lead_results) -> {
              let all_results = list.append(spec_results, lead_results)
              let #(tokens_in, tokens_out) = sum_tokens(all_results)
              // The lead's result IS the synthesis — no separate synthesis needed
              let final_text = case lead_results {
                [r, ..] -> r.result
                [] -> "[Lead produced no output]"
              }
              Ok(TeamResult(
                synthesis: final_text,
                per_agent_results: list.map(all_results, fn(r) {
                  #(r.agent, r.result)
                }),
                rounds_used: 2,
                consensus_reached: True,
                total_input_tokens: tokens_in,
                total_output_tokens: tokens_out,
                total_duration_ms: 0,
              ))
            }
          }
        }
      }
    }
  }
}

fn check_convergence(results: List(MemberResult)) -> Bool {
  case results {
    [] | [_] -> True
    [first, ..rest] -> {
      let first_words = significant_words(first.result)
      list.all(rest, fn(r) {
        let r_words = significant_words(r.result)
        let overlap =
          list.filter(first_words, fn(w) { list.contains(r_words, w) })
        let overlap_ratio = case list.length(first_words) {
          0 -> 1.0
          n -> int.to_float(list.length(overlap)) /. int.to_float(n)
        }
        overlap_ratio >. 0.6
      })
    }
  }
}

fn significant_words(text: String) -> List(String) {
  string.split(text, " ")
  |> list.map(string.lowercase)
  |> list.filter(fn(w) { string.length(w) > 4 })
  |> list.unique()
}

// ---------------------------------------------------------------------------
// Agent dispatch and result collection
// ---------------------------------------------------------------------------

/// Internal result from a single team member.
pub type MemberResult {
  MemberResult(
    agent: String,
    role: String,
    result: String,
    input_tokens: Int,
    output_tokens: Int,
  )
}

/// Dispatch team members to their respective agents.
fn dispatch_members(
  ctx: TeamContext,
  self: Subject(CognitiveMessage),
  members: List(TeamMember),
  instruction: String,
  context: String,
) -> List(String) {
  list.filter_map(members, fn(member) {
    let found =
      list.find(ctx.agent_subjects, fn(s: #(String, Subject(AgentTask))) {
        s.0 == member.agent_name
      })
    case found {
      Ok(#(_, task_subject)) -> {
        let task_id = cycle_log.generate_uuid()
        let enriched_instruction =
          "<team_role>"
          <> member.role
          <> "</team_role>\n<perspective>"
          <> member.perspective
          <> "</perspective>\n\n"
          <> instruction

        let task =
          AgentTask(
            task_id:,
            tool_use_id: task_id,
            instruction: enriched_instruction,
            context:,
            // Parent is the TEAM node, not the cognitive cycle
            parent_cycle_id: ctx.task_id,
            reply_to: self,
            depth: ctx.depth + 1,
            max_turns_override: None,
          )
        process.send(task_subject, task)

        // Index member agent cycle as NodePending in DAG so inspect_cycle
        // can see team member activity nested under the team node
        case ctx.librarian {
          Some(lib) ->
            process.send(
              lib,
              librarian.IndexNode(node: dag_types.CycleNode(
                cycle_id: task_id,
                parent_id: Some(ctx.task_id),
                node_type: dag_types.AgentCycle,
                timestamp: get_datetime(),
                outcome: dag_types.NodePending,
                model: "",
                complexity: "team_member:" <> member.role,
                tool_calls: [],
                dprime_gates: [],
                tokens_in: 0,
                tokens_out: 0,
                duration_ms: 0,
                agent_output: None,
                instance_name: "",
                instance_id: "",
              )),
            )
          None -> Nil
        }
        slog.debug(
          "agent/team",
          "dispatch",
          "Dispatched "
            <> member.role
            <> " ("
            <> member.agent_name
            <> ") for team "
            <> ctx.spec.name,
          Some(ctx.task_id),
        )
        Ok(task_id)
      }
      Error(_) -> {
        slog.warn(
          "agent/team",
          "dispatch",
          "Agent " <> member.agent_name <> " not found in registry",
          Some(ctx.task_id),
        )
        Error(Nil)
      }
    }
  })
}

/// Collect results from dispatched agents. Blocks until all complete or timeout.
fn collect_results(
  self: Subject(CognitiveMessage),
  expected: Int,
  timeout_ms: Int,
) -> Result(List(MemberResult), String) {
  collect_results_loop(self, expected, timeout_ms, [])
}

fn collect_results_loop(
  self: Subject(CognitiveMessage),
  remaining: Int,
  timeout_ms: Int,
  acc: List(MemberResult),
) -> Result(List(MemberResult), String) {
  case remaining <= 0 {
    True -> Ok(acc)
    False -> {
      case process.receive(self, timeout_ms) {
        Error(_) ->
          Error(
            "Timeout waiting for team member ("
            <> int.to_string(remaining)
            <> " still pending)",
          )
        Ok(msg) ->
          case msg {
            AgentComplete(outcome:) -> {
              let member_result = outcome_to_member_result(outcome)
              collect_results_loop(self, remaining - 1, timeout_ms, [
                member_result,
                ..acc
              ])
            }
            // Ignore progress messages and other cognitive messages
            _ -> collect_results_loop(self, remaining, timeout_ms, acc)
          }
      }
    }
  }
}

fn outcome_to_member_result(outcome: AgentOutcome) -> MemberResult {
  case outcome {
    AgentSuccess(agent:, result:, input_tokens:, output_tokens:, ..) ->
      MemberResult(agent:, role: agent, result:, input_tokens:, output_tokens:)
    AgentFailure(agent:, error:, input_tokens:, output_tokens:, ..) ->
      MemberResult(
        agent:,
        role: agent,
        result: "[FAILED: " <> error <> "]",
        input_tokens:,
        output_tokens:,
      )
  }
}

// ---------------------------------------------------------------------------
// Synthesis — LLM call to merge team results
// ---------------------------------------------------------------------------

fn synthesise_results(
  ctx: TeamContext,
  results: List(MemberResult),
  mode: String,
  round: Int,
) -> Result(#(String, Int, Int), String) {
  let results_xml =
    list.map(results, fn(r) {
      "<agent_result role=\""
      <> r.role
      <> "\" agent=\""
      <> r.agent
      <> "\">\n"
      <> r.result
      <> "\n</agent_result>"
    })
    |> string.join("\n\n")

  let system_prompt =
    "You are synthesising results from a team of "
    <> int.to_string(list.length(results))
    <> " agents working on the same task. "
    <> "Mode: "
    <> mode
    <> ", round "
    <> int.to_string(round)
    <> ".\n\n"
    <> "Combine the agents' findings into a single, coherent response. "
    <> "Resolve any contradictions by noting the disagreement. "
    <> "Preserve key details and attributions from each agent. "
    <> "Do not add information not present in the agent results."

  let user_prompt =
    "<task>"
    <> ctx.instruction
    <> "</task>\n\n"
    <> "<team_results>\n"
    <> results_xml
    <> "\n</team_results>\n\n"
    <> "Synthesise these results into a single coherent response."

  let req =
    request.new(ctx.spec.synthesis_model, ctx.spec.synthesis_max_tokens)
    |> request.with_system(system_prompt)
    |> request.with_messages([
      llm_types.Message(role: llm_types.User, content: [
        llm_types.TextContent(text: user_prompt),
      ]),
    ])

  case ctx.provider.chat(req) {
    Ok(resp) -> {
      let text = response.text(resp)
      Ok(#(text, resp.usage.input_tokens, resp.usage.output_tokens))
    }
    Error(err) -> {
      slog.log_error(
        "agent/team",
        "synthesise",
        "LLM synthesis failed: " <> string.inspect(err),
        Some(ctx.task_id),
      )
      // Fallback: concatenate results
      let fallback =
        list.map(results, fn(r) {
          "## " <> r.role <> " (" <> r.agent <> ")\n\n" <> r.result
        })
        |> string.join("\n\n---\n\n")
      Ok(#(fallback, 0, 0))
    }
  }
}

fn sum_tokens(results: List(MemberResult)) -> #(Int, Int) {
  list.fold(results, #(0, 0), fn(acc, r) {
    #(acc.0 + r.input_tokens, acc.1 + r.output_tokens)
  })
}
