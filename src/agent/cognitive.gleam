import agent/registry.{type Registry}
import agent/types.{
  type AgentOutcome, type CognitiveMessage, type CognitiveReply,
  type CognitiveStatus, type Notification, type PendingTask, AgentComplete,
  AgentEvent, AgentFailure, AgentQuestionSource, AgentSuccess, AgentTask,
  AgentWaiting, Classifying, CognitiveQuestion, CognitiveReply, EvaluatingSafety,
  Idle, OwnToolWaiting, PendingAgent, PendingThink, QuestionForHuman,
  RestoreMessages, SafetyGateNotice, SaveResult, SaveWarning, SetModel,
  ThinkComplete, ThinkError, ThinkWorkerDown, Thinking, ToolCalling, UserAnswer,
  UserInput, WaitingForAgents, WaitingForUser,
}
import agent/worker
import context
import cycle_log
import dprime/gate
import dprime/meta
import dprime/types as dprime_types
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/provider.{type Provider}
import llm/request
import llm/response
import llm/tool
import llm/types as llm_types
import query_complexity
import storage
import tools/builtin

@external(erlang, "springdrift_ffi", "rescue")
fn rescue(body: fn() -> a) -> Result(a, String)

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

pub type CognitiveState {
  CognitiveState(
    self: Subject(CognitiveMessage),
    provider: Provider,
    model: String,
    system: String,
    max_tokens: Int,
    max_context_messages: Option(Int),
    tools: List(llm_types.Tool),
    messages: List(llm_types.Message),
    registry: Registry,
    pending: Dict(String, PendingTask),
    status: CognitiveStatus,
    cycle_id: Option(String),
    verbose: Bool,
    notify: Subject(Notification),
    task_model: String,
    reasoning_model: String,
    save_in_progress: Bool,
    save_pending: Option(List(llm_types.Message)),
    dprime_state: Option(dprime_types.DprimeState),
  )
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start the cognitive loop process. Returns a Subject for sending messages.
pub fn start(
  provider: Provider,
  system: String,
  max_tokens: Int,
  max_context_messages: Option(Int),
  agent_tools: List(llm_types.Tool),
  initial_messages: List(llm_types.Message),
  registry: Registry,
  verbose: Bool,
  notify: Subject(Notification),
  task_model: String,
  reasoning_model: String,
  dprime_state: Option(dprime_types.DprimeState),
) -> Subject(CognitiveMessage) {
  // The cognitive loop gets agent tools + request_human_input
  let tools = [builtin.human_input_tool(), ..agent_tools]
  let setup = process.new_subject()
  process.spawn_unlinked(fn() {
    let self = process.new_subject()
    let state =
      CognitiveState(
        self:,
        provider:,
        model: task_model,
        system:,
        max_tokens:,
        max_context_messages:,
        tools:,
        messages: initial_messages,
        registry:,
        pending: dict.new(),
        status: Idle,
        cycle_id: None,
        verbose:,
        notify:,
        task_model:,
        reasoning_model:,
        save_in_progress: False,
        save_pending: None,
        dprime_state:,
      )
    process.send(setup, self)
    cognitive_loop(state)
  })
  let assert Ok(subj) = process.receive(setup, 5000)
  subj
}

/// Build a Tool definition from an AgentSpec so the LLM can call agents.
pub fn agent_to_tool(spec: types.AgentSpec) -> llm_types.Tool {
  tool.new("agent_" <> spec.name)
  |> tool.with_description(spec.description)
  |> tool.add_string_param("instruction", "Task for the agent", True)
  |> tool.add_string_param("context", "Relevant context", False)
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Core loop
// ---------------------------------------------------------------------------

fn cognitive_loop(state: CognitiveState) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(state.self)
  let msg = process.selector_receive_forever(selector)
  let next = handle_message(state, msg)
  cognitive_loop(next)
}

fn handle_message(
  state: CognitiveState,
  msg: CognitiveMessage,
) -> CognitiveState {
  case msg {
    UserInput(text, reply_to) -> handle_user_input(state, text, reply_to)
    UserAnswer(answer) -> handle_user_answer(state, answer)
    ThinkComplete(task_id, resp) -> handle_think_complete(state, task_id, resp)
    ThinkError(task_id, error, retryable) ->
      handle_think_error(state, task_id, error, retryable)
    ThinkWorkerDown(task_id, reason) ->
      handle_think_down(state, task_id, reason)
    AgentComplete(outcome) -> handle_agent_complete(state, outcome)
    types.AgentQuestion(question, agent, reply_to) ->
      handle_agent_question(state, question, agent, reply_to)
    AgentEvent(event) -> handle_agent_event(state, event)
    SaveResult(error) -> handle_save_result(state, error)
    SetModel(model) -> CognitiveState(..state, model:)
    RestoreMessages(messages) -> {
      let new_state = CognitiveState(..state, messages:, cycle_id: None)
      request_save(new_state, messages)
    }
    types.ClassifyComplete(cycle_id, complexity, text, reply_to) ->
      handle_classify_complete(state, cycle_id, complexity, text, reply_to)
    types.SafetyGateComplete(task_id, result, resp, calls, reply_to) ->
      handle_safety_gate_complete(state, task_id, result, resp, calls, reply_to)
  }
}

// ---------------------------------------------------------------------------
// UserInput
// ---------------------------------------------------------------------------

fn handle_user_input(
  state: CognitiveState,
  text: String,
  reply_to: Subject(CognitiveReply),
) -> CognitiveState {
  // Guard: ignore input if not idle
  case state.status {
    Idle -> {
      let cycle_id = cycle_log.generate_uuid()
      cycle_log.log_human_input(cycle_id, state.cycle_id, text)

      // Spawn async classification worker — rescue catches panics
      let self = state.self
      let provider = state.provider
      let task_model = state.task_model
      process.spawn_unlinked(fn() {
        let complexity = case
          rescue(fn() { query_complexity.classify(text, provider, task_model) })
        {
          Ok(c) -> c
          Error(_) -> query_complexity.Simple
        }
        process.send(
          self,
          types.ClassifyComplete(cycle_id:, complexity:, text:, reply_to:),
        )
      })

      CognitiveState(..state, status: Classifying(cycle_id:))
    }
    _ -> state
  }
}

fn handle_classify_complete(
  state: CognitiveState,
  cycle_id: String,
  complexity: query_complexity.QueryComplexity,
  text: String,
  reply_to: Subject(CognitiveReply),
) -> CognitiveState {
  // Only handle if we're still classifying with the matching cycle_id
  case state.status {
    Classifying(current_cycle_id) if current_cycle_id == cycle_id -> {
      case complexity {
        query_complexity.Complex -> {
          cycle_log.log_classification(
            cycle_id,
            "complex",
            state.reasoning_model,
            False,
            None,
          )
          proceed_with_model(
            state,
            state.reasoning_model,
            text,
            cycle_id,
            reply_to,
          )
        }
        query_complexity.Simple -> {
          cycle_log.log_classification(
            cycle_id,
            "simple",
            state.task_model,
            False,
            None,
          )
          proceed_with_model(state, state.task_model, text, cycle_id, reply_to)
        }
      }
    }
    _ -> state
  }
}

/// Build a user message, spawn a think worker with the given model,
/// and transition to Thinking status.
fn proceed_with_model(
  state: CognitiveState,
  model: String,
  text: String,
  cycle_id: String,
  reply_to: Subject(CognitiveReply),
) -> CognitiveState {
  let msg =
    llm_types.Message(role: llm_types.User, content: [
      llm_types.TextContent(text:),
    ])
  let messages = list.append(state.messages, [msg])
  let task_id = cycle_id

  let req = build_request_with_model(state, model, messages)
  case state.verbose {
    True -> cycle_log.log_llm_request(cycle_id, req)
    False -> Nil
  }
  worker.spawn_think(task_id, req, state.provider, state.self)

  CognitiveState(
    ..state,
    model:,
    messages:,
    cycle_id: Some(cycle_id),
    status: Thinking(task_id:),
    pending: dict.insert(
      state.pending,
      task_id,
      PendingThink(task_id:, model:, fallback_from: None, reply_to:),
    ),
  )
}

// ---------------------------------------------------------------------------
// ThinkComplete — the main dispatch point
// ---------------------------------------------------------------------------

fn handle_think_complete(
  state: CognitiveState,
  task_id: String,
  resp: llm_types.LlmResponse,
) -> CognitiveState {
  case dict.get(state.pending, task_id) {
    Error(_) -> state
    Ok(PendingThink(model: req_model, fallback_from:, reply_to: rt, ..)) -> {
      let cycle_id = option.unwrap(state.cycle_id, task_id)
      cycle_log.log_llm_response(cycle_id, resp)
      case response.needs_tool_execution(resp) {
        False -> {
          // Final text response — prefix if this was a model fallback
          let text = response.text(resp)
          let #(reply_text, reply_model) = case fallback_from {
            Some(original) -> #(
              "["
                <> original
                <> " unavailable, used "
                <> req_model
                <> "] "
                <> text,
              req_model,
            )
            None -> #(text, req_model)
          }
          let assistant_msg =
            llm_types.Message(role: llm_types.Assistant, content: resp.content)
          let messages = list.append(state.messages, [assistant_msg])
          process.send(
            rt,
            CognitiveReply(
              response: reply_text,
              model: reply_model,
              usage: Some(resp.usage),
            ),
          )
          // Fire-and-forget save
          let new_state =
            CognitiveState(
              ..state,
              messages:,
              status: Idle,
              pending: dict.delete(state.pending, task_id),
            )
          request_save(new_state, messages)
        }
        True -> {
          let calls = response.tool_calls(resp)
          // D' gate intercept: if enabled, evaluate before dispatch
          case state.dprime_state {
            None -> dispatch_tool_calls(state, task_id, resp, calls, rt)
            Some(_dprime_st) ->
              spawn_safety_gate(state, task_id, resp, calls, rt)
          }
        }
      }
    }
    // dict.get only returns what's stored, but guard against non-PendingThink
    Ok(_) -> state
  }
}

