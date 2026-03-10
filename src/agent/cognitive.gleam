import agent/cognitive/agents as cognitive_agents
import agent/cognitive/llm as cognitive_llm
import agent/cognitive/memory as cognitive_memory
import agent/cognitive/profile as cognitive_profile
import agent/cognitive/safety as cognitive_safety
import agent/cognitive_config
import agent/cognitive_state.{type CognitiveState, CognitiveState}
import agent/types.{
  type CognitiveMessage, type CognitiveReply, AgentComplete, AgentEvent,
  Classifying, CognitiveReply, Idle, PendingThink, RestoreMessages, SaveResult,
  SetModel, ThinkComplete, ThinkError, ThinkWorkerDown, Thinking, UserAnswer,
  UserInput,
}
import agent/worker
import cycle_log
import dag/types as dag_types
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import llm/response
import llm/types as llm_types
import narrative/curator as narrative_curator
import narrative/librarian
import query_complexity
import slog
import tools/builtin
import tools/memory

@external(erlang, "springdrift_ffi", "rescue")
fn rescue(body: fn() -> a) -> Result(a, String)

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start the cognitive loop process. Returns a Subject for sending messages.
pub fn start(cfg: cognitive_config.CognitiveConfig) -> Subject(CognitiveMessage) {
  // The cognitive loop gets agent tools + request_human_input + memory tools
  let tools =
    list.flatten([
      [builtin.human_input_tool()],
      memory.all(),
      cfg.agent_tools,
    ])
  let setup = process.new_subject()
  process.spawn_unlinked(fn() {
    let self = process.new_subject()
    let state =
      CognitiveState(
        self:,
        provider: cfg.provider,
        model: cfg.task_model,
        system: cfg.system,
        max_tokens: cfg.max_tokens,
        max_context_messages: cfg.max_context_messages,
        tools:,
        messages: cfg.initial_messages,
        registry: cfg.registry,
        pending: dict.new(),
        status: Idle,
        cycle_id: None,
        verbose: cfg.verbose,
        notify: cfg.notify,
        task_model: cfg.task_model,
        reasoning_model: cfg.reasoning_model,
        save_in_progress: False,
        save_pending: None,
        dprime_state: cfg.dprime_state,
        narrative_dir: cfg.narrative_dir,
        cbr_dir: cfg.cbr_dir,
        archivist_model: cfg.archivist_model,
        librarian: cfg.librarian,
        agent_completions: [],
        last_user_input: "",
        active_profile: None,
        supervisor: None,
        profile_dirs: cfg.profile_dirs,
        write_anywhere: cfg.write_anywhere,
        output_dprime_state: None,
        dprime_decisions: [],
        curator: cfg.curator,
      )
    process.send(setup, self)
    cognitive_loop(state)
  })
  let assert Ok(subj) = process.receive(setup, 5000)
  subj
}

