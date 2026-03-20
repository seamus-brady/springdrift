import agent/cognitive/llm as cognitive_llm
import agent/cognitive_state.{type CognitiveState, CognitiveState}
import agent/framework
import agent/registry
import agent/types.{
  type AgentOutcome, type CognitiveReply, AgentFailure, AgentQuestionSource,
  AgentSuccess, AgentTask, AgentWaiting, CognitiveQuestion, CognitiveReply, Idle,
  OwnToolWaiting, PendingAgent, PendingThink, QuestionForHuman, Thinking,
  ToolCalling, WaitingForAgents, WaitingForUser,
}
import agent/worker
import cycle_log
import dag/types as dag_types
import dprime/gate
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import llm/response
import llm/types as llm_types
import narrative/curator
import narrative/librarian
import narrative/log as narrative_log
import paths
import planner/log as planner_log
import planner/types as planner_types
import slog
import tools/memory
import tools/planner as planner_tools

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

/// Extract node_type from the PendingThink for a task_id, defaulting to CognitiveCycle.
fn pending_node_type(
  state: CognitiveState,
  task_id: String,
) -> dag_types.CycleNodeType {
  case dict.get(state.pending, task_id) {
    Ok(PendingThink(node_type:, ..)) -> node_type
    _ -> dag_types.CognitiveCycle
  }
}

pub fn dispatch_tool_calls(
  state: CognitiveState,
  task_id: String,
  resp: llm_types.LlmResponse,
  calls: List(llm_types.ToolCall),
  reply_to: Subject(CognitiveReply),
) -> CognitiveState {
  // Check for request_human_input first
  case list.find(calls, fn(c) { c.name == "request_human_input" }) {
    Ok(hi_call) ->
      handle_own_human_input(state, task_id, resp, hi_call, reply_to)
    Error(_) -> {
      // Check for memory and planner tools — execute synchronously, then re-think
      let #(memory_calls, after_memory) =
        list.partition(calls, fn(c) { memory.is_memory_tool(c.name) })
      let #(planner_calls, remaining_calls) =
        list.partition(after_memory, fn(c) {
          planner_tools.is_planner_tool(c.name)
        })
      let sync_calls = list.append(memory_calls, planner_calls)
      case sync_calls {
        [] ->
          dispatch_agent_calls(state, task_id, resp, remaining_calls, reply_to)
        _ ->
          handle_memory_tools(
            state,
            task_id,
            resp,
            sync_calls,
            remaining_calls,
            reply_to,
          )
      }
    }
  }
}

fn handle_own_human_input(
  state: CognitiveState,
  task_id: String,
  resp: llm_types.LlmResponse,
  call: llm_types.ToolCall,
  reply_to: Subject(CognitiveReply),
) -> CognitiveState {
  let question = framework.parse_human_input_question(call.input_json)

  // Send decoupled notification
  process.send(
    state.notify,
    QuestionForHuman(question:, source: CognitiveQuestion),
  )

  // Add assistant message with tool use content to history
  let assistant_msg =
    llm_types.Message(role: llm_types.Assistant, content: resp.content)
  let messages = list.append(state.messages, [assistant_msg])

  // Stash context so we can resume after the human answers
  let ctx = OwnToolWaiting(tool_use_id: call.id, reply_to:)

  CognitiveState(
    ..state,
    messages:,
    status: WaitingForUser(question:, context: ctx),
    pending: dict.delete(state.pending, task_id),
  )
}

