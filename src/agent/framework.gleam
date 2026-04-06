// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types.{
  type AgentIdentity, type AgentOutcome, type AgentSpec, type AgentTask,
  type CognitiveMessage, AgentComplete, AgentFailure, AgentIdentity,
  AgentProgress, AgentQuestion, AgentSpec, AgentSuccess, DelegationProgress,
}
import context
import cycle_log
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process.{type ExitMessage, type Pid, type Subject}
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import llm/request
import llm/response
import llm/retry
import llm/types as llm_types
import paths
import slog
import xstructor
import xstructor/schemas

// inter_turn_delay_ms is now on AgentSpec — no module constant needed.

@external(erlang, "springdrift_ffi", "monotonic_now_ms")
fn monotonic_now_ms() -> Int

// ---------------------------------------------------------------------------
// Internal types
// ---------------------------------------------------------------------------

type ActiveTask {
  ActiveTask(task_id: String, pid: Pid, reply_to: Subject(CognitiveMessage))
}

type AgentState {
  AgentState(active: List(ActiveTask), identity: AgentIdentity)
}

type ReactStats {
  ReactStats(
    tools_used: List(String),
    tool_call_details: List(types.ToolCallDetail),
    input_tokens: Int,
    output_tokens: Int,
  )
}

type ReactResult {
  ReactResult(result: Result(String, String), stats: ReactStats)
}

