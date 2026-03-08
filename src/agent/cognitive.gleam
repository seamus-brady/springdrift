import agent/framework
import agent/registry.{type Registry}
import agent/types.{
  type AgentOutcome, type CognitiveMessage, type CognitiveReply,
  type CognitiveStatus, type Notification, type PendingTask, AgentComplete,
  AgentEvent, AgentFailure, AgentQuestionSource, AgentSuccess, AgentTask,
  AgentWaiting, Classifying, CognitiveQuestion, CognitiveReply,
  EvaluatingInputSafety, EvaluatingSafety, Idle, OwnToolWaiting, PendingAgent,
  PendingThink, QuestionForHuman, RestoreMessages, SafetyGateNotice, SaveResult,
  SaveWarning, SetModel, ThinkComplete, ThinkError, ThinkWorkerDown, Thinking,
  ToolCalling, UserAnswer, UserInput, WaitingForAgents, WaitingForUser,
}
import agent/worker
import context
import cycle_log
import dprime/audit as dprime_audit
import dprime/config as dprime_config_mod
import dprime/gate
import dprime/meta
import dprime/output_gate
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
import narrative/archivist
import narrative/librarian.{type LibrarianMessage}
import paths
import profile
import profile/types as profile_types
import query_complexity
import skills
import slog
import storage
import tools/builtin
import tools/memory
import tools/web as tools_web

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
    // Narrative (always enabled)
    narrative_dir: String,
    cbr_dir: String,
    archivist_model: String,
    librarian: Option(Subject(LibrarianMessage)),
    agent_completions: List(types.AgentCompletionRecord),
    last_user_input: String,
    // Profile
    active_profile: Option(String),
    supervisor: Option(Subject(types.SupervisorMessage)),
    profile_dirs: List(String),
    write_anywhere: Bool,
    output_dprime_state: Option(dprime_types.DprimeState),
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
  narrative_dir: String,
  cbr_dir: String,
  archivist_model: String,
  librarian: Option(Subject(LibrarianMessage)),
  profile_dirs: List(String),
  write_anywhere: Bool,
) -> Subject(CognitiveMessage) {
  // The cognitive loop gets agent tools + request_human_input + memory tools
  let tools =
    list.flatten([
      [builtin.human_input_tool()],
      memory.all(),
      agent_tools,
    ])
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
        narrative_dir:,
        cbr_dir:,
        archivist_model:,
        librarian:,
        agent_completions: [],
        last_user_input: "",
        active_profile: None,
        supervisor: None,
        profile_dirs:,
        write_anywhere:,
        output_dprime_state: None,
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
  slog.debug(
    "cognitive",
    "handle_message",
    case msg {
      UserInput(..) -> "UserInput"
      UserAnswer(..) -> "UserAnswer"
      ThinkComplete(..) -> "ThinkComplete"
      ThinkError(..) -> "ThinkError"
      ThinkWorkerDown(..) -> "ThinkWorkerDown"
      AgentComplete(..) -> "AgentComplete"
      types.AgentQuestion(..) -> "AgentQuestion"
      AgentEvent(..) -> "AgentEvent"
      SaveResult(..) -> "SaveResult"
      SetModel(..) -> "SetModel"
      RestoreMessages(..) -> "RestoreMessages"
      types.ClassifyComplete(..) -> "ClassifyComplete"
      types.SafetyGateComplete(..) -> "SafetyGateComplete"
      types.InputSafetyGateComplete(..) -> "InputSafetyGateComplete"
      types.PostExecutionGateComplete(..) -> "PostExecutionGateComplete"
      types.LoadProfile(..) -> "LoadProfile"
      types.SetSupervisor(..) -> "SetSupervisor"
      types.OutputGateComplete(..) -> "OutputGateComplete"
    },
    state.cycle_id,
  )
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
    types.InputSafetyGateComplete(cycle_id, result, model, text, reply_to) ->
      handle_input_safety_gate_complete(
        state,
        cycle_id,
        result,
        model,
        text,
        reply_to,
      )
    types.PostExecutionGateComplete(cycle_id, result, pre_score, reply_to) ->
      handle_post_execution_gate_complete(
        state,
        cycle_id,
        result,
        pre_score,
        reply_to,
      )
    types.LoadProfile(name, reply_to) ->
      handle_load_profile(state, name, reply_to)
    types.SetSupervisor(supervisor:) ->
      CognitiveState(..state, supervisor: Some(supervisor))
    types.OutputGateComplete(
      cycle_id,
      result,
      report_text,
      modification_count,
      reply_to,
    ) ->
      handle_output_gate_complete(
        state,
        cycle_id,
        result,
        report_text,
        modification_count,
        reply_to,
      )
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
  slog.debug(
    "cognitive",
    "handle_user_input",
    "Input: " <> string.slice(text, 0, 80),
    state.cycle_id,
  )
  // Guard: ignore input if not idle
  case state.status {
    Idle -> {
      let cycle_id = cycle_log.generate_uuid()
      cycle_log.log_human_input(cycle_id, state.cycle_id, text)
      let state =
        CognitiveState(..state, last_user_input: text, agent_completions: [])

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
  slog.info(
    "cognitive",
    "handle_classify_complete",
    "Complexity: "
      <> case complexity {
      query_complexity.Simple -> "simple"
      query_complexity.Complex -> "complex"
    },
    Some(cycle_id),
  )
  // Only handle if we're still classifying with the matching cycle_id
  case state.status {
    Classifying(current_cycle_id) if current_cycle_id == cycle_id -> {
      let model = case complexity {
        query_complexity.Complex -> {
          cycle_log.log_classification(
            cycle_id,
            "complex",
            state.reasoning_model,
            False,
            None,
          )
          state.reasoning_model
        }
        query_complexity.Simple -> {
          cycle_log.log_classification(
            cycle_id,
            "simple",
            state.task_model,
            False,
            None,
          )
          state.task_model
        }
      }
      case state.dprime_state {
        None -> proceed_with_model(state, model, text, cycle_id, reply_to)
        Some(_) ->
          spawn_input_safety_gate(state, cycle_id, model, text, reply_to)
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
  slog.info(
    "cognitive",
    "proceed_with_model",
    "Using model: " <> model,
    Some(cycle_id),
  )
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
      PendingThink(
        task_id:,
        model:,
        fallback_from: None,
        reply_to:,
        output_gate_count: 0,
        empty_retried: False,
      ),
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
    Ok(PendingThink(
      model: req_model,
      fallback_from:,
      reply_to: rt,
      output_gate_count: ogc,
      empty_retried:,
      ..,
    )) -> {
      let cycle_id = option.unwrap(state.cycle_id, task_id)
      cycle_log.log_llm_response(cycle_id, resp)
      case response.needs_tool_execution(resp) {
        False -> {
          // Final text response
          let raw_text = response.text(resp)
          // Auto-retry once on empty response before surfacing error
          case raw_text == "" && !empty_retried {
            True -> {
              slog.warn(
                "cognitive",
                "handle_think_complete",
                "Empty response, auto-retrying once",
                state.cycle_id,
              )
              let new_task_id = cycle_log.generate_uuid()
              let req =
                build_request_with_model(state, req_model, state.messages)
              worker.spawn_think(new_task_id, req, state.provider, state.self)
              CognitiveState(
                ..state,
                status: Thinking(task_id: new_task_id),
                pending: dict.insert(
                  dict.delete(state.pending, task_id),
                  new_task_id,
                  PendingThink(
                    task_id: new_task_id,
                    model: req_model,
                    fallback_from:,
                    reply_to: rt,
                    output_gate_count: ogc,
                    empty_retried: True,
                  ),
                ),
              )
            }
            False -> {
              // Prefix if this was a model fallback
              let text = case raw_text {
                "" -> {
                  slog.warn(
                    "cognitive",
                    "handle_think_complete",
                    "LLM returned empty response (no text, no tool calls)",
                    state.cycle_id,
                  )
                  "[Empty response from model — please try again]"
                }
                _ -> raw_text
              }
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
                llm_types.Message(
                  role: llm_types.Assistant,
                  content: resp.content,
                )
              let messages = list.append(state.messages, [assistant_msg])
              // Check for output gate
              case state.output_dprime_state {
                Some(output_state) -> {
                  // Spawn output gate evaluation instead of replying immediately
                  spawn_output_gate(
                    state,
                    output_state,
                    reply_text,
                    rt,
                    messages,
                    task_id,
                    ogc,
                  )
                }
                None -> {
                  process.send(
                    rt,
                    CognitiveReply(
                      response: reply_text,
                      model: reply_model,
                      usage: Some(resp.usage),
                    ),
                  )
                  // Spawn Archivist (fire-and-forget)
                  maybe_spawn_archivist(
                    state,
                    reply_text,
                    reply_model,
                    Some(resp.usage),
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
              }
            }
          }
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
    Error(_) -> {
      // Check for memory tools — execute synchronously, then re-think
      let #(memory_calls, remaining_calls) =
        list.partition(calls, fn(c) { memory.is_memory_tool(c.name) })
      case memory_calls {
        [] ->
          dispatch_agent_calls(state, task_id, resp, remaining_calls, reply_to)
        _ ->
          handle_memory_tools(
            state,
            task_id,
            resp,
            memory_calls,
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
  // Execute memory tools synchronously
  let memory_results =
    list.map(memory_calls, fn(call) {
      let facts_ctx = case state.cycle_id {
        Some(cid) ->
          Some(memory.FactsContext(
            facts_dir: paths.facts_dir(),
            cycle_id: cid,
            agent_id: "cognitive",
          ))
        None -> None
      }
      let result =
        memory.execute(call, state.narrative_dir, state.librarian, facts_ctx)
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
      let req = build_request(new_state, messages)
      case state.verbose {
        True -> cycle_log.log_llm_request(cycle_id, req)
        False -> Nil
      }
      worker.spawn_think(new_task_id, req, state.provider, state.self)

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
          let req = build_request(new_state, messages)
          case state.verbose {
            True -> cycle_log.log_llm_request(cycle_id, req)
            False -> Nil
          }
          worker.spawn_think(new_task_id, req, state.provider, state.self)
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
  slog.log_error(
    "cognitive",
    "handle_think_error",
    "Error: "
      <> error
      <> " retryable="
      <> case retryable {
      True -> "true"
      False -> "false"
    },
    state.cycle_id,
  )
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
                output_gate_count: 0,
                empty_retried: False,
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
    AgentSuccess(task_id, result:, ..) -> #(task_id, result)
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
          let req = build_request(new_state_with_messages, messages)
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
                output_gate_count: 0,
                empty_retried: False,
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
            output_gate_count: 0,
            empty_retried: False,
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
  slog.debug(
    "cognitive",
    "handle_save_result",
    case error {
      Some(msg) -> "Save error: " <> msg
      None -> "Save ok"
    },
    state.cycle_id,
  )
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
  slog.info(
    "cognitive",
    "spawn_safety_gate",
    "Spawning D' safety evaluation",
    state.cycle_id,
  )
  let assert Some(dprime_st) = state.dprime_state
  let self = state.self
  let provider = state.provider
  let model = state.task_model
  let cycle_id = option.unwrap(state.cycle_id, task_id)
  let verbose = state.verbose

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
    let result =
      gate.evaluate(
        instruction,
        ctx,
        dprime_st,
        provider,
        model,
        cycle_id,
        verbose,
      )
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
  let decision_str = case result.decision {
    dprime_types.Accept -> "ACCEPT"
    dprime_types.Modify -> "MODIFY"
    dprime_types.Reject -> "REJECT"
  }
  slog.info(
    "cognitive",
    "handle_safety_gate_complete",
    "D' result: "
      <> decision_str
      <> " (score: "
      <> float.to_string(result.dprime_score)
      <> ")",
    Some(cycle_id),
  )

  // Log the D' evaluation
  cycle_log.log_dprime_evaluation(cycle_id, result)

  // Emit audit record
  let instruction =
    list.map(calls, fn(c) { c.name <> ": " <> c.input_json })
    |> string.join("; ")
  let audit_record =
    dprime_audit.build_record(
      cycle_id,
      instruction,
      result,
      case state.dprime_state {
        Some(ds) -> ds.config.features
        None -> []
      },
      None,
      None,
    )
  dprime_audit.log_record(audit_record, cycle_id)

  // Send notification
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
            output_gate_count: 0,
            empty_retried: False,
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
            output_gate_count: 0,
            empty_retried: False,
          ),
        ),
      )
    }
  }
}

// ---------------------------------------------------------------------------
// Input-level safety gate (D' evaluation on user input)
// ---------------------------------------------------------------------------

fn spawn_input_safety_gate(
  state: CognitiveState,
  cycle_id: String,
  model: String,
  text: String,
  reply_to: Subject(CognitiveReply),
) -> CognitiveState {
  slog.info(
    "cognitive",
    "spawn_input_safety_gate",
    "Spawning D' input safety evaluation",
    Some(cycle_id),
  )
  let assert Some(dprime_st) = state.dprime_state
  let self = state.self
  let provider = state.provider
  let scorer_model = state.task_model
  let verbose = state.verbose

  // Instruction is the user's raw input
  let instruction = text

  // Build context from recent text messages
  let ctx =
    list.filter_map(state.messages, fn(m) {
      case m.content {
        [llm_types.TextContent(text: t), ..] -> Ok(t)
        _ -> Error(Nil)
      }
    })
    |> list.take(3)
    |> string.join("\n")

  process.spawn_unlinked(fn() {
    let result =
      gate.evaluate(
        instruction,
        ctx,
        dprime_st,
        provider,
        scorer_model,
        cycle_id,
        verbose,
      )
    process.send(
      self,
      types.InputSafetyGateComplete(
        cycle_id:,
        result:,
        model:,
        text:,
        reply_to:,
      ),
    )
  })

  CognitiveState(
    ..state,
    cycle_id: Some(cycle_id),
    status: EvaluatingInputSafety(cycle_id:, model:, text:, reply_to:),
  )
}

fn handle_input_safety_gate_complete(
  state: CognitiveState,
  cycle_id: String,
  result: dprime_types.GateResult,
  model: String,
  text: String,
  reply_to: Subject(CognitiveReply),
) -> CognitiveState {
  let decision_str = case result.decision {
    dprime_types.Accept -> "ACCEPT"
    dprime_types.Modify -> "MODIFY"
    dprime_types.Reject -> "REJECT"
  }
  slog.info(
    "cognitive",
    "handle_input_safety_gate_complete",
    "D' input result: "
      <> decision_str
      <> " (score: "
      <> float.to_string(result.dprime_score)
      <> ")",
    Some(cycle_id),
  )

  // Log the input-level D' evaluation
  cycle_log.log_dprime_input_evaluation(cycle_id, result)

  // Send notification
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
      // Proceed normally with the LLM call
      proceed_with_model(state, model, text, cycle_id, reply_to)
    }

    dprime_types.Modify -> {
      // Inject a caution message into history, then proceed
      let caution_msg =
        llm_types.Message(role: llm_types.User, content: [
          llm_types.TextContent(
            text: "[Safety system: D' input evaluation flagged potential concerns (score: "
            <> float.to_string(result.dprime_score)
            <> "). "
            <> result.explanation
            <> ". Please proceed with additional caution.]",
          ),
        ])
      let messages = list.append(state.messages, [caution_msg])
      proceed_with_model(
        CognitiveState(..state, messages:),
        model,
        text,
        cycle_id,
        reply_to,
      )
    }

    dprime_types.Reject -> {
      // Reply directly with refusal — no LLM call
      process.send(
        reply_to,
        CognitiveReply(
          response: "[Safety system: query rejected (D' score: "
            <> float.to_string(result.dprime_score)
            <> "). "
            <> result.explanation
            <> "]",
          model:,
          usage: None,
        ),
      )
      CognitiveState(..state, status: Idle)
    }
  }
}

// ---------------------------------------------------------------------------
// Post-execution D' re-check
// ---------------------------------------------------------------------------

fn handle_post_execution_gate_complete(
  state: CognitiveState,
  cycle_id: String,
  result: dprime_types.GateResult,
  pre_score: Float,
  _reply_to: Subject(CognitiveReply),
) -> CognitiveState {
  let decision_str = case result.decision {
    dprime_types.Accept -> "ACCEPT"
    dprime_types.Modify -> "MODIFY"
    dprime_types.Reject -> "REJECT"
  }
  slog.info(
    "cognitive",
    "handle_post_execution_gate_complete",
    "Post-execution D' result: "
      <> decision_str
      <> " (score: "
      <> float.to_string(result.dprime_score)
      <> ", pre: "
      <> float.to_string(pre_score)
      <> ")",
    Some(cycle_id),
  )

  // Log the post-execution evaluation
  cycle_log.log_dprime_evaluation(cycle_id, result)

  // Update D' state history
  let new_dprime_state = case state.dprime_state {
    None -> None
    Some(ds) -> {
      let updated = meta.record(ds, cycle_id, result, "")
      Some(updated)
    }
  }
  let state = CognitiveState(..state, dprime_state: new_dprime_state)

  // Check if D' improved (decreased) or worsened
  case result.dprime_score <=. pre_score {
    True -> {
      // D' decreased or held — action was effective, continue normally
      slog.debug(
        "cognitive",
        "handle_post_execution_gate_complete",
        "D' improved, continuing normally",
        Some(cycle_id),
      )
      state
    }
    False -> {
      // D' increased — action was counterproductive
      // Check meta-management intervention
      let intervention = case state.dprime_state {
        Some(ds) -> meta.should_intervene(ds)
        None -> dprime_types.NoIntervention
      }
      case intervention {
        dprime_types.AbortMaxIterations -> {
          slog.warn(
            "cognitive",
            "handle_post_execution_gate_complete",
            "Max iterations reached, aborting",
            Some(cycle_id),
          )
          process.send(
            state.notify,
            SafetyGateNotice(
              decision: "ABORT",
              score: result.dprime_score,
              explanation: "Post-execution check: max iterations reached",
            ),
          )
          state
        }
        dprime_types.Stalled -> {
          slog.warn(
            "cognitive",
            "handle_post_execution_gate_complete",
            "D' stalled after execution, tightening thresholds",
            Some(cycle_id),
          )
          let new_ds = case state.dprime_state {
            Some(ds) -> Some(meta.tighten_thresholds(ds))
            None -> None
          }
          process.send(
            state.notify,
            SafetyGateNotice(
              decision: "STALLED",
              score: result.dprime_score,
              explanation: "Post-execution check: D' worsened, thresholds tightened",
            ),
          )
          CognitiveState(..state, dprime_state: new_ds)
        }
        dprime_types.NoIntervention -> {
          slog.info(
            "cognitive",
            "handle_post_execution_gate_complete",
            "D' increased but no intervention needed",
            Some(cycle_id),
          )
          state
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// LoadProfile
// ---------------------------------------------------------------------------

fn handle_load_profile(
  state: CognitiveState,
  name: String,
  reply_to: Subject(types.CognitiveReply),
) -> CognitiveState {
  case state.status {
    Idle -> do_load_profile(state, name, reply_to)
    _ -> {
      // Not idle — reject
      process.send(
        reply_to,
        CognitiveReply(
          response: "[Cannot switch profiles while busy. Try again when idle.]",
          model: state.model,
          usage: None,
        ),
      )
      state
    }
  }
}

fn do_load_profile(
  state: CognitiveState,
  name: String,
  reply_to: Subject(types.CognitiveReply),
) -> CognitiveState {
  case profile.load(name, state.profile_dirs) {
    Error(msg) -> {
      slog.warn("cognitive", "do_load_profile", msg, state.cycle_id)
      process.send(
        reply_to,
        CognitiveReply(
          response: "[Profile error: " <> msg <> "]",
          model: state.model,
          usage: None,
        ),
      )
      state
    }
    Ok(loaded_profile) -> {
      slog.info(
        "cognitive",
        "do_load_profile",
        "Loading profile: " <> name,
        state.cycle_id,
      )

      // Shutdown existing agents if we have a supervisor reference
      case state.supervisor {
        Some(sup) -> process.send(sup, types.ShutdownAll)
        None -> Nil
      }

      // Build new agent specs from profile
      let task_model = case loaded_profile.models.task_model {
        Some(m) -> m
        None -> state.task_model
      }
      let reasoning_model = case loaded_profile.models.reasoning_model {
        Some(m) -> m
        None -> state.reasoning_model
      }

      let agent_specs =
        profile_agent_specs(
          loaded_profile,
          state.provider,
          task_model,
          state.write_anywhere,
        )
      let agent_tools = list.map(agent_specs, agent_to_tool)
      let tools = [builtin.human_input_tool(), ..agent_tools]

      // Load profile-specific D' config (dual-gate: tool_gate + output_gate)
      let #(dprime_state, output_dprime_state) = case
        loaded_profile.dprime_path
      {
        Some(path) -> {
          let #(tool_cfg, output_cfg) = dprime_config_mod.load_dual(path)
          let tool_state = Some(dprime_config_mod.initial_state(tool_cfg))
          let output_state = case output_cfg {
            Some(cfg) -> Some(dprime_config_mod.initial_state(cfg))
            None -> None
          }
          #(tool_state, output_state)
        }
        None -> #(state.dprime_state, state.output_dprime_state)
      }

      // Load profile-specific skills
      let skill_dirs = case loaded_profile.skills_dir {
        Some(sd) -> [sd]
        None -> []
      }
      let discovered = skills.discover(skill_dirs)
      let base_system =
        "You are a cognitive orchestrator. You manage specialist agents and talk to the human. Use agent tools to delegate work and request_human_input to ask questions."
      let system = case discovered {
        [] -> base_system
        _ -> base_system <> "\n\n" <> skills.to_system_prompt_xml(discovered)
      }

      // Start new agents via supervisor
      case state.supervisor {
        Some(sup) ->
          list.each(agent_specs, fn(spec) {
            let rs = process.new_subject()
            process.send(sup, types.StartChild(spec:, reply_to: rs))
            case process.receive(rs, 5000) {
              Ok(Ok(_)) ->
                slog.info(
                  "cognitive",
                  "do_load_profile",
                  "Started agent: " <> spec.name,
                  state.cycle_id,
                )
              _ ->
                slog.warn(
                  "cognitive",
                  "do_load_profile",
                  "Failed to start agent: " <> spec.name,
                  state.cycle_id,
                )
            }
          })
        None -> Nil
      }

      // Notify UI
      process.send(state.notify, types.ProfileNotification(name:))

      let agent_names =
        list.map(agent_specs, fn(s) { s.name })
        |> string.join(", ")
      process.send(
        reply_to,
        CognitiveReply(
          response: "[Profile switched to '"
            <> name
            <> "' — agents: "
            <> agent_names
            <> "]",
          model: state.model,
          usage: None,
        ),
      )

      CognitiveState(
        ..state,
        tools:,
        system:,
        model: task_model,
        task_model:,
        reasoning_model:,
        messages: [],
        dprime_state:,
        output_dprime_state:,
        active_profile: Some(name),
      )
    }
  }
}

fn profile_agent_specs(
  p: profile_types.Profile,
  provider: Provider,
  task_model: String,
  write_anywhere: Bool,
) -> List(types.AgentSpec) {
  list.map(p.agents, fn(agent_def) {
    let tools_list = resolve_agent_tools(agent_def.tools)
    let model = task_model
    let system_prompt = case agent_def.system_prompt {
      Some(sp) -> sp
      None ->
        "You are a " <> agent_def.name <> " agent. " <> agent_def.description
    }
    let tool_executor = build_tool_executor(agent_def.tools, write_anywhere)
    types.AgentSpec(
      name: agent_def.name,
      human_name: string.capitalise(agent_def.name),
      description: agent_def.description,
      system_prompt:,
      provider:,
      model:,
      max_tokens: 4096,
      max_turns: agent_def.max_turns,
      max_consecutive_errors: 3,
      tools: tools_list,
      restart: types.Permanent,
      tool_executor:,
    )
  })
}

fn resolve_agent_tools(tool_groups: List(String)) -> List(llm_types.Tool) {
  list.flat_map(tool_groups, fn(group) {
    case group {
      "web" -> tools_web.all()
      "builtin" -> builtin.all()
      _ -> []
    }
  })
}

fn build_tool_executor(
  tool_groups: List(String),
  _write_anywhere: Bool,
) -> fn(llm_types.ToolCall) -> llm_types.ToolResult {
  let has_web = list.contains(tool_groups, "web")
  fn(call: llm_types.ToolCall) -> llm_types.ToolResult {
    case call.name {
      "fetch_url" if has_web -> tools_web.execute(call)
      _ -> builtin.execute(call)
    }
  }
}

// ---------------------------------------------------------------------------
// Output Gate — spawn and handle
// ---------------------------------------------------------------------------

fn spawn_output_gate(
  state: CognitiveState,
  output_state: dprime_types.DprimeState,
  report_text: String,
  reply_to: Subject(CognitiveReply),
  messages: List(llm_types.Message),
  task_id: String,
  modification_count: Int,
) -> CognitiveState {
  let cycle_id = option.unwrap(state.cycle_id, task_id)
  let self = state.self
  let provider = state.provider
  let model = state.model
  let verbose = state.verbose
  let query = state.last_user_input
  process.spawn_unlinked(fn() {
    let result =
      output_gate.evaluate(
        report_text,
        query,
        output_state,
        provider,
        model,
        cycle_id,
        verbose,
      )
    process.send(
      self,
      types.OutputGateComplete(
        cycle_id:,
        result:,
        report_text:,
        modification_count:,
        reply_to:,
      ),
    )
  })
  slog.info(
    "cognitive",
    "spawn_output_gate",
    "Spawned output gate evaluation",
    state.cycle_id,
  )
  CognitiveState(
    ..state,
    messages:,
    status: Thinking(task_id:),
    pending: dict.delete(state.pending, task_id),
  )
}

fn handle_output_gate_complete(
  state: CognitiveState,
  _cycle_id: String,
  result: dprime_types.GateResult,
  report_text: String,
  modification_count: Int,
  reply_to: Subject(types.CognitiveReply),
) -> CognitiveState {
  let max_modifications = 2
  let explanation = result.explanation
  case result.decision {
    dprime_types.Accept -> {
      slog.info(
        "cognitive",
        "handle_output_gate_complete",
        "Output gate: ACCEPT",
        state.cycle_id,
      )
      process.send(
        reply_to,
        CognitiveReply(response: report_text, model: state.model, usage: None),
      )
      CognitiveState(..state, status: Idle)
    }
    dprime_types.Modify -> {
      case modification_count >= max_modifications {
        True -> {
          slog.warn(
            "cognitive",
            "handle_output_gate_complete",
            "Output gate: MODIFY exceeded max modifications, delivering with warning",
            state.cycle_id,
          )
          let warning =
            "\n\n---\nQuality warning: This report was flagged for review but could not be fully corrected. Issues: "
            <> explanation
          process.send(
            reply_to,
            CognitiveReply(
              response: report_text <> warning,
              model: state.model,
              usage: None,
            ),
          )
          CognitiveState(..state, status: Idle)
        }
        False -> {
          slog.info(
            "cognitive",
            "handle_output_gate_complete",
            "Output gate: MODIFY (" <> explanation <> ")",
            state.cycle_id,
          )
          let correction_msg =
            llm_types.Message(role: llm_types.User, content: [
              llm_types.TextContent(
                text: "The quality gate flagged the following issues with your report. Please revise:\n\n"
                <> explanation
                <> "\n\nPlease produce an updated report addressing these issues.",
              ),
            ])
          let messages = list.append(state.messages, [correction_msg])
          let new_state = CognitiveState(..state, messages:)
          let task_id = cycle_log.generate_uuid()
          let req = build_request(new_state, messages)
          worker.spawn_think(task_id, req, new_state.provider, new_state.self)
          CognitiveState(
            ..new_state,
            status: Thinking(task_id:),
            pending: dict.insert(
              new_state.pending,
              task_id,
              PendingThink(
                task_id:,
                model: new_state.model,
                fallback_from: None,
                reply_to:,
                output_gate_count: modification_count + 1,
                empty_retried: False,
              ),
            ),
          )
        }
      }
    }
    dprime_types.Reject -> {
      slog.warn(
        "cognitive",
        "handle_output_gate_complete",
        "Output gate: REJECT (" <> explanation <> ")",
        state.cycle_id,
      )
      process.send(
        reply_to,
        CognitiveReply(
          response: "[Report rejected by quality gate: " <> explanation <> "]",
          model: state.model,
          usage: None,
        ),
      )
      CognitiveState(..state, status: Idle)
    }
  }
}

/// Set the supervisor reference on the cognitive state (called from springdrift.gleam after startup).
pub fn set_supervisor(
  cognitive: Subject(CognitiveMessage),
  sup: Subject(types.SupervisorMessage),
) -> Nil {
  process.send(cognitive, types.SetSupervisor(supervisor: sup))
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

/// Spawn the Archivist after each reply. Called after sending CognitiveReply.
fn maybe_spawn_archivist(
  state: CognitiveState,
  response_text: String,
  model_used: String,
  usage: Option(llm_types.Usage),
) -> Nil {
  let cycle_id = option.unwrap(state.cycle_id, "unknown")
  let #(input_tokens, output_tokens) = case usage {
    Some(u) -> #(u.input_tokens, u.output_tokens)
    None -> #(0, 0)
  }
  let ctx =
    archivist.ArchivistContext(
      cycle_id:,
      parent_cycle_id: None,
      user_input: state.last_user_input,
      final_response: response_text,
      agent_completions: list.reverse(state.agent_completions),
      model_used:,
      classification: case state.model == state.reasoning_model {
        True -> "complex"
        False -> "simple"
      },
      total_input_tokens: input_tokens,
      total_output_tokens: output_tokens,
      tool_calls: list.length(state.agent_completions),
      dprime_decisions: [],
      thread_index_json: "",
    )
  archivist.spawn(
    ctx,
    state.provider,
    state.archivist_model,
    state.narrative_dir,
    state.cbr_dir,
    state.verbose,
    state.librarian,
  )
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