fn handle_memory_tools(
  state: CognitiveState,
  task_id: String,
  resp: llm_types.LlmResponse,
  memory_calls: List(llm_types.ToolCall),
  remaining_calls: List(llm_types.ToolCall),
  reply_to: Subject(CognitiveReply),
) -> CognitiveState {
  let cycle_id = option.unwrap(state.cycle_id, task_id)
  // Execute memory tools synchronously, logging each call/result
  let memory_results =
    list.map(memory_calls, fn(call) {
      // Log tool call to cycle log
      cycle_log.log_tool_call(cycle_id, call, state.redact_secrets)
      let facts_ctx = case state.cycle_id {
        Some(cid) ->
          Some(memory.FactsContext(
            facts_dir: paths.facts_dir(),
            cycle_id: cid,
            agent_id: "cognitive",
          ))
        None -> None
      }
      let agent_entries =
        list.map(registry.list_agents(state.registry), fn(e) {
          let status_str = case e.status {
            registry.Running -> "Running"
            registry.Restarting -> "Restarting"
            registry.Stopped -> "Stopped"
          }
          memory.AgentStatusEntry(name: e.name, status: status_str)
        })
      // Compute thread health stats for introspect
      let thread_index = case state.memory.librarian {
        Some(l) -> librarian.load_thread_index(l)
        None -> narrative_log.load_thread_index(state.memory.narrative_dir)
      }
      let thread_total = list.length(thread_index.threads)
      let thread_single_cycle =
        list.count(thread_index.threads, fn(ts) { ts.cycle_count <= 1 })
      let thread_uuid_named =
        list.count(thread_index.threads, fn(ts) {
          string.starts_with(ts.thread_name, "Thread ")
        })
      let introspect_ctx =
        Some(memory.IntrospectContext(
          agent_uuid: state.identity.agent_uuid,
          session_since: state.identity.session_since,
          active_profile: state.identity.active_profile,
          agents: agent_entries,
          dprime_enabled: option.is_some(state.dprime_state),
          dprime_modify_threshold: case state.dprime_state {
            Some(ds) -> ds.current_modify_threshold
            None -> 0.0
          },
          dprime_reject_threshold: case state.dprime_state {
            Some(ds) -> ds.current_reject_threshold
            None -> 0.0
          },
          current_cycle_id: state.cycle_id,
          thread_total:,
          thread_single_cycle:,
          thread_uuid_named:,
          thread_multi_cycle: thread_total - thread_single_cycle,
        ))
      let result = case planner_tools.is_planner_tool(call.name) {
        True ->
          case state.memory.librarian {
            Some(lib) -> planner_tools.execute(call, state.planner_dir, lib)
            None ->
              llm_types.ToolFailure(
                tool_use_id: call.id,
                error: "Planner tools unavailable (no librarian)",
              )
          }
        False ->
          memory.execute_with_how_to(
            call,
            state.memory.narrative_dir,
            state.memory.librarian,
            facts_ctx,
            introspect_ctx,
            state.config.memory_limits,
            state.config.how_to_content,
          )
      }
      // Log tool result to cycle log
      cycle_log.log_tool_result(cycle_id, result, state.redact_secrets)
      case result {
        llm_types.ToolSuccess(tool_use_id: id, content: c) ->
          llm_types.ToolResultContent(
            tool_use_id: id,
            content: c,
            is_error: False,
          )
        llm_types.ToolFailure(tool_use_id: id, error: e) ->
          llm_types.ToolResultContent(
            tool_use_id: id,
            content: e,
            is_error: True,
          )
      }
    })

  // Accumulate ToolSummaries for DAG telemetry
  let new_summaries =
    list.map(memory_calls, fn(call) {
      let success =
        list.any(memory_results, fn(r) {
          case r {
            llm_types.ToolResultContent(tool_use_id: tuid, is_error: err, ..) ->
              tuid == call.id && !err
            _ -> False
          }
        })
      dag_types.ToolSummary(name: call.name, success:, error: None)
    })
  let state =
    CognitiveState(
      ..state,
      cycle_tool_calls: list.append(state.cycle_tool_calls, new_summaries),
    )

  // If there are also agent calls, dispatch those with memory results as initial_results
  case remaining_calls {
    [] -> {
      // Only memory calls — add results to messages and re-think
      let assistant_msg =
        llm_types.Message(role: llm_types.Assistant, content: resp.content)
      let user_msg =
        llm_types.Message(role: llm_types.User, content: memory_results)
      let messages = list.append(state.messages, [assistant_msg, user_msg])

      let new_task_id = cycle_log.generate_uuid()
      let cycle_id = option.unwrap(state.cycle_id, new_task_id)
      let new_state =
        CognitiveState(
          ..state,
          messages:,
          pending: dict.delete(state.pending, task_id),
        )
      let req = cognitive_llm.build_request(new_state, messages)
      case state.verbose {
        True -> cycle_log.log_llm_request(cycle_id, req)
        False -> Nil
      }
      worker.spawn_think(
        new_task_id,
        req,
        state.provider,
        state.self,
        state.config.retry_config,
      )

      CognitiveState(
        ..new_state,
        status: Thinking(task_id: new_task_id),
        pending: dict.insert(
          dict.delete(state.pending, task_id),
          new_task_id,
          PendingThink(
            task_id: new_task_id,
            model: state.model,
            fallback_from: None,
            reply_to:,
            output_gate_count: 0,
            empty_retried: False,
            node_type: pending_node_type(state, task_id),
          ),
        ),
      )
    }
    agent_remaining -> {
      // Mix: execute memory tools, pass results as initial, dispatch agents
      let #(agent_calls, non_agent_calls) =
        list.partition(agent_remaining, fn(c) {
          string.starts_with(c.name, "agent_")
        })
      let error_blocks =
        list.map(non_agent_calls, fn(call) {
          llm_types.ToolResultContent(
            tool_use_id: call.id,
            content: "Unknown tool",
            is_error: True,
          )
        })
      let initial = list.append(memory_results, error_blocks)
      case agent_calls {
        [] -> {
          // No agent calls either — just memory + unknown tools, re-think
          let assistant_msg =
            llm_types.Message(role: llm_types.Assistant, content: resp.content)
          let user_msg =
            llm_types.Message(role: llm_types.User, content: initial)
          let messages = list.append(state.messages, [assistant_msg, user_msg])
          let new_task_id = cycle_log.generate_uuid()
          let cycle_id = option.unwrap(state.cycle_id, new_task_id)
          let new_state =
            CognitiveState(
              ..state,
              messages:,
              pending: dict.delete(state.pending, task_id),
            )
          let req = cognitive_llm.build_request(new_state, messages)
          case state.verbose {
            True -> cycle_log.log_llm_request(cycle_id, req)
            False -> Nil
          }
          worker.spawn_think(
            new_task_id,
            req,
            state.provider,
            state.self,
            state.config.retry_config,
          )
          CognitiveState(
            ..new_state,
            status: Thinking(task_id: new_task_id),
            pending: dict.insert(
              dict.delete(state.pending, task_id),
              new_task_id,
              PendingThink(
                task_id: new_task_id,
                model: state.model,
                fallback_from: None,
                reply_to:,
                output_gate_count: 0,
                empty_retried: False,
                node_type: pending_node_type(state, task_id),
              ),
            ),
          )
        }
        _ ->
          do_dispatch_agents(
            state,
            task_id,
            resp,
            agent_calls,
            initial,
            reply_to,
          )
      }
    }
  }
}