type AgentEvent {
  NewTask(AgentTask)
  TaskDone(
    task_id: String,
    agent_cycle_id: String,
    react_result: ReactResult,
    instruction: String,
    duration_ms: Int,
  )
  WorkerExited(ExitMessage)
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start an agent gen-server process. Returns the pid (linked to caller,
/// i.e. the supervisor) and a Subject for sending tasks.
pub fn start_agent(
  spec: AgentSpec,
) -> Result(#(Pid, Subject(types.AgentTask)), String) {
  slog.info("framework", "start_agent", "Starting agent: " <> spec.name, None)
  let setup = process.new_subject()
  let pid =
    process.spawn(fn() {
      process.trap_exits(True)
      let task_subj = process.new_subject()
      let done_subj = process.new_subject()
      let identity = make_identity(spec.human_name)
      process.send(setup, Ok(task_subj))
      agent_loop(spec, task_subj, done_subj, AgentState(active: [], identity:))
    })
  case process.receive(setup, 5000) {
    Ok(Ok(subj)) -> Ok(#(pid, subj))
    Ok(Error(reason)) -> Error(reason)
    Error(_) -> Error("Agent failed to start: " <> spec.name)
  }
}

// ---------------------------------------------------------------------------
// Agent gen-server loop
// ---------------------------------------------------------------------------

fn agent_loop(
  spec: AgentSpec,
  task_subj: Subject(AgentTask),
  done_subj: Subject(#(String, String, ReactResult, String, Int)),
  state: AgentState,
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(task_subj, fn(task) { NewTask(task) })
    |> process.select_map(done_subj, fn(done) {
      TaskDone(done.0, done.1, done.2, done.3, done.4)
    })
    |> process.select_trapped_exits(WorkerExited)

  case process.selector_receive_forever(selector) {
    NewTask(task) -> {
      let captured_done_subj = done_subj
      let captured_instruction = task.instruction
      let worker_pid =
        process.spawn(fn() {
          let #(agent_cycle_id, react_result, duration_ms) =
            do_react_loop(spec, task)
          process.send(captured_done_subj, #(
            task.task_id,
            agent_cycle_id,
            react_result,
            captured_instruction,
            duration_ms,
          ))
        })
      let active_task =
        ActiveTask(
          task_id: task.task_id,
          pid: worker_pid,
          reply_to: task.reply_to,
        )
      agent_loop(
        spec,
        task_subj,
        done_subj,
        AgentState(..state, active: [active_task, ..state.active]),
      )
    }

    TaskDone(task_id, agent_cycle_id, react_result, instruction, duration_ms) -> {
      case find_active(state.active, task_id) {
        None -> agent_loop(spec, task_subj, done_subj, state)
        Some(active) -> {
          let outcome =
            outcome_from_result(
              task_id,
              spec.name,
              state.identity,
              agent_cycle_id,
              react_result,
              instruction,
              duration_ms,
            )
          process.send(active.reply_to, AgentComplete(outcome:))
          agent_loop(
            spec,
            task_subj,
            done_subj,
            AgentState(..state, active: remove_active(state.active, task_id)),
          )
        }
      }
    }

    WorkerExited(exit_msg) -> {
      case find_active_by_pid(state.active, exit_msg.pid) {
        None -> agent_loop(spec, task_subj, done_subj, state)
        Some(active) -> {
          let outcome =
            AgentFailure(
              task_id: active.task_id,
              agent: spec.name,
              agent_id: state.identity.agent_id,
              agent_human_name: state.identity.human_name,
              agent_cycle_id: "",
              error: "Worker crashed",
              instruction: "",
              tools_used: [],
              tool_call_details: [],
              input_tokens: 0,
              output_tokens: 0,
              duration_ms: 0,
            )
          process.send(active.reply_to, AgentComplete(outcome:))
          agent_loop(
            spec,
            task_subj,
            done_subj,
            AgentState(
              ..state,
              active: remove_active(state.active, active.task_id),
            ),
          )
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Inner react loop (runs in task worker process)
// ---------------------------------------------------------------------------

fn do_react_loop(
  spec: AgentSpec,
  task: AgentTask,
) -> #(String, ReactResult, Int) {
  // Use the task_id as the cycle_id for logging — this matches the DAG node
  // indexed by the cognitive loop, so inspect_cycle(detail: "full") can find
  // the tool call entries.
  let agent_cycle_id = task.task_id
  // Resolve effective max_turns: override capped at 3x default (safety ceiling)
  let effective_max_turns = case task.max_turns_override {
    Some(n) -> int.min(n, spec.max_turns * 3)
    None -> spec.max_turns
  }
  let effective_spec = AgentSpec(..spec, max_turns: effective_max_turns)
  let req = build_agent_request(effective_spec, task)
  let start_ms = monotonic_now_ms()
  let initial_stats =
    ReactStats(
      tools_used: [],
      tool_call_details: [],
      input_tokens: 0,
      output_tokens: 0,
    )
  let react_result =
    do_react(
      req,
      effective_spec,
      effective_max_turns,
      0,
      agent_cycle_id,
      task.reply_to,
      initial_stats,
      task.depth,
    )
  let duration_ms = monotonic_now_ms() - start_ms
  #(agent_cycle_id, react_result, duration_ms)
}

fn do_react(
  req: llm_types.LlmRequest,
  spec: AgentSpec,
  remaining: Int,
  consecutive_errors: Int,
  cycle_id: String,
  cognitive: Subject(CognitiveMessage),
  stats: ReactStats,
  task_depth: Int,
) -> ReactResult {
  let current_turn = spec.max_turns - remaining + 1
  slog.debug(
    "framework",
    "do_react",
    spec.name <> " turn " <> int.to_string(current_turn),
    Some(cycle_id),
  )
  case remaining {
    0 -> ReactResult(result: Error("max turns reached"), stats:)
    _ ->
      case
        retry.call_with_retry(req, spec.provider, retry.default_retry_config())
      {
        Error(e) ->
          ReactResult(result: Error(response.error_message(e)), stats:)
        Ok(resp) -> {
          let updated_stats =
            ReactStats(
              ..stats,
              input_tokens: stats.input_tokens + resp.usage.input_tokens,
              output_tokens: stats.output_tokens + resp.usage.output_tokens,
            )
          case response.needs_tool_execution(resp) {
            False ->
              ReactResult(result: Ok(response.text(resp)), stats: updated_stats)
            True -> {
              let calls = response.tool_calls(resp)
              let tool_names = list.map(calls, fn(c) { c.name })
              // Execute tools and capture details
              let call_results =
                list.map(calls, fn(call) {
                  cycle_log.log_tool_call(cycle_id, call, spec.redact_secrets)
                  let result = execute_tool(call, spec, cognitive)
                  cycle_log.log_tool_result(
                    cycle_id,
                    result,
                    spec.redact_secrets,
                  )
                  #(call, result)
                })
              let results = list.map(call_results, fn(cr) { cr.1 })
              let new_details =
                list.map(call_results, fn(cr) {
                  let #(call, result) = cr
                  let #(output, success) = case result {
                    llm_types.ToolSuccess(content: c, ..) -> #(c, True)
                    llm_types.ToolFailure(error: e, ..) -> #(e, False)
                  }
                  types.ToolCallDetail(
                    name: call.name,
                    input_summary: string.slice(call.input_json, 0, 500),
                    output_summary: string.slice(output, 0, 500),
                    success:,
                  )
                })
              let stats_with_tools =
                ReactStats(
                  ..updated_stats,
                  tools_used: list.append(updated_stats.tools_used, tool_names),
                  tool_call_details: list.append(
                    updated_stats.tool_call_details,
                    new_details,
                  ),
                )
              let has_failure =
                list.any(results, fn(r) {
                  case r {
                    llm_types.ToolFailure(..) -> True
                    _ -> False
                  }
                })
              let new_consecutive = case has_failure {
                True -> consecutive_errors + 1
                False -> 0
              }
              // Report progress to cognitive loop
              let last_tool_name = case tool_names {
                [name, ..] -> name
                [] -> ""
              }
              process.send(
                cognitive,
                AgentProgress(progress: DelegationProgress(
                  task_id: cycle_id,
                  agent: spec.name,
                  turn: current_turn,
                  max_turns: spec.max_turns,
                  input_tokens: stats_with_tools.input_tokens,
                  output_tokens: stats_with_tools.output_tokens,
                  last_tool: last_tool_name,
                  depth: task_depth,
                )),
              )

              case new_consecutive >= spec.max_consecutive_errors {
                True ->
                  ReactResult(
                    result: Error("too many consecutive tool errors"),
                    stats: stats_with_tools,
                  )
                False -> {
                  // Pace requests — brief pause between turns
                  process.sleep(spec.inter_turn_delay_ms)
                  let next =
                    request.with_tool_results(req, resp.content, results)
                  // Inject turn budget warning when running low
                  let next = case remaining - 1 {
                    r if r <= 2 && r > 0 -> {
                      let warning_msg =
                        llm_types.Message(role: llm_types.User, content: [
                          llm_types.TextContent(
                            text: "[SYSTEM: You have "
                            <> int.to_string(r)
                            <> " turn(s) remaining. Wrap up and return your best result now.]",
                          ),
                        ])
                      llm_types.LlmRequest(
                        ..next,
                        messages: list.append(next.messages, [warning_msg]),
                      )
                    }
                    _ -> next
                  }
                  // Apply context trimming if configured, always ensure alternation
                  let trimmed = case spec.max_context_messages {
                    Some(max) ->
                      llm_types.LlmRequest(
                        ..next,
                        messages: context.trim(next.messages, max),
                      )
                    None ->
                      llm_types.LlmRequest(
                        ..next,
                        messages: context.ensure_alternation(next.messages),
                      )
                  }
                  do_react(
                    trimmed,
                    spec,
                    remaining - 1,
                    new_consecutive,
                    cycle_id,
                    cognitive,
                    stats_with_tools,
                    task_depth,
                  )
                }
              }
            }
          }
        }
      }
  }
}

/// Execute a tool call, routing request_human_input through the cognitive loop.
fn execute_tool(
  call: llm_types.ToolCall,
  spec: AgentSpec,
  cognitive: Subject(CognitiveMessage),
) -> llm_types.ToolResult {
  slog.debug(
    "framework",
    "execute_tool",
    spec.name <> " -> " <> call.name,
    None,
  )
  case call.name {
    "request_human_input" -> {
      let question = parse_human_input_question(call.input_json)
      let answer_subj = process.new_subject()
      process.send(
        cognitive,
        AgentQuestion(question:, agent: spec.name, reply_to: answer_subj),
      )
      let answer = process.receive_forever(answer_subj)
      llm_types.ToolSuccess(tool_use_id: call.id, content: answer)
    }
    _ -> spec.tool_executor(call)
  }
}

pub fn parse_human_input_question(input_json: String) -> String {
  let decoder = {
    use question <- decode.field("question", decode.string)
    decode.success(question)
  }
  case json.parse(input_json, decoder) {
    Ok(q) -> q
    Error(_) -> input_json
  }
}

fn build_agent_request(spec: AgentSpec, task: AgentTask) -> llm_types.LlmRequest {
  let user_content = case task.context {
    "" -> task.instruction
    ctx -> task.instruction <> "\n\nContext:\n" <> ctx
  }
  let budget_note =
    "\n\n## Turn Budget\nYou have "
    <> int.to_string(spec.max_turns)
    <> " turns for this task. Plan your tool usage accordingly. When you have 2 turns remaining, wrap up and return your best result."
  let base =
    request.new(spec.model, spec.max_tokens)
    |> request.with_system(spec.system_prompt <> budget_note)
    |> request.with_user_message(user_content)
  case spec.tools {
    [] -> base
    tools -> request.with_tools(base, tools)
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn outcome_from_result(
  task_id: String,
  agent: String,
  identity: AgentIdentity,
  agent_cycle_id: String,
  react_result: ReactResult,
  instruction: String,
  duration_ms: Int,
) -> AgentOutcome {
  let stats = react_result.stats
  // Deduplicate tool names
  let unique_tools = list.unique(stats.tools_used)
  let structured = case react_result.result {
    Ok(text) ->
      Some(types.AgentResult(
        final_text: text,
        agent_id: identity.agent_id,
        cycle_id: agent_cycle_id,
        findings: build_findings(agent, stats, text),
      ))
    Error(_) -> None
  }
  // Extract tool errors — these are tools that failed during the react loop.
  // If non-empty on AgentSuccess, the agent LLM continued despite failures.
  let tool_errors =
    list.filter_map(stats.tool_call_details, fn(d) {
      case d.success {
        False -> Ok(d.name <> ": " <> d.output_summary)
        True -> Error(Nil)
      }
    })
  case react_result.result {
    Ok(text) ->
      AgentSuccess(
        task_id:,
        agent:,
        agent_id: identity.agent_id,
        agent_human_name: identity.human_name,
        agent_cycle_id:,
        result: text,
        structured_result: structured,
        instruction:,
        tools_used: unique_tools,
        tool_call_details: stats.tool_call_details,
        tool_errors:,
        input_tokens: stats.input_tokens,
        output_tokens: stats.output_tokens,
        duration_ms:,
      )
    Error(err) ->
      AgentFailure(
        task_id:,
        agent:,
        agent_id: identity.agent_id,
        agent_human_name: identity.human_name,
        agent_cycle_id:,
        error: err,
        instruction:,
        tools_used: unique_tools,
        tool_call_details: stats.tool_call_details,
        input_tokens: stats.input_tokens,
        output_tokens: stats.output_tokens,
        duration_ms:,
      )
  }
}

fn build_findings(
  agent: String,
  stats: ReactStats,
  final_text: String,
) -> types.AgentFindings {
  let details = stats.tool_call_details
  case agent {
    "researcher" -> {
      // Extract sources from web tool calls and dead ends from failures
      let sources =
        list.filter_map(details, fn(d) {
          case d.name == "web_search" || d.name == "fetch_url" {
            True ->
              Ok(
                types.DiscoveredSource(
                  url: d.input_summary,
                  title: d.output_summary,
                  relevance: case d.success {
                    True -> 1.0
                    False -> 0.0
                  },
                ),
              )
            False -> Error(Nil)
          }
        })
      let dead_ends =
        list.filter_map(details, fn(d) {
          case d.success {
            False -> Ok(d.name <> ": " <> d.output_summary)
            True -> Error(Nil)
          }
        })
      types.ResearcherFindings(sources:, facts: [], data_points: [], dead_ends:)
    }
    "planner" -> extract_planner_findings(final_text)
    "coder" -> {
      let files =
        list.filter_map(details, fn(d) {
          case d.name == "write_file" || d.name == "read_file" {
            True -> Ok(d.input_summary)
            False -> Error(Nil)
          }
        })
      let errors =
        list.filter_map(details, fn(d) {
          case d.success {
            False -> Ok(d.name <> ": " <> d.output_summary)
            True -> Error(Nil)
          }
        })
      types.CoderFindings(
        files_touched: list.unique(files),
        patterns_used: [],
        errors_fixed: errors,
        libraries: [],
      )
    }
    "writer" -> types.WriterFindings(word_count: 0, format: "", sections: [])
    _ -> types.GenericFindings(notes: list.unique(stats.tools_used))
  }
}

/// Extract planner findings from XML output using XStructor.
/// The planner agent outputs <plan> XML validated against planner_output_xsd.
/// Falls back to empty findings if validation or extraction fails.
fn extract_planner_findings(text: String) -> types.AgentFindings {
  let cleaned = xstructor.clean_response(text)

  // Compile schema (cached on disk after first call)
  let schema_result =
    xstructor.compile_schema(
      paths.schemas_dir(),
      "planner_output.xsd",
      schemas.planner_output_xsd,
    )

  case schema_result {
    Error(e) -> {
      slog.warn(
        "agent/framework",
        "extract_planner_findings",
        "Failed to compile planner schema: " <> e,
        None,
      )
      empty_planner_findings()
    }
    Ok(schema) ->
      case xstructor.validate(cleaned, schema) {
        Error(e) -> {
          slog.warn(
            "agent/framework",
            "extract_planner_findings",
            "Planner XML validation failed: " <> e,
            None,
          )
          empty_planner_findings()
        }
        Ok(_) ->
          case xstructor.extract(cleaned) {
            Error(_) -> empty_planner_findings()
            Ok(elements) -> {
              let steps = xstructor.extract_list(elements, "plan.steps.step")
              let complexity = case dict.get(elements, "plan.complexity") {
                Ok(c) -> c
                Error(_) -> "medium"
              }
              let risks = xstructor.extract_list(elements, "plan.risks.risk")
              let verifications =
                xstructor.extract_list(elements, "plan.verifications.verify")
              // Dependencies: extract from dep.N.@from / dep.N.@to attributes
              let dependencies = extract_dep_pairs(elements, 0, [])
              let forecaster_cfg = extract_forecaster_config(elements)
              types.PlannerFindings(
                plan_steps: steps,
                dependencies:,
                complexity:,
                risks:,
                verifications:,
                task_id: None,
                endeavour_id: None,
                forecaster_config: forecaster_cfg,
              )
            }
          }
      }
  }
}

fn empty_planner_findings() -> types.AgentFindings {
  types.PlannerFindings(
    plan_steps: [],
    dependencies: [],
    complexity: "",
    risks: [],
    verifications: [],
    task_id: None,
    endeavour_id: None,
    forecaster_config: None,
  )
}

/// Extract optional forecaster_config from planner XML output.
/// Looks for plan.forecaster_config.threshold and plan.forecaster_config.feature.N attributes.
fn extract_forecaster_config(
  elements: dict.Dict(String, String),
) -> option.Option(types.PlannerForecasterConfig) {
  let threshold = case dict.get(elements, "plan.forecaster_config.threshold") {
    Ok(t) ->
      case float.parse(t) {
        Ok(f) -> Some(f)
        Error(_) -> None
      }
    Error(_) -> None
  }
  let features = extract_forecaster_features(elements, 0, [])
  case threshold, features {
    None, [] -> None
    _, _ ->
      Some(types.PlannerForecasterConfig(
        threshold:,
        feature_overrides: features,
      ))
  }
}

fn extract_forecaster_features(
  elements: dict.Dict(String, String),
  idx: Int,
  acc: List(#(String, String)),
) -> List(#(String, String)) {
  let name_key =
    "plan.forecaster_config.feature." <> int.to_string(idx) <> ".@name"
  let imp_key =
    "plan.forecaster_config.feature." <> int.to_string(idx) <> ".@importance"
  case dict.get(elements, name_key), dict.get(elements, imp_key) {
    Ok(name), Ok(importance) ->
      extract_forecaster_features(
        elements,
        idx + 1,
        list.append(acc, [
          #(name, importance),
        ]),
      )
    _, _ -> acc
  }
}

/// Extract dependency pairs from XStructor elements.
/// Looks for plan.dependencies.dep.N.@from and plan.dependencies.dep.N.@to
fn extract_dep_pairs(
  elements: dict.Dict(String, String),
  idx: Int,
  acc: List(#(String, String)),
) -> List(#(String, String)) {
  let from_key = "plan.dependencies.dep." <> int.to_string(idx) <> ".@from"
  let to_key = "plan.dependencies.dep." <> int.to_string(idx) <> ".@to"
  case dict.get(elements, from_key), dict.get(elements, to_key) {
    Ok(from), Ok(to) ->
      extract_dep_pairs(elements, idx + 1, list.append(acc, [#(from, to)]))
    _, _ -> acc
  }
}

fn find_active(
  tasks: List(ActiveTask),
  task_id: String,
) -> option.Option(ActiveTask) {
  case list.find(tasks, fn(t) { t.task_id == task_id }) {
    Ok(t) -> Some(t)
    Error(_) -> None
  }
}

fn find_active_by_pid(
  tasks: List(ActiveTask),
  pid: Pid,
) -> option.Option(ActiveTask) {
  case list.find(tasks, fn(t) { t.pid == pid }) {
    Ok(t) -> Some(t)
    Error(_) -> None
  }
}

fn remove_active(tasks: List(ActiveTask), task_id: String) -> List(ActiveTask) {
  list.filter(tasks, fn(t) { t.task_id != task_id })
}

/// Build an AgentIdentity from a human_name, generating a fresh GUID.
pub fn make_identity(human_name: String) -> AgentIdentity {
  let guid = cycle_log.generate_uuid()
  let agent_id = make_agent_id(human_name, guid)
  AgentIdentity(human_name:, guid:, agent_id:)
}

/// Construct agent_id: normalised human_name + first 8 chars of GUID.
pub fn make_agent_id(human_name: String, guid: String) -> String {
  let normalised =
    human_name
    |> string.lowercase
    |> string.replace(" ", "-")
    |> strip_non_alnum_hyphens
  normalised <> "_" <> string.slice(guid, 0, 8)
}

fn strip_non_alnum_hyphens(s: String) -> String {
  string.to_graphemes(s)
  |> list.filter(fn(c) {
    case c {
      "-" -> True
      _ -> is_alnum(c)
    }
  })
  |> string.join("")
}

fn is_alnum(c: String) -> Bool {
  case c {
    "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f"
    | "g"
    | "h"
    | "i"
    | "j"
    | "k"
    | "l"
    | "m"
    | "n"
    | "o"
    | "p"
    | "q"
    | "r"
    | "s"
    | "t"
    | "u"
    | "v"
    | "w"
    | "x"
    | "y"
    | "z"
    | "0"
    | "1"
    | "2"
    | "3"
    | "4"
    | "5"
    | "6"
    | "7"
    | "8"
    | "9" -> True
    _ -> False
  }
}
