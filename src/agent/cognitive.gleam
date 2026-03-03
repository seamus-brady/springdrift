import agent/registry.{type Registry}
import agent/types.{
  type AgentOutcome, type CognitiveMessage, type CognitiveReply,
  type CognitiveStatus, type Notification, type PendingTask, AgentComplete,
  AgentEvent, AgentFailure, AgentQuestionSource, AgentSuccess, AgentTask,
  AgentWaiting, CognitiveQuestion, CognitiveReply, Idle, OwnToolWaiting,
  PendingAgent, PendingThink, QuestionForHuman, RestoreMessages, SaveResult,
  SaveWarning, SetModel, ThinkComplete, ThinkError, ThinkWorkerDown, Thinking,
  ToolCalling, UserAnswer, UserInput, WaitingForAgents, WaitingForUser,
}
import agent/worker
import context
import cycle_log
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
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
    pending: List(PendingTask),
    status: CognitiveStatus,
    cycle_id: Option(String),
    verbose: Bool,
    notify: Subject(Notification),
    task_model: String,
    reasoning_model: String,
  )
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start the cognitive loop process. Returns a Subject for sending messages.
pub fn start(
  provider: Provider,
  model: String,
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
        model:,
        system:,
        max_tokens:,
        max_context_messages:,
        tools:,
        messages: initial_messages,
        registry:,
        pending: [],
        status: Idle,
        cycle_id: None,
        verbose:,
        notify:,
        task_model:,
        reasoning_model:,
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
      spawn_save(messages, state.self)
      CognitiveState(..state, messages:, cycle_id: None)
    }
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

      // Classify query complexity
      let complexity =
        query_complexity.classify(text, state.provider, state.task_model)

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
          proceed_with_input(state, text, cycle_id, reply_to)
        }
      }
    }
    _ -> state
  }
}

fn proceed_with_input(
  state: CognitiveState,
  text: String,
  cycle_id: String,
  reply_to: Subject(CognitiveReply),
) -> CognitiveState {
  proceed_with_model(state, state.model, text, cycle_id, reply_to)
}

/// Like proceed_with_input but uses a specific model for this request
/// without permanently changing state.model.
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
    messages:,
    cycle_id: Some(cycle_id),
    status: Thinking(task_id:),
    pending: [
      PendingThink(task_id:, model:, fallback_from: None, reply_to:),
      ..state.pending
    ],
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
  case find_pending_think(state.pending, task_id) {
    None -> state
    Some(PendingThink(model: req_model, fallback_from:, reply_to: rt, ..)) -> {
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
          spawn_save(messages, state.self)
          CognitiveState(
            ..state,
            messages:,
            status: Idle,
            pending: remove_pending(state.pending, task_id),
          )
        }
        True -> {
          let calls = response.tool_calls(resp)
          dispatch_tool_calls(state, task_id, resp, calls, rt)
        }
      }
    }
    // find_pending_think only returns PendingThink, but exhaustive matching
    Some(_) -> state
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
  let ctx =
    OwnToolWaiting(
      tool_use_id: call.id,
      assistant_content: resp.content,
      reply_to:,
    )

  CognitiveState(
    ..state,
    messages:,
    status: WaitingForUser(question:, context: ctx),
    pending: remove_pending(state.pending, task_id),
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

      CognitiveState(
        ..state,
        messages:,
        status: WaitingForAgents(pending_ids:),
        pending: list.append(
          remove_pending(state.pending, task_id),
          new_pending_agents,
        ),
      )
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
        pending: remove_pending(state.pending, task_id),
      )
    }

    // Mix of agent and non-agent — dispatch agents, ignore others
    agent_calls, _other ->
      dispatch_agent_calls(state, task_id, resp, agent_calls, reply_to)
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
  case find_pending_think(state.pending, task_id) {
    None -> state
    Some(PendingThink(model: failed_model, reply_to: rt, ..)) -> {
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
            pending: [
              PendingThink(
                task_id: new_task_id,
                model: state.task_model,
                fallback_from: Some(failed_model),
                reply_to: rt,
              ),
              ..remove_pending(state.pending, task_id)
            ],
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
            pending: remove_pending(state.pending, task_id),
          )
        }
      }
    }
    Some(_) -> state
  }
}