fn dispatch_agent_calls(
  state: CognitiveState,
  task_id: String,
  resp: llm_types.LlmResponse,
  calls: List(llm_types.ToolCall),
  reply_to: Subject(CognitiveReply),
) -> CognitiveState {
  // Separate agent calls from non-agent calls
  let #(agent_calls, other_calls) =
    list.partition(calls, fn(call) { string.starts_with(call.name, "agent_") })

  case agent_calls, other_calls {
    // Only agent calls
    agent_calls, [] -> {
      do_dispatch_agents(state, task_id, resp, agent_calls, [], reply_to)
    }

    // No agent calls — unknown tools, send error
    [], _other -> {
      let text = response.text(resp)
      let reply_text = case text {
        "" -> "No agent tools matched."
        t -> t
      }
      // Add assistant message to history so it isn't silently lost
      let assistant_msg =
        llm_types.Message(role: llm_types.Assistant, content: resp.content)
      let messages = list.append(state.messages, [assistant_msg])
      process.send(
        reply_to,
        CognitiveReply(
          response: reply_text,
          model: state.model,
          usage: Some(resp.usage),
        ),
      )
      CognitiveState(
        ..state,
        messages:,
        status: Idle,
        pending: dict.delete(state.pending, task_id),
      )
    }

    // Mix of agent and non-agent — error blocks for non-agent, dispatch agents
    agent_calls, non_agent_calls -> {
      let error_blocks =
        list.map(non_agent_calls, fn(call) {
          llm_types.ToolResultContent(
            tool_use_id: call.id,
            content: "Unknown tool",
            is_error: True,
          )
        })
      do_dispatch_agents(
        state,
        task_id,
        resp,
        agent_calls,
        error_blocks,
        reply_to,
      )
    }
  }
}