/// Build a Tool definition from an AgentSpec so the LLM can call agents.
pub fn agent_to_tool(spec: types.AgentSpec) -> llm_types.Tool {
  types.agent_to_tool(spec)
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
    UserAnswer(answer) -> cognitive_agents.handle_user_answer(state, answer)
    ThinkComplete(task_id, resp) -> handle_think_complete(state, task_id, resp)
    ThinkError(task_id, error, retryable) ->
      cognitive_llm.handle_think_error(state, task_id, error, retryable)
    ThinkWorkerDown(task_id, reason) ->
      cognitive_llm.handle_think_down(state, task_id, reason)
    AgentComplete(outcome) ->
      cognitive_agents.handle_agent_complete(state, outcome)
    types.AgentQuestion(question, agent, reply_to) ->
      cognitive_agents.handle_agent_question(state, question, agent, reply_to)
    AgentEvent(event) -> cognitive_agents.handle_agent_event(state, event)
    SaveResult(error) -> cognitive_memory.handle_save_result(state, error)
    SetModel(model) -> CognitiveState(..state, model:)
    RestoreMessages(messages) -> {
      let new_state = CognitiveState(..state, messages:, cycle_id: None)
      cognitive_memory.request_save(new_state, messages)
    }
    types.ClassifyComplete(cycle_id, complexity, text, reply_to) ->
      handle_classify_complete(state, cycle_id, complexity, text, reply_to)
    types.SafetyGateComplete(task_id, result, resp, calls, reply_to) ->
      cognitive_safety.handle_safety_gate_complete(
        state,
        task_id,
        result,
        resp,
        calls,
        reply_to,
        cognitive_agents.dispatch_tool_calls,
      )
    types.InputSafetyGateComplete(cycle_id, result, model, text, reply_to) ->
      cognitive_safety.handle_input_safety_gate_complete(
        state,
        cycle_id,
        result,
        model,
        text,
        reply_to,
      )
    types.PostExecutionGateComplete(cycle_id, result, pre_score, reply_to) ->
      cognitive_safety.handle_post_execution_gate_complete(
        state,
        cycle_id,
        result,
        pre_score,
        reply_to,
      )
    types.LoadProfile(name, reply_to) ->
      cognitive_profile.handle_load_profile(state, name, reply_to)
    types.SetSupervisor(supervisor:) ->
      CognitiveState(..state, supervisor: Some(supervisor))
    types.OutputGateComplete(
      cycle_id,
      result,
      report_text,
      modification_count,
      reply_to,
    ) ->
      cognitive_safety.handle_output_gate_complete(
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
      // Clear Curator scratchpad from previous cycle
      case state.curator {
        option.Some(cur) ->
          narrative_curator.clear_cycle(cur, option.unwrap(state.cycle_id, ""))
        option.None -> Nil
      }
      let state =
        CognitiveState(
          ..state,
          last_user_input: text,
          agent_completions: [],
          dprime_decisions: [],
        )

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
        None ->
          cognitive_llm.proceed_with_model(
            state,
            model,
            text,
            cycle_id,
            reply_to,
          )
        Some(_) ->
          cognitive_safety.spawn_input_safety_gate(
            state,
            cycle_id,
            model,
            text,
            reply_to,
          )
      }
    }
    _ -> state
  }
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
              let nudge_msg =
                llm_types.Message(role: llm_types.User, content: [
                  llm_types.TextContent(
                    "Your previous response was empty. Please provide a substantive response.",
                  ),
                ])
              let retry_messages = list.append(state.messages, [nudge_msg])
              let req =
                cognitive_llm.build_request_with_model(
                  state,
                  req_model,
                  retry_messages,
                )
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
                  cognitive_safety.spawn_output_gate(
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
                  // Update DAG node with final outcome
                  case state.librarian {
                    Some(lib) ->
                      process.send(
                        lib,
                        librarian.UpdateNode(node: dag_types.CycleNode(
                          cycle_id: option.unwrap(state.cycle_id, task_id),
                          parent_id: None,
                          node_type: dag_types.CognitiveCycle,
                          timestamp: "",
                          outcome: dag_types.NodeSuccess,
                          model: reply_model,
                          complexity: "",
                          tool_calls: [],
                          dprime_gates: list.map(state.dprime_decisions, fn(d) {
                            dag_types.GateSummary(
                              gate: d.gate,
                              decision: d.decision,
                              score: d.score,
                            )
                          }),
                          tokens_in: resp.usage.input_tokens,
                          tokens_out: resp.usage.output_tokens,
                          duration_ms: 0,
                          agent_output: None,
                        )),
                      )
                    None -> Nil
                  }
                  process.send(
                    rt,
                    CognitiveReply(
                      response: reply_text,
                      model: reply_model,
                      usage: Some(resp.usage),
                    ),
                  )
                  // Spawn Archivist (fire-and-forget)
                  cognitive_memory.maybe_spawn_archivist(
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
                  cognitive_memory.request_save(new_state, messages)
                }
              }
            }
          }
        }
        True -> {
          let calls = response.tool_calls(resp)
          // D' gate intercept: if enabled, evaluate before dispatch
          case state.dprime_state {
            None ->
              cognitive_agents.dispatch_tool_calls(
                state,
                task_id,
                resp,
                calls,
                rt,
              )
            Some(_dprime_st) ->
              cognitive_safety.spawn_safety_gate(
                state,
                task_id,
                resp,
                calls,
                rt,
              )
          }
        }
      }
    }
    // dict.get only returns what's stored, but guard against non-PendingThink
    Ok(_) -> state
  }
}

/// Set the supervisor reference on the cognitive state (called from springdrift.gleam after startup).
pub fn set_supervisor(
  cognitive: Subject(CognitiveMessage),
  sup: Subject(types.SupervisorMessage),
) -> Nil {
  process.send(cognitive, types.SetSupervisor(supervisor: sup))
}