fn handle_think_down(
  state: CognitiveState,
  task_id: String,
  reason: String,
) -> CognitiveState {
  // Only act if we still have this pending (may already be resolved)
  case find_pending_think(state.pending, task_id) {
    None -> state
    Some(PendingThink(reply_to: rt, ..)) -> {
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
        pending: remove_pending(state.pending, task_id),
      )
    }
    Some(_) -> state
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

  case find_pending_agent(state.pending, outcome_task_id) {
    None -> state
    Some(pending_agent) -> {
      let actual_tool_use_id = case pending_agent {
        PendingAgent(tool_use_id: tuid, ..) -> tuid
        _ -> ""
      }
      let reply_to = case pending_agent {
        PendingAgent(reply_to: rt, ..) -> rt
        PendingThink(reply_to: rt, ..) -> rt
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

      let remaining = remove_pending(state.pending, outcome_task_id)

      // Check if all agents are done
      let still_waiting =
        list.any(remaining, fn(p) {
          case p {
            PendingAgent(..) -> True
            _ -> False
          }
        })

      case still_waiting {
        True -> {
          // More agents pending — accumulate result, stay in WaitingForAgents
          let user_msg =
            llm_types.Message(role: llm_types.User, content: [tool_result_block])
          let messages = list.append(state.messages, [user_msg])
          CognitiveState(..state, messages:, pending: remaining)
        }
        False -> {
          // All agents done — feed results back, spawn think worker
          let user_msg =
            llm_types.Message(role: llm_types.User, content: [tool_result_block])
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
            pending: [
              PendingThink(
                task_id: new_task_id,
                model: state.model,
                fallback_from: None,
                reply_to:,
              ),
              ..remaining
            ],
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
    WaitingForUser(context: OwnToolWaiting(tool_use_id:, reply_to:, ..), ..) -> {
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
        pending: [
          PendingThink(
            task_id: new_task_id,
            model: state.model,
            fallback_from: None,
            reply_to:,
          ),
          ..state.pending
        ],
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
    types.AgentStarted(name:) ->
      CognitiveState(
        ..state,
        registry: registry.mark_running(state.registry, name),
      )
    types.AgentCrashed(name:, ..) ->
      CognitiveState(
        ..state,
        registry: registry.mark_restarting(state.registry, name),
      )
    types.AgentRestarted(name:, ..) ->
      CognitiveState(
        ..state,
        registry: registry.mark_running(state.registry, name),
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
// SaveResult
// ---------------------------------------------------------------------------

fn handle_save_result(
  state: CognitiveState,
  error: Option(String),
) -> CognitiveState {
  case error {
    None -> state
    Some(msg) -> {
      process.send(state.notify, SaveWarning(message: msg))
      state
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

fn spawn_save(
  messages: List(llm_types.Message),
  self: Subject(CognitiveMessage),
) -> Nil {
  process.spawn_unlinked(fn() {
    let result = storage.save(messages)
    process.send(
      self,
      SaveResult(error: case result {
        Ok(_) -> None
        Error(msg) -> Some(msg)
      }),
    )
  })
  Nil
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

fn find_pending_think(
  pending: List(PendingTask),
  task_id: String,
) -> Option(PendingTask) {
  case
    list.find(pending, fn(p) {
      case p {
        PendingThink(task_id: tid, ..) -> tid == task_id
        _ -> False
      }
    })
  {
    Ok(p) -> Some(p)
    Error(_) -> None
  }
}

fn find_pending_agent(
  pending: List(PendingTask),
  task_id: String,
) -> Option(PendingTask) {
  case
    list.find(pending, fn(p) {
      case p {
        PendingAgent(task_id: tid, ..) -> tid == task_id
        _ -> False
      }
    })
  {
    Ok(p) -> Some(p)
    Error(_) -> None
  }
}

fn remove_pending(
  pending: List(PendingTask),
  task_id: String,
) -> List(PendingTask) {
  list.filter(pending, fn(p) {
    case p {
      PendingThink(task_id: tid, ..) -> tid != task_id
      PendingAgent(task_id: tid, ..) -> tid != task_id
    }
  })
}