fn do_dispatch_agents(
  state: CognitiveState,
  task_id: String,
  resp: llm_types.LlmResponse,
  agent_calls: List(llm_types.ToolCall),
  initial_results: List(llm_types.ContentBlock),
  reply_to: Subject(CognitiveReply),
) -> CognitiveState {
  let cycle_id = option.unwrap(state.cycle_id, task_id)
  let new_pending_agents =
    list.filter_map(agent_calls, fn(call) {
      let agent_prefix_len = string.length("agent_")
      let agent_name = string.drop_start(call.name, agent_prefix_len)
      case registry.get_task_subject(state.registry, agent_name) {
        None -> Error(Nil)
        Some(task_subject) -> {
          let agent_task_id = cycle_log.generate_uuid()
          let #(instruction, ctx) = parse_agent_params(call.input_json)
          let base_task =
            AgentTask(
              task_id: agent_task_id,
              tool_use_id: call.id,
              instruction:,
              context: ctx,
              parent_cycle_id: cycle_id,
              reply_to: state.self,
            )
          // Enrich task with prior agent results via Curator
          let enriched_task = case state.memory.curator {
            Some(cur) -> curator.inject_context(cur, base_task)
            None -> base_task
          }
          process.send(task_subject, enriched_task)
          process.send(state.notify, ToolCalling(name: call.name))
          // Index agent cycle as NodePending in DAG
          case state.memory.librarian {
            Some(lib) ->
              process.send(
                lib,
                librarian.IndexNode(node: dag_types.CycleNode(
                  cycle_id: agent_task_id,
                  parent_id: Some(cycle_id),
                  node_type: dag_types.AgentCycle,
                  timestamp: get_datetime(),
                  outcome: dag_types.NodePending,
                  model: "",
                  complexity: "agent",
                  tool_calls: [],
                  dprime_gates: [],
                  tokens_in: 0,
                  tokens_out: 0,
                  duration_ms: 0,
                  agent_output: None,
                )),
              )
            None -> Nil
          }
          Ok(PendingAgent(
            task_id: agent_task_id,
            tool_use_id: call.id,
            agent: agent_name,
            reply_to:,
          ))
        }
      }
    })

  // Guard: if no agents were dispatched, reply with error and return to Idle
  case new_pending_agents {
    [] -> {
      let error_text = "[Error: no matching agents available]"
      process.send(
        reply_to,
        CognitiveReply(
          response: error_text,
          model: state.model,
          usage: Some(resp.usage),
        ),
      )
      // Add single assistant message with the original response content + error
      // so message history stays well-formed (alternating user/assistant).
      let assistant_msg =
        llm_types.Message(
          role: llm_types.Assistant,
          content: list.append(resp.content, [
            llm_types.TextContent(text: error_text),
          ]),
        )
      let messages = list.append(state.messages, [assistant_msg])
      CognitiveState(
        ..state,
        messages:,
        status: Idle,
        pending: dict.delete(state.pending, task_id),
      )
    }
    _ -> {
      let pending_ids =
        list.map(new_pending_agents, fn(p) {
          case p {
            PendingAgent(task_id: tid, ..) -> tid
            _ -> ""
          }
        })

      // Add assistant message with tool use content
      let assistant_msg =
        llm_types.Message(role: llm_types.Assistant, content: resp.content)
      let messages = list.append(state.messages, [assistant_msg])

      // Insert new pending agents into the dict
      let new_pending =
        list.fold(
          new_pending_agents,
          dict.delete(state.pending, task_id),
          fn(d, p) {
            case p {
              PendingAgent(task_id: tid, ..) -> dict.insert(d, tid, p)
              _ -> d
            }
          },
        )

      // Log agent dispatch calls and accumulate ToolSummaries
      let agent_summaries =
        list.map(agent_calls, fn(call) {
          cycle_log.log_tool_call(cycle_id, call, state.redact_secrets)
          dag_types.ToolSummary(name: call.name, success: True, error: None)
        })

      CognitiveState(
        ..state,
        messages:,
        cycle_tool_calls: list.append(state.cycle_tool_calls, agent_summaries),
        status: WaitingForAgents(
          pending_ids:,
          accumulated_results: initial_results,
          reply_to:,
        ),
        pending: new_pending,
      )
    }
  }
}

