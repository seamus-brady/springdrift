import agent/cognitive/agents as cognitive_agents
import agent/cognitive/llm as cognitive_llm
import agent/cognitive/memory as cognitive_memory
import agent/cognitive/profile as cognitive_profile
import agent/cognitive/safety as cognitive_safety
import agent/cognitive_config
import agent/cognitive_state.{
  type CognitiveState, CognitiveState, IdentityContext, MemoryContext,
  RuntimeConfig,
}
import agent/registry as agent_registry
import agent/types.{
  type CognitiveMessage, type CognitiveReply, AgentComplete, AgentEvent,
  Classifying, CognitiveReply, Idle, InputQueueFull, InputQueued, PendingThink,
  QueuedInput, QueuedSchedulerInput, QueuedSensoryInput, RestoreMessages,
  SaveResult, SchedulerJobStarted, SetModel, ThinkComplete, ThinkError,
  ThinkWorkerDown, Thinking, UserAnswer, UserInput,
}
import agent/worker
import cycle_log
import dag/types as dag_types
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import llm/response
import llm/types as llm_types
import narrative/curator as narrative_curator
import narrative/librarian
import planner/log as planner_log
import planner/types as planner_types
import query_complexity
import scheduler/types as scheduler_types
import slog
import tools/builtin
import tools/memory
import tools/planner as planner_tools

@external(erlang, "springdrift_ffi", "rescue")
fn rescue(body: fn() -> a) -> Result(a, String)

@external(erlang, "springdrift_ffi", "monotonic_now_ms")
fn monotonic_now_ms() -> Int

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start the cognitive loop process. Returns a Subject for sending messages.
pub fn start(
  cfg: cognitive_config.CognitiveConfig,
) -> Result(Subject(CognitiveMessage), Nil) {
  // The cognitive loop gets agent tools + request_human_input + memory + planner tools
  let tools =
    list.flatten([
      [builtin.human_input_tool()],
      memory.all(),
      planner_tools.all(),
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
        archivist_model: cfg.archivist_model,
        archivist_max_tokens: cfg.archivist_max_tokens,
        save_in_progress: False,
        save_pending: None,
        dprime_state: cfg.dprime_state,
        output_dprime_state: cfg.output_dprime_state,
        cycle_tool_calls: [],
        cycle_started_ms: 0,
        cycle_node_type: dag_types.CognitiveCycle,
        dprime_decisions: [],
        memory: MemoryContext(
          narrative_dir: cfg.narrative_dir,
          cbr_dir: cfg.cbr_dir,
          librarian: cfg.librarian,
          curator: cfg.curator,
        ),
        agent_completions: [],
        active_delegations: dict.new(),
        last_user_input: "",
        input_queue: [],
        input_queue_cap: cfg.input_queue_cap,
        supervisor: None,
        identity: IdentityContext(
          agent_uuid: cfg.agent_uuid,
          session_since: cfg.session_since,
          active_profile: None,
          profile_dirs: cfg.profile_dirs,
          write_anywhere: cfg.write_anywhere,
        ),
        config: RuntimeConfig(
          retry_config: cfg.retry_config,
          classify_timeout_ms: cfg.classify_timeout_ms,
          threading_config: cfg.threading_config,
          memory_limits: cfg.memory_limits,
          how_to_content: cfg.how_to_content,
          max_delegation_depth: cfg.max_delegation_depth,
        ),
        redact_secrets: cfg.redact_secrets,
        pending_sensory_events: [],
        active_task_id: None,
        planner_dir: cfg.planner_dir,
      )
    process.send(setup, self)
    cognitive_loop(state)
  })
  case process.receive(setup, 5000) {
    Ok(subj) -> Ok(subj)
    Error(_) -> {
      slog.log_error(
        "cognitive",
        "start",
        "Cognitive loop failed to start within 5s",
        None,
      )
      Error(Nil)
    }
  }
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
      types.SchedulerInput(..) -> "SchedulerInput"
      types.OutputGateComplete(..) -> "OutputGateComplete"
      types.QueuedSensoryEvent(..) -> "QueuedSensoryEvent"
      types.ForecasterSuggestion(..) -> "ForecasterSuggestion"
      types.AgentProgress(..) -> "AgentProgress"
    },
    state.cycle_id,
  )
  let next = case msg {
    UserInput(text, reply_to) -> handle_user_input(state, text, reply_to)
    UserAnswer(answer) -> cognitive_agents.handle_user_answer(state, answer)
    ThinkComplete(task_id, resp) -> handle_think_complete(state, task_id, resp)
    ThinkError(task_id, error, retryable) ->
      cognitive_llm.handle_think_error(state, task_id, error, retryable)
    ThinkWorkerDown(task_id, reason) ->
      cognitive_llm.handle_think_down(state, task_id, reason)
    AgentComplete(outcome) ->
      cognitive_agents.handle_agent_complete(state, outcome)
    types.AgentProgress(progress) ->
      cognitive_agents.handle_agent_progress(state, progress)
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
    types.SchedulerInput(
      job_name:,
      query:,
      kind:,
      for_:,
      title:,
      body:,
      tags:,
      reply_to:,
    ) ->
      handle_scheduler_input(
        state,
        job_name,
        query,
        kind,
        for_,
        title,
        body,
        tags,
        reply_to,
      )
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
    types.QueuedSensoryEvent(event:) -> {
      slog.debug(
        "cognitive",
        "handle_message",
        "Sensory event accumulated: " <> event.name,
        state.cycle_id,
      )
      CognitiveState(
        ..state,
        pending_sensory_events: list.append(state.pending_sensory_events, [
          event,
        ]),
      )
    }
    types.ForecasterSuggestion(
      task_id:,
      task_title:,
      plan_dprime:,
      explanation:,
    ) ->
      handle_forecaster_suggestion(
        state,
        task_id,
        task_title,
        plan_dprime,
        explanation,
      )
  }
  // If a cycle just completed (transition to Idle) and there's an active task,
  // append the cycle_id to that task so the forecaster can track progress.
  let next = case
    next.status,
    state.status,
    next.active_task_id,
    next.cycle_id
  {
    Idle, prev_status, Some(task_id), Some(cycle_id) if prev_status != Idle -> {
      planner_log.append_task_op(
        next.planner_dir,
        planner_types.AddCycleId(task_id:, cycle_id:),
      )
      case next.memory.librarian {
        Some(lib) ->
          librarian.notify_task_op(
            lib,
            planner_types.AddCycleId(task_id:, cycle_id:),
          )
        None -> Nil
      }
      next
    }
    _, _, _, _ -> next
  }
  maybe_drain_queue(next)
}