fn dispatch_tool_calls(
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
    Error(_) -> dispatch_agent_calls(state, task_id, resp, calls, reply_to)
  }
}

fn handle_own_human_input(
  state: CognitiveState,
  task_id: String,
  resp: llm_types.LlmResponse,
  call: llm_types.ToolCall,
  reply_to: Subject(CognitiveReply),
) -> CognitiveState {
  let question = parse_human_input_question(call.input_json)

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

fn parse_human_input_question(input_json: String) -> String {
  let decoder = {
    use question <- decode.field("question", decode.string)
    decode.success(question)
  }
  case json.parse(input_json, decoder) {
    Ok(q) -> q
    Error(_) -> input_json
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
      let agent_name = string.drop_start(call.name, 6)
      case registry.get_task_subject(state.registry, agent_name) {
        None -> Error(Nil)
        Some(task_subject) -> {
          let agent_task_id = cycle_log.generate_uuid()
          let #(instruction, ctx) = parse_agent_params(call.input_json)
          process.send(
            task_subject,
            AgentTask(
              task_id: agent_task_id,
              tool_use_id: call.id,
              instruction:,
              context: ctx,
              parent_cycle_id: cycle_id,
              reply_to: state.self,
            ),
          )
          process.send(state.notify, ToolCalling(name: call.name))
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
      process.send(
        reply_to,
        CognitiveReply(
          response: "[Error: no matching agents available]",
          model: state.model,
          usage: Some(resp.usage),
        ),
      )
      CognitiveState(
        ..state,
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

      CognitiveState(
        ..state,
        messages:,
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

// ---------------------------------------------------------------------------
// ThinkError / ThinkWorkerDown
// ---------------------------------------------------------------------------

fn handle_think_error(
  state: CognitiveState,
  task_id: String,
  error: String,
  retryable: Bool,
) -> CognitiveState {
  let cycle_id = option.unwrap(state.cycle_id, task_id)
  cycle_log.log_llm_error(cycle_id, error)
  case dict.get(state.pending, task_id) {
    Error(_) -> state
    Ok(PendingThink(model: failed_model, reply_to: rt, ..)) -> {
      // If the error is retryable and we have a different model to try, fall back
      case retryable && failed_model != state.task_model {
        True -> {
          cycle_log.log_llm_error(
            cycle_id,
            "Falling back from " <> failed_model <> " to " <> state.task_model,
          )
          let new_task_id = cycle_log.generate_uuid()
          let req =
            build_request_with_model(state, state.task_model, state.messages)
          case state.verbose {
            True -> cycle_log.log_llm_request(cycle_id, req)
            False -> Nil
          }
          worker.spawn_think(new_task_id, req, state.provider, state.self)
          CognitiveState(
            ..state,
            status: Thinking(task_id: new_task_id),
            pending: dict.insert(
              dict.delete(state.pending, task_id),
              new_task_id,
              PendingThink(
                task_id: new_task_id,
                model: state.task_model,
                fallback_from: Some(failed_model),
                reply_to: rt,
              ),
            ),
          )
        }
        False -> {
          process.send(
            rt,
            CognitiveReply(
              response: "[Error: " <> error <> "]",
              model: state.model,
              usage: None,
            ),
          )
          CognitiveState(
            ..state,
            status: Idle,
            pending: dict.delete(state.pending, task_id),
          )
        }
      }
    }
    Ok(_) -> state
  }
}

fn handle_think_down(
  state: CognitiveState,
  task_id: String,
  reason: String,
) -> CognitiveState {
  // Only act if we still have this pending (may already be resolved)
  case dict.get(state.pending, task_id) {
    Error(_) -> state
    Ok(PendingThink(reply_to: rt, ..)) -> {
      process.send(
        rt,
        CognitiveReply(
          response: "[Error: think worker crashed: " <> reason <> "]",
          model: state.model,
          usage: None,
        ),
      )
      CognitiveState(
        ..state,
        status: Idle,
        pending: dict.delete(state.pending, task_id),
      )
    }
    Ok(_) -> state
  }
}

// ---------------------------------------------------------------------------
// AgentComplete
// ---------------------------------------------------------------------------

fn handle_agent_complete(
  state: CognitiveState,
  outcome: AgentOutcome,
) -> CognitiveState {
  let #(outcome_task_id, result_text) = case outcome {
    AgentSuccess(task_id, _agent, result) -> #(task_id, result)
    AgentFailure(task_id, _agent, error) -> #(
      task_id,
      "[Agent error: " <> error <> "]",
    )
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
          let new_task_id = cycle_log.generate_uuid()
          let cycle_id = option.unwrap(state.cycle_id, new_task_id)
          let req = build_request(state, messages)
          case state.verbose {
            True -> cycle_log.log_llm_request(cycle_id, req)
            False -> Nil
          }
          worker.spawn_think(new_task_id, req, state.provider, state.self)

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
              ),
            ),
          )
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// AgentQuestion — sub-agent needs human input
// ---------------------------------------------------------------------------

fn handle_agent_question(
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

// ---------------------------------------------------------------------------
// UserAnswer — user responded to a question
// ---------------------------------------------------------------------------

fn handle_user_answer(state: CognitiveState, answer: String) -> CognitiveState {
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
      let req = build_request(state, messages)
      case state.verbose {
        True -> cycle_log.log_llm_request(cycle_id, req)
        False -> Nil
      }
      worker.spawn_think(new_task_id, req, state.provider, state.self)

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
          ),
        ),
      )
    }
    _ -> state
  }
}