pub fn handle_agent_complete(
  state: CognitiveState,
  outcome: AgentOutcome,
) -> CognitiveState {
  let #(outcome_task_id, result_text) = case outcome {
    AgentSuccess(task_id, agent:, result:, tool_errors:, ..) -> {
      // If the agent "succeeded" but had tool failures, prefix them so the
      // orchestrating LLM knows the result may be unreliable.
      let prefixed = case tool_errors {
        [] -> result
        errors -> {
          let error_lines = string.join(errors, "\n  ")
          "[WARNING: agent "
          <> agent
          <> " had tool failures during execution:\n  "
          <> error_lines
          <> "\nThe following result may be unreliable.]\n\n"
          <> result
        }
      }
      #(task_id, prefixed)
    }
    AgentFailure(task_id, error:, ..) -> #(
      task_id,
      "[Agent error: " <> error <> "]",
    )
  }

  // Accumulate completion record for the Archivist
  let completion = case outcome {
    AgentSuccess(
      agent_id:,
      agent_human_name:,
      agent_cycle_id:,
      result:,
      instruction:,
      tools_used:,
      tool_call_details:,
      input_tokens:,
      output_tokens:,
      duration_ms:,
      ..,
    ) ->
      types.AgentCompletionRecord(
        agent_id:,
        agent_human_name:,
        agent_cycle_id:,
        instruction:,
        result: Ok(result),
        tools_used:,
        tool_call_details:,
        input_tokens:,
        output_tokens:,
        duration_ms:,
      )
    AgentFailure(
      agent_id:,
      agent_human_name:,
      agent_cycle_id:,
      error:,
      instruction:,
      tools_used:,
      tool_call_details:,
      input_tokens:,
      output_tokens:,
      duration_ms:,
      ..,
    ) ->
      types.AgentCompletionRecord(
        agent_id:,
        agent_human_name:,
        agent_cycle_id:,
        instruction:,
        result: Error(error),
        tools_used:,
        tool_call_details:,
        input_tokens:,
        output_tokens:,
        duration_ms:,
      )
  }
  let state =
    CognitiveState(..state, agent_completions: [
      completion,
      ..state.agent_completions
    ])

  // Push agent health to Curator when tools failed (degraded status)
  case outcome {
    AgentSuccess(agent:, tool_errors: [first_err, ..], ..) ->
      case state.memory.curator {
        Some(cur) ->
          curator.update_agent_health(cur, agent <> " degraded: " <> first_err)
        None -> Nil
      }
    AgentFailure(agent:, error:, ..) ->
      case state.memory.curator {
        Some(cur) ->
          curator.update_agent_health(cur, agent <> " failed: " <> error)
        None -> Nil
      }
    _ -> Nil
  }

  // Write back to Curator scratchpad for inter-agent context
  case state.memory.curator {
    Some(cur) -> {
      let cycle_id = option.unwrap(state.cycle_id, outcome_task_id)
      let findings = case outcome {
        AgentSuccess(structured_result: option.Some(sr), ..) -> sr.findings
        _ -> types.GenericFindings(notes: completion.tools_used)
      }
      let agent_result =
        types.AgentResult(
          final_text: case completion.result {
            Ok(text) -> text
            Error(err) -> "[error] " <> err
          },
          agent_id: completion.agent_id,
          cycle_id:,
          findings:,
        )
      curator.write_back_result(cur, cycle_id, agent_result)
    }
    None -> Nil
  }

  // Update DAG node with agent outcome
  case state.memory.librarian {
    Some(lib) -> {
      let node_outcome = case outcome {
        AgentSuccess(..) -> dag_types.NodeSuccess
        AgentFailure(error:, ..) -> dag_types.NodeFailure(reason: error)
      }
      let tool_summaries =
        list.map(completion.tools_used, fn(name) {
          dag_types.ToolSummary(name:, success: True, error: None)
        })
      process.send(
        lib,
        librarian.UpdateNode(node: dag_types.CycleNode(
          cycle_id: outcome_task_id,
          parent_id: state.cycle_id,
          node_type: dag_types.AgentCycle,
          timestamp: get_datetime(),
          outcome: node_outcome,
          model: "",
          complexity: "",
          tool_calls: tool_summaries,
          dprime_gates: [],
          tokens_in: completion.input_tokens,
          tokens_out: completion.output_tokens,
          duration_ms: completion.duration_ms,
          agent_output: Some(findings_to_dag_output(outcome, completion)),
        )),
      )
    }
    None -> Nil
  }

  // --- Planner output hook: auto-create task from planner findings ---
  let state = case outcome {
    AgentSuccess(agent: "planner", structured_result: Some(sr), ..) ->
      handle_planner_output(state, sr.findings, outcome_task_id)
    _ -> state
  }

  case dict.get(state.pending, outcome_task_id) {
    Error(_) -> state
    Ok(pending_agent) -> {
      let actual_tool_use_id = case pending_agent {
        PendingAgent(tool_use_id: tuid, ..) -> tuid
        _ -> ""
      }

      // Build tool result content block
      let is_error = case outcome {
        AgentFailure(..) -> True
        AgentSuccess(..) -> False
      }
      let tool_result_block =
        llm_types.ToolResultContent(
          tool_use_id: actual_tool_use_id,
          content: result_text,
          is_error:,
        )

      let remaining = dict.delete(state.pending, outcome_task_id)

      // Check if all agents are done
      let still_waiting =
        dict.fold(remaining, False, fn(acc, _key, p) {
          acc
          || case p {
            PendingAgent(..) -> True
            _ -> False
          }
        })

      case still_waiting {
        True -> {
          // More agents pending — accumulate result in WaitingForAgents status
          case state.status {
            WaitingForAgents(pending_ids:, accumulated_results:, reply_to:) -> {
              CognitiveState(
                ..state,
                status: WaitingForAgents(
                  pending_ids:,
                  accumulated_results: list.append(accumulated_results, [
                    tool_result_block,
                  ]),
                  reply_to:,
                ),
                pending: remaining,
              )
            }
            _ -> CognitiveState(..state, pending: remaining)
          }
        }
        False -> {
          // All agents done — get reply_to and accumulated results from status
          let #(all_results, reply_to) = case state.status {
            WaitingForAgents(accumulated_results:, reply_to:, ..) -> #(
              list.append(accumulated_results, [tool_result_block]),
              reply_to,
            )
            _ -> {
              // Fallback — shouldn't happen, but extract reply_to from pending
              let rt = case pending_agent {
                PendingAgent(reply_to: r, ..) -> r
                PendingThink(reply_to: r, ..) -> r
              }
              #([tool_result_block], rt)
            }
          }

          // Build ONE user message with ALL accumulated results
          let user_msg =
            llm_types.Message(role: llm_types.User, content: all_results)
          let messages = list.append(state.messages, [user_msg])

          // Spawn post-execution D' re-check if enabled
          let result_text =
            list.filter_map(all_results, fn(block) {
              case block {
                llm_types.ToolResultContent(content: c, ..) -> Ok(c)
                _ -> Error(Nil)
              }
            })
            |> string.join("\n")
          let new_state_with_messages =
            CognitiveState(..state, messages:, pending: remaining)
          case state.dprime_state {
            Some(dprime_st) -> {
              let cycle_id = option.unwrap(state.cycle_id, "post-exec")
              let self = state.self
              let provider = state.provider
              let scorer_model = state.task_model
              let verbose = state.verbose
              let redact_secrets = state.redact_secrets
              // Get the pre-execution D' score from the most recent history
              let pre_score = case dprime_st.history {
                [latest, ..] -> latest.score
                [] -> 0.0
              }
              process.spawn_unlinked(fn() {
                let post_result =
                  gate.post_execution_evaluate(
                    result_text,
                    "",
                    dprime_st,
                    provider,
                    scorer_model,
                    cycle_id,
                    verbose,
                    redact_secrets,
                  )
                process.send(
                  self,
                  types.PostExecutionGateComplete(
                    cycle_id:,
                    result: post_result,
                    pre_score:,
                    reply_to:,
                  ),
                )
              })
              Nil
            }
            None -> Nil
          }

          let new_task_id = cycle_log.generate_uuid()
          let cycle_id = option.unwrap(state.cycle_id, new_task_id)
          let req =
            cognitive_llm.build_request(new_state_with_messages, messages)
          case state.verbose {
            True -> cycle_log.log_llm_request(cycle_id, req)
            False -> Nil
          }
          worker.spawn_think(
            new_task_id,
            req,
            state.provider,
            state.self,
            state.config.retry_config,
          )

          CognitiveState(
            ..state,
            messages:,
            status: Thinking(task_id: new_task_id),
            pending: dict.insert(
              remaining,
              new_task_id,
              PendingThink(
                task_id: new_task_id,
                model: state.model,
                fallback_from: None,
                reply_to:,
                output_gate_count: 0,
                empty_retried: False,
                node_type: state.cycle_node_type,
              ),
            ),
          )
        }
      }
    }
  }
}