fn maybe_drain_queue(state: CognitiveState) -> CognitiveState {
  case state.status, state.input_queue {
    Idle, [QueuedInput(text:, reply_to:), ..rest] -> {
      slog.info(
        "cognitive",
        "maybe_drain_queue",
        "Draining queued input (remaining: "
          <> int.to_string(list.length(rest))
          <> ")",
        state.cycle_id,
      )
      handle_user_input(
        CognitiveState(..state, input_queue: rest),
        text,
        reply_to,
      )
    }
    Idle,
      [
        QueuedSchedulerInput(
          job_name:,
          query:,
          kind:,
          for_:,
          title:,
          body:,
          tags:,
          reply_to:,
        ),
        ..rest
      ]
    -> {
      slog.info(
        "cognitive",
        "maybe_drain_queue",
        "Draining queued scheduler input '"
          <> job_name
          <> "' (remaining: "
          <> int.to_string(list.length(rest))
          <> ")",
        state.cycle_id,
      )
      handle_scheduler_input(
        CognitiveState(..state, input_queue: rest),
        job_name,
        query,
        kind,
        for_,
        title,
        body,
        tags,
        reply_to,
      )
    }
    Idle, [QueuedSensoryInput(event:), ..rest] -> {
      slog.debug(
        "cognitive",
        "maybe_drain_queue",
        "Draining queued sensory event: " <> event.name,
        state.cycle_id,
      )
      let next_state =
        CognitiveState(
          ..state,
          input_queue: rest,
          pending_sensory_events: list.append(state.pending_sensory_events, [
            event,
          ]),
        )
      // Sensory events don't trigger cycles, so continue draining
      maybe_drain_queue(next_state)
    }
    _, _ -> state
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
      cycle_log.log_human_input(
        cycle_id,
        state.cycle_id,
        text,
        state.redact_secrets,
      )
      // Clear Curator scratchpad from previous cycle
      case state.memory.curator {
        option.Some(cur) ->
          narrative_curator.clear_cycle(cur, option.unwrap(state.cycle_id, ""))
        option.None -> Nil
      }
      let state =
        CognitiveState(
          ..state,
          last_user_input: text,
          agent_completions: [],
          cycle_tool_calls: [],
          cycle_started_ms: monotonic_now_ms(),
          cycle_node_type: dag_types.CognitiveCycle,
          dprime_decisions: [],
        )

      // Spawn async classification worker — rescue catches panics
      let self = state.self
      let provider = state.provider
      let task_model = state.task_model
      let classify_timeout_ms = state.config.classify_timeout_ms
      process.spawn_unlinked(fn() {
        let complexity = case
          rescue(fn() {
            query_complexity.classify(
              text,
              provider,
              task_model,
              classify_timeout_ms,
            )
          })
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
    _ -> {
      let queue_len = list.length(state.input_queue)
      case queue_len >= state.input_queue_cap {
        True -> {
          slog.warn(
            "cognitive",
            "handle_user_input",
            "Input queue full (cap="
              <> int.to_string(state.input_queue_cap)
              <> "), rejecting input",
            state.cycle_id,
          )
          process.send(
            state.notify,
            InputQueueFull(queue_cap: state.input_queue_cap),
          )
          process.send(
            reply_to,
            CognitiveReply(
              response: "[System: input queue full ("
                <> int.to_string(state.input_queue_cap)
                <> " pending), please wait.]",
              model: state.model,
              usage: None,
            ),
          )
          state
        }
        False -> {
          let position = queue_len + 1
          let new_queue =
            list.append(state.input_queue, [QueuedInput(text:, reply_to:)])
          slog.info(
            "cognitive",
            "handle_user_input",
            "Input queued at position "
              <> int.to_string(position)
              <> " (queue size: "
              <> int.to_string(position)
              <> ")",
            state.cycle_id,
          )
          process.send(
            state.notify,
            InputQueued(position:, queue_size: position),
          )
          CognitiveState(..state, input_queue: new_queue)
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// SchedulerInput — typed input from the scheduler subsystem
// ---------------------------------------------------------------------------

fn handle_scheduler_input(
  state: CognitiveState,
  job_name: String,
  query: String,
  kind: scheduler_types.JobKind,
  for_: scheduler_types.ForTarget,
  title: String,
  body: String,
  tags: List(String),
  reply_to: Subject(CognitiveReply),
) -> CognitiveState {
  // Guard: queue if not idle
  case state.status {
    Idle -> {
      let cycle_id = cycle_log.generate_uuid()
      cycle_log.log_human_input(
        cycle_id,
        state.cycle_id,
        "[scheduler:" <> job_name <> "] " <> query,
        state.redact_secrets,
      )
      // Clear Curator scratchpad from previous cycle
      case state.memory.curator {
        option.Some(cur) ->
          narrative_curator.clear_cycle(cur, option.unwrap(state.cycle_id, ""))
        option.None -> Nil
      }
      let state =
        CognitiveState(
          ..state,
          last_user_input: query,
          agent_completions: [],
          cycle_tool_calls: [],
          cycle_started_ms: monotonic_now_ms(),
          cycle_node_type: dag_types.SchedulerCycle,
          dprime_decisions: [],
        )

      // Select input text based on job kind
      let input_text = case kind {
        scheduler_types.Reminder | scheduler_types.Appointment -> body
        scheduler_types.RecurringTask | scheduler_types.Todo -> query
      }

      // Build scheduler context XML block
      let kind_str = case kind {
        scheduler_types.RecurringTask -> "recurring_task"
        scheduler_types.Reminder -> "reminder"
        scheduler_types.Todo -> "todo"
        scheduler_types.Appointment -> "appointment"
      }
      let for_str = case for_ {
        scheduler_types.ForAgent -> "agent"
        scheduler_types.ForUser -> "user"
      }
      let tags_str = string.join(tags, ", ")
      let context_xml =
        "<scheduler_context>\n  <job_name>"
        <> job_name
        <> "</job_name>\n  <kind>"
        <> kind_str
        <> "</kind>\n  <for>"
        <> for_str
        <> "</for>\n  <title>"
        <> title
        <> "</title>\n  <tags>"
        <> tags_str
        <> "</tags>\n</scheduler_context>\n\n"
      let text_with_context = context_xml <> input_text

      // Emit SchedulerJobStarted notification
      process.send(
        state.notify,
        SchedulerJobStarted(name: job_name, kind: kind_str),
      )

      // If ForUser, also send SchedulerReminder for TUI display
      case for_ {
        scheduler_types.ForUser ->
          process.send(
            state.notify,
            types.SchedulerReminder(name: job_name, title:, body:),
          )
        scheduler_types.ForAgent -> Nil
      }

      // Inject scheduler trigger as a sensory event so it appears in <events>
      let state =
        CognitiveState(
          ..state,
          pending_sensory_events: list.append(state.pending_sensory_events, [
            types.SensoryEvent(
              name: "scheduler:" <> job_name,
              title:,
              body: input_text,
              fired_at: get_datetime(),
            ),
          ]),
        )

      // Skip classification — always use task_model, go straight to LLM
      cognitive_llm.proceed_with_model(
        state,
        state.task_model,
        text_with_context,
        cycle_id,
        reply_to,
        dag_types.SchedulerCycle,
      )
    }
    _ -> {
      // Queue the scheduler input
      let queue_len = list.length(state.input_queue)
      case queue_len >= state.input_queue_cap {
        True -> {
          slog.warn(
            "cognitive",
            "handle_scheduler_input",
            "Input queue full, rejecting scheduler job '" <> job_name <> "'",
            state.cycle_id,
          )
          process.send(
            state.notify,
            InputQueueFull(queue_cap: state.input_queue_cap),
          )
          process.send(
            reply_to,
            CognitiveReply(
              response: "[System: input queue full, scheduler job '"
                <> job_name
                <> "' rejected]",
              model: state.model,
              usage: None,
            ),
          )
          state
        }
        False -> {
          let position = queue_len + 1
          let new_queue =
            list.append(state.input_queue, [
              types.QueuedSchedulerInput(
                job_name:,
                query:,
                kind:,
                for_:,
                title:,
                body:,
                tags:,
                reply_to:,
              ),
            ])
          slog.info(
            "cognitive",
            "handle_scheduler_input",
            "Scheduler job '"
              <> job_name
              <> "' queued at position "
              <> int.to_string(position),
            state.cycle_id,
          )
          process.send(
            state.notify,
            InputQueued(position:, queue_size: position),
          )
          CognitiveState(..state, input_queue: new_queue)
        }
      }
    }
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
            dag_types.CognitiveCycle,
          )
        Some(dprime_st) ->
          cognitive_safety.spawn_input_safety_gate(
            state,
            cycle_id,
            model,
            text,
            reply_to,
            dprime_st,
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
      node_type:,
      ..,
    )) -> {
      let cycle_id = option.unwrap(state.cycle_id, task_id)
      cycle_log.log_llm_response(cycle_id, resp, state.redact_secrets)
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
              worker.spawn_think(
                new_task_id,
                req,
                state.provider,
                state.self,
                state.config.retry_config,
              )
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
                    node_type:,
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
                  let duration_ms = case state.cycle_started_ms {
                    0 -> 0
                    started -> monotonic_now_ms() - started
                  }
                  case state.memory.librarian {
                    Some(lib) ->
                      process.send(
                        lib,
                        librarian.UpdateNode(node: dag_types.CycleNode(
                          cycle_id: option.unwrap(state.cycle_id, task_id),
                          parent_id: None,
                          node_type: node_type,
                          timestamp: "",
                          outcome: dag_types.NodeSuccess,
                          model: reply_model,
                          complexity: "",
                          tool_calls: state.cycle_tool_calls,
                          dprime_gates: list.map(state.dprime_decisions, fn(d) {
                            dag_types.GateSummary(
                              gate: d.gate,
                              decision: d.decision,
                              score: d.score,
                            )
                          }),
                          tokens_in: resp.usage.input_tokens,
                          tokens_out: resp.usage.output_tokens,
                          duration_ms:,
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
            Some(dprime_st) ->
              cognitive_safety.spawn_safety_gate(
                state,
                task_id,
                resp,
                calls,
                rt,
                dprime_st,
              )
          }
        }
      }
    }
    // dict.get only returns what's stored, but guard against non-PendingThink
    Ok(_) -> state
  }
}

// ---------------------------------------------------------------------------
// ForecasterSuggestion — typed replan trigger from the Forecaster
// ---------------------------------------------------------------------------

fn handle_forecaster_suggestion(
  state: CognitiveState,
  task_id: String,
  task_title: String,
  plan_dprime: Float,
  explanation: String,
) -> CognitiveState {
  case state.status {
    Idle -> {
      slog.info(
        "cognitive",
        "handle_forecaster_suggestion",
        "Dispatching planner replan for task "
          <> task_id
          <> " (D'="
          <> float.to_string(plan_dprime)
          <> ")",
        state.cycle_id,
      )
      // Build forecast context for the planner
      let forecast_context =
        "Task: "
        <> task_title
        <> " (id: "
        <> task_id
        <> ")\nD' health score: "
        <> float.to_string(plan_dprime)
        <> "\nExplanation: "
        <> explanation

      // Dispatch to the existing planner agent with forecast context
      case agent_registry.get_task_subject(state.registry, "planner") {
        Some(task_subject) -> {
          let cycle_id = cycle_log.generate_uuid()
          let agent_task_id = cycle_log.generate_uuid()
          let instruction =
            "Replan task '"
            <> task_title
            <> "': the Forecaster detected health deterioration (D'="
            <> float.to_string(plan_dprime)
            <> "). "
            <> explanation
            <> "\nProduce a revised plan."

          let agent_task =
            types.AgentTask(
              task_id: agent_task_id,
              tool_use_id: "forecaster_replan_" <> task_id,
              instruction:,
              context: forecast_context,
              parent_cycle_id: cycle_id,
              reply_to: state.self,
              depth: 1,
            )
          process.send(task_subject, agent_task)
          process.send(
            state.notify,
            types.PlannerNotification(
              task_id:,
              title: task_title,
              action: "replan",
            ),
          )

          // Create a synthetic reply_to for the cycle
          let cycle_reply = process.new_subject()

          CognitiveState(
            ..state,
            cycle_id: Some(cycle_id),
            cycle_started_ms: monotonic_now_ms(),
            cycle_node_type: dag_types.CognitiveCycle,
            status: types.WaitingForAgents(
              pending_ids: [agent_task_id],
              accumulated_results: [],
              reply_to: cycle_reply,
            ),
            pending: dict.insert(
              state.pending,
              agent_task_id,
              types.PendingAgent(
                task_id: agent_task_id,
                tool_use_id: "forecaster_replan_" <> task_id,
                agent: "planner",
                reply_to: cycle_reply,
              ),
            ),
          )
        }
        None -> {
          slog.warn(
            "cognitive",
            "handle_forecaster_suggestion",
            "Planner agent not available, deferring as sensory event",
            state.cycle_id,
          )
          let event =
            types.SensoryEvent(
              name: "forecaster_replan",
              title: "Replan suggested: " <> task_title,
              body: "Task "
                <> task_id
                <> " (D'="
                <> float.to_string(plan_dprime)
                <> "): "
                <> explanation,
              fired_at: get_datetime(),
            )
          CognitiveState(
            ..state,
            pending_sensory_events: list.append(state.pending_sensory_events, [
              event,
            ]),
          )
        }
      }
    }
    _ -> {
      // Not idle — defer as sensory event for next cycle
      slog.debug(
        "cognitive",
        "handle_forecaster_suggestion",
        "Not idle, deferring forecaster suggestion as sensory event",
        state.cycle_id,
      )
      let event =
        types.SensoryEvent(
          name: "forecaster_replan",
          title: "Replan suggested: " <> task_title,
          body: "Task "
            <> task_id
            <> " (D'="
            <> float.to_string(plan_dprime)
            <> "): "
            <> explanation,
          fired_at: get_datetime(),
        )
      CognitiveState(
        ..state,
        pending_sensory_events: list.append(state.pending_sensory_events, [
          event,
        ]),
      )
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