// ---------------------------------------------------------------------------
// AgentEvent — lifecycle notifications from supervisor
// ---------------------------------------------------------------------------

fn handle_agent_event(
  state: CognitiveState,
  event: types.AgentLifecycleEvent,
) -> CognitiveState {
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

// ---------------------------------------------------------------------------
// SaveResult + save queue
// ---------------------------------------------------------------------------

fn handle_save_result(
  state: CognitiveState,
  error: Option(String),
) -> CognitiveState {
  case error {
    Some(msg) -> process.send(state.notify, SaveWarning(message: msg))
    None -> Nil
  }
  case state.save_pending {
    Some(msgs) -> {
      let cleared =
        CognitiveState(..state, save_in_progress: False, save_pending: None)
      do_spawn_save(cleared, msgs)
      CognitiveState(..cleared, save_in_progress: True)
    }
    None -> CognitiveState(..state, save_in_progress: False)
  }
}

fn request_save(
  state: CognitiveState,
  messages: List(llm_types.Message),
) -> CognitiveState {
  case state.save_in_progress {
    True -> {
      // Queue for when current save completes
      CognitiveState(..state, save_pending: Some(messages))
    }
    False -> {
      do_spawn_save(state, messages)
      CognitiveState(..state, save_in_progress: True)
    }
  }
}

fn do_spawn_save(
  state: CognitiveState,
  messages: List(llm_types.Message),
) -> Nil {
  let self_subj = state.self
  process.spawn_unlinked(fn() {
    let result = storage.save(messages)
    process.send(
      self_subj,
      SaveResult(error: case result {
        Ok(_) -> None
        Error(msg) -> Some(msg)
      }),
    )
  })
  Nil
}

// ---------------------------------------------------------------------------
// Safety gate (D' evaluation)
// ---------------------------------------------------------------------------

fn spawn_safety_gate(
  state: CognitiveState,
  task_id: String,
  resp: llm_types.LlmResponse,
  calls: List(llm_types.ToolCall),
  reply_to: Subject(CognitiveReply),
) -> CognitiveState {
  let assert Some(dprime_st) = state.dprime_state
  let self = state.self
  let provider = state.provider
  let model = state.task_model

  // Extract instruction text from tool calls
  let instruction =
    list.map(calls, fn(c) { c.name <> ": " <> c.input_json })
    |> string.join("; ")

  // Build context from recent messages
  let ctx =
    list.filter_map(state.messages, fn(m) {
      case m.content {
        [llm_types.TextContent(text:), ..] -> Ok(text)
        _ -> Error(Nil)
      }
    })
    |> list.take(3)
    |> string.join("\n")

  process.spawn_unlinked(fn() {
    let result = gate.evaluate(instruction, ctx, dprime_st, provider, model)
    process.send(
      self,
      types.SafetyGateComplete(
        task_id:,
        result:,
        response: resp,
        calls:,
        reply_to:,
      ),
    )
  })

  CognitiveState(
    ..state,
    status: EvaluatingSafety(task_id:, response: resp, calls:, reply_to:),
  )
}

fn handle_safety_gate_complete(
  state: CognitiveState,
  task_id: String,
  result: dprime_types.GateResult,
  resp: llm_types.LlmResponse,
  calls: List(llm_types.ToolCall),
  reply_to: Subject(CognitiveReply),
) -> CognitiveState {
  let cycle_id = option.unwrap(state.cycle_id, task_id)

  // Log the D' evaluation
  cycle_log.log_dprime_evaluation(cycle_id, result)

  // Send notification
  let decision_str = case result.decision {
    dprime_types.Accept -> "ACCEPT"
    dprime_types.Modify -> "MODIFY"
    dprime_types.Reject -> "REJECT"
  }
  process.send(
    state.notify,
    SafetyGateNotice(
      decision: decision_str,
      score: result.dprime_score,
      explanation: result.explanation,
    ),
  )

  // Update D' state history
  let new_dprime_state = case state.dprime_state {
    None -> None
    Some(ds) -> {
      let updated = meta.record(ds, cycle_id, result, "")
      let final_state = case meta.should_tighten(updated) {
        True -> meta.tighten_thresholds(updated)
        False -> updated
      }
      Some(final_state)
    }
  }
  let state = CognitiveState(..state, dprime_state: new_dprime_state)

  case result.decision {
    dprime_types.Accept -> {
      // Proceed normally
      dispatch_tool_calls(state, task_id, resp, calls, reply_to)
    }

    dprime_types.Modify -> {
      // Append modification instruction and continue thinking
      let assistant_msg =
        llm_types.Message(role: llm_types.Assistant, content: resp.content)
      let modify_msg =
        llm_types.Message(role: llm_types.User, content: [
          llm_types.TextContent(
            text: "[Safety system: D' evaluation flagged potential concerns (score: "
            <> float.to_string(result.dprime_score)
            <> "). "
            <> result.explanation
            <> ". Please reconsider your approach and proceed with additional caution.]",
          ),
        ])
      let messages = list.append(state.messages, [assistant_msg, modify_msg])

      let new_task_id = cycle_log.generate_uuid()
      let req = build_request(state, messages)
      case state.verbose {
        True -> cycle_log.log_llm_request(cycle_id, req)
        False -> Nil
      }
      worker.spawn_think(new_task_id, req, state.provider, state.self)

      CognitiveState(
        ..state,
        messages:,
        status: Thinking(task_id: new_task_id),
        pending: dict.insert(
          dict.delete(state.pending, task_id),
          new_task_id,
          PendingThink(
            task_id: new_task_id,
            model: state.model,
            fallback_from: None,
            reply_to:,
          ),
        ),
      )
    }

    dprime_types.Reject -> {
      // Generate error tool results for all calls and continue
      let assistant_msg =
        llm_types.Message(role: llm_types.Assistant, content: resp.content)
      let error_blocks =
        list.map(calls, fn(call) {
          llm_types.ToolResultContent(
            tool_use_id: call.id,
            content: "[Safety system rejected: "
              <> result.explanation
              <> " (D' score: "
              <> float.to_string(result.dprime_score)
              <> ")]",
            is_error: True,
          )
        })
      let user_msg =
        llm_types.Message(role: llm_types.User, content: error_blocks)
      let messages = list.append(state.messages, [assistant_msg, user_msg])

      let new_task_id = cycle_log.generate_uuid()
      let req = build_request(state, messages)
      case state.verbose {
        True -> cycle_log.log_llm_request(cycle_id, req)
        False -> Nil
      }
      worker.spawn_think(new_task_id, req, state.provider, state.self)

      CognitiveState(
        ..state,
        messages:,
        status: Thinking(task_id: new_task_id),
        pending: dict.insert(
          dict.delete(state.pending, task_id),
          new_task_id,
          PendingThink(
            task_id: new_task_id,
            model: state.model,
            fallback_from: None,
            reply_to:,
          ),
        ),
      )
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn build_request(
  state: CognitiveState,
  messages: List(llm_types.Message),
) -> llm_types.LlmRequest {
  build_request_with_model(state, state.model, messages)
}

fn build_request_with_model(
  state: CognitiveState,
  model: String,
  messages: List(llm_types.Message),
) -> llm_types.LlmRequest {
  let trimmed = case state.max_context_messages {
    None -> messages
    Some(max) -> context.trim(messages, max)
  }
  let base =
    request.new(model, state.max_tokens)
    |> request.with_system(state.system)
    |> request.with_messages(trimmed)
  case state.tools {
    [] -> base
    tools -> request.with_tools(base, tools)
  }
}

fn parse_agent_params(input_json: String) -> #(String, String) {
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