pub fn handle_agent_question(
  state: CognitiveState,
  question: String,
  agent: String,
  reply_to: Subject(String),
) -> CognitiveState {
  process.send(
    state.notify,
    QuestionForHuman(question:, source: AgentQuestionSource(agent:)),
  )
  CognitiveState(
    ..state,
    status: WaitingForUser(question:, context: AgentWaiting(reply_to:)),
  )
}

pub fn handle_user_answer(
  state: CognitiveState,
  answer: String,
) -> CognitiveState {
  case state.status {
    WaitingForUser(context: AgentWaiting(reply_to:), ..) -> {
      // Sub-agent question — forward answer
      process.send(reply_to, answer)
      CognitiveState(..state, status: Idle)
    }
    WaitingForUser(context: OwnToolWaiting(tool_use_id:, reply_to:), ..) -> {
      // Cognitive loop's own request_human_input — build tool result and continue
      let tool_result_block =
        llm_types.ToolResultContent(
          tool_use_id:,
          content: answer,
          is_error: False,
        )
      let user_msg =
        llm_types.Message(role: llm_types.User, content: [tool_result_block])
      let messages = list.append(state.messages, [user_msg])

      // Spawn a continuation think worker
      let new_task_id = cycle_log.generate_uuid()
      let cycle_id = option.unwrap(state.cycle_id, new_task_id)
      let req = cognitive_llm.build_request(state, messages)
      case state.verbose {
        True -> cycle_log.log_llm_request(cycle_id, req)
        False -> Nil
      }
      worker.spawn_think(
        new_task_id,
        req,
        state.provider,
        state.self,
        state.config.retry_config,
      )

      CognitiveState(
        ..state,
        messages:,
        status: Thinking(task_id: new_task_id),
        pending: dict.insert(
          state.pending,
          new_task_id,
          PendingThink(
            task_id: new_task_id,
            model: state.model,
            fallback_from: None,
            reply_to:,
            output_gate_count: 0,
            empty_retried: False,
            node_type: state.cycle_node_type,
          ),
        ),
      )
    }
    _ -> state
  }
}

pub fn handle_agent_event(
  state: CognitiveState,
  event: types.AgentLifecycleEvent,
) -> CognitiveState {
  slog.debug(
    "cognitive",
    "handle_agent_event",
    case event {
      types.AgentStarted(name:, ..) -> "AgentStarted: " <> name
      types.AgentCrashed(name:, ..) -> "AgentCrashed: " <> name
      types.AgentRestarted(name:, ..) -> "AgentRestarted: " <> name
      types.AgentRestartFailed(name:, ..) -> "AgentRestartFailed: " <> name
      types.AgentStopped(name:) -> "AgentStopped: " <> name
    },
    state.cycle_id,
  )
  // Forward lifecycle event to notification channel
  let #(event_type, event_name) = case event {
    types.AgentStarted(name:, ..) -> #("started", name)
    types.AgentCrashed(name:, ..) -> #("crashed", name)
    types.AgentRestarted(name:, ..) -> #("restarted", name)
    types.AgentRestartFailed(name:, ..) -> #("restart_failed", name)
    types.AgentStopped(name:) -> #("stopped", name)
  }
  process.send(
    state.notify,
    types.AgentLifecycleNotice(event_type:, agent_name: event_name),
  )
  // Push agent health to Curator on crash/restart/stop events
  case event {
    types.AgentCrashed(name:, ..)
    | types.AgentRestartFailed(name:, ..)
    | types.AgentStopped(name:) -> {
      case state.memory.curator {
        Some(cur) -> curator.update_agent_health(cur, name <> " " <> event_type)
        None -> Nil
      }
    }
    _ -> Nil
  }

  case event {
    types.AgentStarted(name:, task_subject:) ->
      CognitiveState(
        ..state,
        registry: registry.register(state.registry, name, task_subject),
      )
    types.AgentCrashed(name:, ..) ->
      CognitiveState(
        ..state,
        registry: registry.mark_restarting(state.registry, name),
      )
    types.AgentRestarted(name:, task_subject:, ..) ->
      CognitiveState(
        ..state,
        registry: registry.update_task_subject(
          state.registry,
          name,
          task_subject,
        ),
      )
    types.AgentRestartFailed(name:, ..) ->
      CognitiveState(
        ..state,
        registry: registry.mark_stopped(state.registry, name),
      )
    types.AgentStopped(name:) ->
      CognitiveState(
        ..state,
        registry: registry.mark_stopped(state.registry, name),
      )
  }
}

pub fn parse_agent_params(input_json: String) -> #(String, String) {
  let decoder = {
    use instruction <- decode.field("instruction", decode.string)
    use ctx <- decode.optional_field("context", "", decode.string)
    decode.success(#(instruction, ctx))
  }
  case json.parse(input_json, decoder) {
    Ok(#(instruction, ctx)) -> #(instruction, ctx)
    Error(_) -> #(input_json, "")
  }
}

// ---------------------------------------------------------------------------
// Structured output → DAG AgentOutput conversion
// ---------------------------------------------------------------------------

fn findings_to_dag_output(
  outcome: types.AgentOutcome,
  completion: types.AgentCompletionRecord,
) -> dag_types.AgentOutput {
  case outcome {
    types.AgentSuccess(structured_result: option.Some(sr), ..) ->
      case sr.findings {
        types.ResearcherFindings(sources:, dead_ends:, ..) ->
          dag_types.ResearchOutput(
            facts: list.map(sources, fn(s) {
              dag_types.FoundFact(
                label: s.title,
                value: s.url,
                confidence: s.relevance,
              )
            }),
            sources: list.length(sources),
            dead_ends:,
            confidence: case sources != [] {
              True -> 1.0
              False -> 0.0
            },
          )
        types.PlannerFindings(
          plan_steps:,
          dependencies:,
          complexity:,
          risks:,
          ..,
        ) ->
          dag_types.PlanOutput(
            steps: plan_steps,
            dependencies:,
            complexity:,
            risks:,
          )
        types.CoderFindings(files_touched:, patterns_used:, ..) ->
          dag_types.CoderOutput(files_touched:, patterns: patterns_used)
        types.WriterFindings(word_count:, format:, sections:) ->
          dag_types.WriterOutput(word_count:, format:, sections:)
        types.GenericFindings(notes:) -> dag_types.GenericOutput(notes:)
      }
    _ ->
      dag_types.GenericOutput(notes: [
        "agent=" <> completion.agent_id,
        "instruction=" <> completion.instruction,
      ])
  }
}

// ---------------------------------------------------------------------------
// Planner output hook — auto-create/update tasks from planner findings
// ---------------------------------------------------------------------------

fn handle_planner_output(
  state: CognitiveState,
  findings: types.AgentFindings,
  cycle_id: String,
) -> CognitiveState {
  case findings {
    types.PlannerFindings(
      plan_steps:,
      dependencies:,
      complexity:,
      risks:,
      task_id: existing_task_id,
      endeavour_id:,
    ) -> {
      case state.memory.librarian {
        Some(lib) -> {
          let actual_cycle_id = option.unwrap(state.cycle_id, cycle_id)
          case existing_task_id {
            // Update existing task — add cycle_id
            Some(tid) -> {
              let op =
                planner_types.AddCycleId(
                  task_id: tid,
                  cycle_id: actual_cycle_id,
                )
              planner_log.append_task_op(state.planner_dir, op)
              librarian.notify_task_op(lib, op)
              CognitiveState(..state, active_task_id: Some(tid))
            }
            // Create new task
            None -> {
              let new_task_id =
                planner_tools.create_task(
                  state.planner_dir,
                  lib,
                  // Use first step as title fallback if no other info
                  case plan_steps {
                    [first, ..] -> first
                    [] -> "Planned task"
                  },
                  string.join(plan_steps, "; "),
                  plan_steps,
                  dependencies,
                  complexity,
                  risks,
                  planner_types.SystemTask,
                  endeavour_id,
                  actual_cycle_id,
                )
              CognitiveState(..state, active_task_id: Some(new_task_id))
            }
          }
        }
        None -> state
      }
    }
    _ -> state
  }
}
