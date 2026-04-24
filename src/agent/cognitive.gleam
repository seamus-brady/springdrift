// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/cognitive/agents as cognitive_agents
import agent/cognitive/llm as cognitive_llm
import agent/cognitive/memory as cognitive_memory
import agent/cognitive/output
import agent/cognitive/safety as cognitive_safety
import agent/cognitive_config
import agent/cognitive_state.{
  type CognitiveState, CognitiveState, IdentityContext, MemoryContext,
  RuntimeConfig,
}
import agent/registry as agent_registry
import agent/team
import agent/types.{
  type CognitiveMessage, AgentComplete, AgentEvent, Classifying, Idle,
  InputQueueFull, InputQueued, PendingThink, QueuedInput, QueuedSchedulerInput,
  QueuedSensoryInput, SchedulerJobStarted, SetModel, ThinkComplete, ThinkError,
  ThinkWorkerDown, Thinking, UserAnswer, UserInput,
}
import agent/worker
import agentlair/emitter as agentlair_emitter
import cycle_log
import dag/types as dag_types
import dprime/meta as dprime_meta
import frontdoor/types as frontdoor_types
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import llm/response
import llm/types as llm_types
import meta/log as meta_log
import meta/types as meta_types
import narrative/curator as narrative_curator
import narrative/librarian
import normative/drift as normative_drift
import planner/log as planner_log
import planner/types as planner_types
import query_complexity
import scheduler/types as scheduler_types
import slog
import tools/builtin
import tools/captures as captures_tools
import tools/learning_goals as learning_goal_tools
import tools/memory
import tools/planner as planner_tools
import tools/strategies as strategy_tools

@external(erlang, "springdrift_ffi", "rescue")
fn rescue(body: fn() -> a) -> Result(a, String)

@external(erlang, "springdrift_ffi", "monotonic_now_ms")
fn monotonic_now_ms() -> Int

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

/// Maximum age for a queued user input before it is considered stale.
/// A queued input older than this, with newer user inputs behind it in the
/// queue, is dropped on drain rather than firing against obsolete context.
const stale_input_max_age_ms: Int = 60_000

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start the cognitive loop process. Returns a Subject for sending messages.
pub fn start(
  cfg: cognitive_config.CognitiveConfig,
) -> Result(Subject(CognitiveMessage), Nil) {
  // The cognitive loop gets agent tools + team tools + request_human_input + memory + planner tools
  let team_tools = list.map(cfg.team_specs, team.team_to_tool)
  let captures_tool_set = case cfg.captures_scanner_enabled {
    True -> captures_tools.all()
    False -> []
  }
  let tools =
    list.flatten([
      [builtin.human_input_tool()],
      memory.all(),
      planner_tools.all(),
      learning_goal_tools.all(),
      strategy_tools.all(),
      captures_tool_set,
      cfg.agent_tools,
      team_tools,
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
        thinking_budget_tokens: cfg.thinking_budget_tokens,
        archivist_model: cfg.archivist_model,
        archivist_max_tokens: cfg.archivist_max_tokens,
        appraiser_model: cfg.appraiser_model,
        appraiser_max_tokens: cfg.appraiser_max_tokens,
        appraisal_min_complexity: cfg.appraisal_min_complexity,
        appraisal_min_steps: cfg.appraisal_min_steps,
        input_dprime_state: cfg.input_dprime_state,
        tool_dprime_state: cfg.tool_dprime_state,
        output_dprime_state: cfg.output_dprime_state,
        cycle_tool_calls: [],
        cycle_started_ms: 0,
        cycle_tokens_in: 0,
        cycle_tokens_out: 0,
        cycle_node_type: dag_types.CognitiveCycle,
        dprime_decisions: [],
        pending_output_reply: None,
        pending_output_usage: None,
        retrieved_case_ids: [],
        memory: MemoryContext(
          narrative_dir: cfg.narrative_dir,
          cbr_dir: cfg.cbr_dir,
          librarian: cfg.librarian,
          curator: cfg.curator,
        ),
        agent_completions: [],
        active_delegations: dict.new(),
        last_user_input: "",
        team_specs: cfg.team_specs,
        input_queue: [],
        input_queue_cap: cfg.input_queue_cap,
        supervisor: None,
        scheduler: None,
        identity: IdentityContext(
          agent_uuid: cfg.agent_uuid,
          agent_name: cfg.agent_name,
          session_since: cfg.session_since,
          write_anywhere: cfg.write_anywhere,
        ),
        config: RuntimeConfig(
          retry_config: cfg.retry_config,
          classify_timeout_ms: cfg.classify_timeout_ms,
          threading_config: cfg.threading_config,
          memory_limits: cfg.memory_limits,
          how_to_content: cfg.how_to_content,
          max_delegation_depth: cfg.max_delegation_depth,
          sandbox_enabled: cfg.sandbox_enabled,
          deterministic_config: cfg.deterministic_config,
          fact_decay_half_life_days: cfg.fact_decay_half_life_days,
          escalation_config: cfg.escalation_config,
          gate_timeout_ms: cfg.gate_timeout_ms,
          normative_calculus_enabled: cfg.normative_calculus_enabled,
          character_spec: cfg.character_spec,
          team_guards: cfg.team_guards,
          agentlair_config: cfg.agentlair_config,
          strategy_registry_enabled: cfg.strategy_registry_enabled,
          evidence_config: cfg.evidence_config,
          frontdoor: cfg.frontdoor,
          captures_scanner_enabled: cfg.captures_scanner_enabled,
          captures_dir: cfg.captures_dir,
          captures_max_per_cycle: cfg.captures_max_per_cycle,
          deputies_enabled: cfg.deputies_enabled,
          deputies_model: cfg.deputies_model,
          deputies_max_tokens: cfg.deputies_max_tokens,
          deputy_timeout_ms: cfg.deputy_timeout_ms,
        ),
        redact_secrets: cfg.redact_secrets,
        pending_sensory_events: [],
        active_task_id: None,
        planner_dir: cfg.planner_dir,
        meta_state: case cfg.input_dprime_state {
          Some(_) -> {
            let meta_cfg =
              option.unwrap(cfg.meta_config, meta_types.default_config())
            // Restore from JSONL with configurable decay window
            Some(meta_log.restore_state(meta_cfg, meta_cfg.decay_days))
          }
          None -> None
        },
        consecutive_probe_failures: 0,
        output_gate_rejections: 0,
        cycles_today: 0,
        deferred_dispatches: [],
        watchdog_generation: 0,
        drift_state: case cfg.normative_calculus_enabled {
          True -> Some(normative_drift.new(20))
          False -> None
        },
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
      SetModel(..) -> "SetModel"
      types.ClassifyComplete(..) -> "ClassifyComplete"
      types.SafetyGateComplete(..) -> "SafetyGateComplete"
      types.InputSafetyGateComplete(..) -> "InputSafetyGateComplete"
      types.PostExecutionGateComplete(..) -> "PostExecutionGateComplete"
      types.SetSupervisor(..) -> "SetSupervisor"
      types.SchedulerInput(..) -> "SchedulerInput"
      types.OutputGateComplete(..) -> "OutputGateComplete"
      types.QueuedSensoryEvent(..) -> "QueuedSensoryEvent"
      types.ForecasterSuggestion(..) -> "ForecasterSuggestion"
      types.AgentProgress(..) -> "AgentProgress"
      types.GetMessages(..) -> "GetMessages"
      types.Ping(..) -> "Ping"
      types.GateTimeout(..) -> "GateTimeout"
      types.WatchdogTimeout(..) -> "WatchdogTimeout"
      types.InjectUserAnswer(..) -> "InjectUserAnswer"
      types.SetScheduler(..) -> "SetScheduler"
    },
    state.cycle_id,
  )
  let next = case msg {
    UserInput(source_id, text) -> handle_user_input(state, source_id, text)
    types.InjectUserAnswer(text:) ->
      cognitive_agents.handle_user_answer(state, text)
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
    SetModel(model) -> CognitiveState(..state, model:)
    types.SetScheduler(scheduler) ->
      CognitiveState(..state, scheduler: Some(scheduler))
    types.GetMessages(reply_to:) -> {
      process.send(reply_to, state.messages)
      state
    }
    types.Ping(reply_to:) -> {
      // Cheap liveness + status tag for /health. Deliberately avoids
      // copying the messages list (which can be large on a long
      // session); the pinger only needs to know we're reachable and
      // in what coarse state.
      let tag = case state.status {
        types.Idle -> "Idle"
        types.Classifying(..) -> "Classifying"
        types.Thinking(..) -> "Thinking"
        types.WaitingForAgents(..) -> "WaitingForAgents"
        types.WaitingForUser(..) -> "WaitingForUser"
        types.EvaluatingSafety(..) -> "EvaluatingSafety"
        types.EvaluatingInputSafety(..) -> "EvaluatingInputSafety"
        types.EvaluatingPostExecution(..) -> "EvaluatingPostExecution"
      }
      process.send(
        reply_to,
        types.PingReply(status_tag: tag, cycle_id: state.cycle_id),
      )
      state
    }
    types.GateTimeout(task_id:, gate:) ->
      cognitive_safety.handle_gate_timeout(state, task_id, gate)
    types.WatchdogTimeout(generation:) ->
      handle_watchdog_timeout(state, generation)
    types.ClassifyComplete(cycle_id, complexity, text) ->
      handle_classify_complete(state, cycle_id, complexity, text)
    types.SafetyGateComplete(task_id, result, resp, calls) -> {
      agentlair_emitter.emit_gate_decision(
        state.config.agentlair_config,
        state.identity.agent_uuid,
        result,
        "tool",
        state.cycle_id,
      )
      cognitive_safety.handle_safety_gate_complete(
        state,
        task_id,
        result,
        resp,
        calls,
        cognitive_agents.dispatch_tool_calls,
      )
    }
    types.InputSafetyGateComplete(cycle_id, result, model, text) -> {
      agentlair_emitter.emit_gate_decision(
        state.config.agentlair_config,
        state.identity.agent_uuid,
        result,
        "input",
        Some(cycle_id),
      )
      cognitive_safety.handle_input_safety_gate_complete(
        state,
        cycle_id,
        result,
        model,
        text,
      )
    }
    types.PostExecutionGateComplete(cycle_id, result, pre_score) -> {
      agentlair_emitter.emit_gate_decision(
        state.config.agentlair_config,
        state.identity.agent_uuid,
        result,
        "post_exec",
        Some(cycle_id),
      )
      cognitive_safety.handle_post_execution_gate_complete(
        state,
        cycle_id,
        result,
        pre_score,
      )
    }
    types.SetSupervisor(supervisor:) ->
      CognitiveState(..state, supervisor: Some(supervisor))
    types.SchedulerInput(
      source_id:,
      job_name:,
      query:,
      kind:,
      for_:,
      title:,
      body:,
      tags:,
    ) ->
      handle_scheduler_input(
        state,
        source_id,
        job_name,
        query,
        kind,
        for_,
        title,
        body,
        tags,
      )
    types.OutputGateComplete(cycle_id, result, report_text, modification_count) -> {
      agentlair_emitter.emit_gate_decision(
        state.config.agentlair_config,
        state.identity.agent_uuid,
        result,
        "output",
        Some(cycle_id),
      )
      cognitive_safety.handle_output_gate_complete(
        state,
        cycle_id,
        result,
        report_text,
        modification_count,
      )
    }
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

/// Bind cycle_id ↔ source_id on the Frontdoor routing table when a
/// non-empty source_id is present. Callers with no Frontdoor wiring
/// pass "" and this is a no-op.
fn claim_cycle_if_present(
  state: CognitiveState,
  cycle_id: String,
  source_id: String,
) -> Nil {
  case state.config.frontdoor, source_id {
    Some(frontdoor), s if s != "" -> {
      process.send(frontdoor, frontdoor_types.ClaimCycle(cycle_id:, source_id:))
    }
    _, _ -> Nil
  }
}

fn maybe_drain_queue(state: CognitiveState) -> CognitiveState {
  case state.status, state.input_queue {
    Idle, [QueuedInput(source_id:, text:, enqueued_at_ms:), ..rest] -> {
      // Stale-input drop: if this user input has been queued for longer
      // than the configured threshold AND there are newer user inputs
      // behind it, skip it. Protects against cycles firing against
      // obsolete context (the "I'm here. Was my diagnostic report too
      // long?" pattern from long cycles where the operator's first
      // queued message is no longer relevant by the time we drain).
      let age_ms = monotonic_now_ms() - enqueued_at_ms
      let has_newer_user_input =
        list.any(rest, fn(q) {
          case q {
            QueuedInput(..) -> True
            _ -> False
          }
        })
      case age_ms > stale_input_max_age_ms && has_newer_user_input {
        True -> {
          slog.warn(
            "cognitive",
            "maybe_drain_queue",
            "Dropping stale queued input (age="
              <> int.to_string(age_ms / 1000)
              <> "s, newer inputs in queue)",
            state.cycle_id,
          )
          // Emit a sensory event so the agent can acknowledge the drop
          // on its next cycle if relevant to the current exchange.
          let event =
            types.SensoryEvent(
              name: "stale_input_dropped",
              title: "An earlier message was skipped",
              body: "A user input from "
                <> int.to_string(age_ms / 1000)
                <> " seconds ago was dropped because newer messages arrived "
                <> "while you were busy. Mention this if it might be relevant.",
              fired_at: "",
            )
          let state_dropped =
            CognitiveState(..state, input_queue: rest, pending_sensory_events: [
              event,
              ..state.pending_sensory_events
            ])
          maybe_drain_queue(state_dropped)
        }
        False -> {
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
            source_id,
            text,
          )
        }
      }
    }
    Idle,
      [
        QueuedSchedulerInput(
          source_id:,
          job_name:,
          query:,
          kind:,
          for_:,
          title:,
          body:,
          tags:,
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
        source_id,
        job_name,
        query,
        kind,
        for_,
        title,
        body,
        tags,
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

// ---------------------------------------------------------------------------
// Watchdog — detects stuck non-Idle states
// ---------------------------------------------------------------------------

/// Start a watchdog timer. If the loop is still non-Idle when it fires,
/// and the generation matches, force recovery to Idle.
fn start_watchdog(state: CognitiveState) -> CognitiveState {
  let gen = state.watchdog_generation + 1
  let timeout_ms = state.config.gate_timeout_ms * 3
  process.send_after(
    state.self,
    timeout_ms,
    types.WatchdogTimeout(generation: gen),
  )
  CognitiveState(..state, watchdog_generation: gen)
}

fn handle_watchdog_timeout(
  state: CognitiveState,
  generation: Int,
) -> CognitiveState {
  // Stale timeout from a previous cycle — ignore
  case generation != state.watchdog_generation {
    True -> state
    False ->
      case state.status {
        // Already Idle — nothing to do
        Idle -> state
        _stuck_status -> {
          let status_name = "non-Idle"
          slog.warn(
            "cognitive",
            "watchdog_timeout",
            "Stuck in "
              <> status_name
              <> " for >"
              <> int.to_string(state.config.gate_timeout_ms * 3 / 1000)
              <> "s — forcing recovery to Idle",
            state.cycle_id,
          )
          // Force back to Idle so the queue can drain
          CognitiveState(..state, status: Idle)
        }
      }
  }
}

fn handle_user_input(
  state: CognitiveState,
  source_id: String,
  text: String,
) -> CognitiveState {
  slog.debug(
    "cognitive",
    "handle_user_input",
    "Input: " <> string.slice(text, 0, 80),
    state.cycle_id,
  )
  // Idle-gate signal. Pushed on every UserInput regardless of whether
  // we accept or queue — the scheduler only cares that the operator is
  // active. Skipped when no scheduler is wired (tests, boot order).
  case state.scheduler {
    option.Some(sched) ->
      process.send(
        sched,
        scheduler_types.UserInputObserved(at_ms: monotonic_now_ms()),
      )
    option.None -> Nil
  }
  // Guard: ignore input if not idle
  case state.status {
    Idle -> {
      let cycle_id = cycle_log.generate_uuid()
      // If a Frontdoor source is named, register the cycle so the
      // terminal reply lands back on the originating destination.
      claim_cycle_if_present(state, cycle_id, source_id)
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
          cycle_tokens_in: 0,
          cycle_tokens_out: 0,
          cycle_node_type: dag_types.CognitiveCycle,
          dprime_decisions: [],
          pending_output_reply: None,
          pending_output_usage: None,
          retrieved_case_ids: [],
          // Reset D' iteration counters at cycle start so
          // per-cycle MODIFY budgets don't accumulate across cycles
          tool_dprime_state: option.map(
            state.tool_dprime_state,
            dprime_meta.reset_iterations,
          ),
          input_dprime_state: option.map(
            state.input_dprime_state,
            dprime_meta.reset_iterations,
          ),
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
          types.ClassifyComplete(cycle_id:, complexity:, text:),
        )
      })

      start_watchdog(CognitiveState(..state, status: Classifying(cycle_id:)))
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
          output.send_reply(
            state,
            "[System: input queue full ("
              <> int.to_string(state.input_queue_cap)
              <> " pending), please wait.]",
            state.model,
            None,
            [],
          )
          state
        }
        False -> {
          let position = queue_len + 1
          let new_queue =
            list.append(state.input_queue, [
              QueuedInput(source_id:, text:, enqueued_at_ms: monotonic_now_ms()),
            ])
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
  source_id: String,
  job_name: String,
  query: String,
  kind: scheduler_types.JobKind,
  for_: scheduler_types.ForTarget,
  title: String,
  body: String,
  tags: List(String),
) -> CognitiveState {
  // Guard: queue if not idle
  case state.status {
    Idle -> {
      let cycle_id = cycle_log.generate_uuid()
      claim_cycle_if_present(state, cycle_id, source_id)
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
          cycle_tokens_in: 0,
          cycle_tokens_out: 0,
          cycle_node_type: dag_types.SchedulerCycle,
          dprime_decisions: [],
          pending_output_reply: None,
          pending_output_usage: None,
          retrieved_case_ids: [],
          tool_dprime_state: option.map(
            state.tool_dprime_state,
            dprime_meta.reset_iterations,
          ),
          input_dprime_state: option.map(
            state.input_dprime_state,
            dprime_meta.reset_iterations,
          ),
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

      // Inbound emails are tracked by the poller's seen_ids set (seeded from
      // comms JSONL on startup). No mark_processed needed — the JSONL entry
      // written by the poller is the durable record.

      // Skip classification — always use task_model, go straight to LLM
      cognitive_llm.proceed_with_model(
        state,
        state.task_model,
        text_with_context,
        cycle_id,
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
          output.send_reply(
            state,
            "[System: input queue full, scheduler job '"
              <> job_name
              <> "' rejected]",
            state.model,
            None,
            [],
          )
          state
        }
        False -> {
          let position = queue_len + 1
          let new_queue =
            list.append(state.input_queue, [
              types.QueuedSchedulerInput(
                source_id:,
                job_name:,
                query:,
                kind:,
                for_:,
                title:,
                body:,
                tags:,
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
      case state.input_dprime_state {
        None ->
          cognitive_llm.proceed_with_model(
            state,
            model,
            text,
            cycle_id,
            dag_types.CognitiveCycle,
          )
        Some(dprime_st) ->
          cognitive_safety.spawn_input_safety_gate(
            state,
            cycle_id,
            model,
            text,
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
                    output_gate_count: ogc,
                    empty_retried: True,
                    node_type:,
                  ),
                ),
              )
            }
            False -> {
              // Detect length-capped stops on the cognitive loop's own
              // response. When the LLM hit max_tokens AND produced no tool
              // calls, the reply may be mid-sentence or have had a tool_use
              // block sliced off before it could be emitted — the operator-
              // visible "agent promises and doesn't deliver" pattern.
              case resp.stop_reason == Some(llm_types.MaxTokens) {
                True ->
                  slog.warn(
                    "cognitive",
                    "handle_think_complete",
                    "Response was length-capped at max_tokens with no tool calls — output may be truncated or a tool_use block may have been sliced off",
                    state.cycle_id,
                  )
                False -> Nil
              }
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
              // Output gate strategy:
              // - Autonomous (scheduler) cycles: full LLM scorer + normative
              //   calculus — nobody's watching, quality matters before delivery
              // - Interactive cycles: deterministic rules only — the operator
              //   is the quality gate, don't destroy good output with false positives
              let is_autonomous =
                state.cycle_node_type == dag_types.SchedulerCycle
              // Stash LLM usage for DAG finalisation after gate completes
              // Accumulate cycle token counters
              let state =
                CognitiveState(
                  ..state,
                  pending_output_usage: Some(resp.usage),
                  cycle_tokens_in: state.cycle_tokens_in
                    + resp.usage.input_tokens,
                  cycle_tokens_out: state.cycle_tokens_out
                    + resp.usage.output_tokens,
                )
              case state.output_dprime_state, is_autonomous {
                Some(output_state), True -> {
                  // Autonomous delivery — full output gate evaluation
                  cognitive_safety.spawn_output_gate(
                    state,
                    output_state,
                    reply_text,
                    messages,
                    task_id,
                    ogc,
                  )
                }
                Some(_), False -> {
                  // Interactive session — deterministic rules only, skip LLM scorer
                  cognitive_safety.check_deterministic_only(
                    state,
                    reply_text,
                    messages,
                    task_id,
                    resp.usage,
                  )
                }
                None, _ -> {
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
                          instance_name: state.identity.agent_name,
                          instance_id: string.slice(
                            state.identity.agent_uuid,
                            0,
                            8,
                          ),
                        )),
                      )
                    None -> Nil
                  }
                  output.send_reply(
                    state,
                    reply_text,
                    reply_model,
                    Some(resp.usage),
                    list.map(state.cycle_tool_calls, fn(t) { t.name }),
                  )
                  // Spawn Archivist (fire-and-forget)
                  cognitive_memory.maybe_spawn_archivist(
                    state,
                    reply_text,
                    reply_model,
                    Some(resp.usage),
                  )
                  // Post-cycle meta observation (Layer 3b)
                  let state =
                    cognitive_state.apply_meta_observation(
                      state,
                      resp.usage.input_tokens + resp.usage.output_tokens,
                    )
                  // Fire-and-forget save
                  let new_state =
                    CognitiveState(
                      ..state,
                      messages:,
                      status: Idle,
                      pending: dict.delete(state.pending, task_id),
                      cycles_today: state.cycles_today + 1,
                    )
                  new_state
                }
              }
            }
          }
        }
        True -> {
          let calls = response.tool_calls(resp)
          // Detect length-capped stops on a tool-calling response: the
          // tool_use arguments JSON may have been sliced off mid-construction.
          // The model SDK would normally reject malformed tool_use, but when
          // it doesn't, the tool call will fail in odd ways. Log for
          // operator visibility.
          case resp.stop_reason == Some(llm_types.MaxTokens) {
            True ->
              slog.warn(
                "cognitive",
                "handle_think_complete",
                "Response was length-capped at max_tokens during tool_use construction — tool arguments may be malformed",
                state.cycle_id,
              )
            False -> Nil
          }
          // Accumulate cycle token counters from tool-calling response
          let state =
            CognitiveState(
              ..state,
              cycle_tokens_in: state.cycle_tokens_in + resp.usage.input_tokens,
              cycle_tokens_out: state.cycle_tokens_out
                + resp.usage.output_tokens,
            )
          // D' gate intercept: if enabled, evaluate before dispatch.
          // Skip D' when ALL tool calls are exempt (memory, planner,
          // builtin tools — internal operations that can't exfiltrate
          // data or modify the filesystem).
          let all_exempt =
            list.all(calls, fn(c) { memory.is_dprime_exempt(c.name) })
          case state.tool_dprime_state {
            _ if all_exempt ->
              cognitive_agents.dispatch_tool_calls(state, task_id, resp, calls)
            None ->
              cognitive_agents.dispatch_tool_calls(state, task_id, resp, calls)
            Some(dprime_st) ->
              cognitive_safety.spawn_safety_gate(
                state,
                task_id,
                resp,
                calls,
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

          // Log the forecaster trigger to cycle_log so it's traceable
          cycle_log.log_human_input(
            cycle_id,
            state.cycle_id,
            "[Forecaster replan] Task "
              <> task_id
              <> " '"
              <> task_title
              <> "' D'="
              <> float.to_string(plan_dprime)
              <> ": "
              <> explanation,
            state.redact_secrets,
          )

          // Index the root cycle in DAG so inspect_cycle can find it
          case state.memory.librarian {
            option.Some(lib) -> {
              process.send(
                lib,
                librarian.IndexNode(node: dag_types.CycleNode(
                  cycle_id:,
                  parent_id: None,
                  node_type: dag_types.CognitiveCycle,
                  timestamp: get_datetime(),
                  outcome: dag_types.NodePending,
                  model: "",
                  complexity: "forecaster_replan",
                  tool_calls: [],
                  dprime_gates: [],
                  tokens_in: 0,
                  tokens_out: 0,
                  duration_ms: 0,
                  agent_output: None,
                  instance_name: state.identity.agent_name,
                  instance_id: string.slice(state.identity.agent_uuid, 0, 8),
                )),
              )
              // Index the planner agent sub-cycle
              process.send(
                lib,
                librarian.IndexNode(node: dag_types.CycleNode(
                  cycle_id: agent_task_id,
                  parent_id: option.Some(cycle_id),
                  node_type: dag_types.AgentCycle,
                  timestamp: get_datetime(),
                  outcome: dag_types.NodePending,
                  model: "",
                  complexity: "replan",
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
            }
            option.None -> Nil
          }

          let agent_task =
            types.AgentTask(
              task_id: agent_task_id,
              tool_use_id: "forecaster_replan_" <> task_id,
              instruction:,
              context: forecast_context,
              parent_cycle_id: cycle_id,
              reply_to: state.self,
              depth: 1,
              max_turns_override: None,
              // Forecaster-triggered replans don't get a deputy — they're
              // internal planner work, not externally-facing delegations.
              deputy_subject: None,
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

          CognitiveState(
            ..state,
            cycle_id: Some(cycle_id),
            cycle_started_ms: monotonic_now_ms(),
            cycle_node_type: dag_types.CognitiveCycle,
            status: types.WaitingForAgents(
              pending_ids: [agent_task_id],
              accumulated_results: [],
            ),
            pending: dict.insert(
              state.pending,
              agent_task_id,
              types.PendingAgent(
                task_id: agent_task_id,
                tool_use_id: "forecaster_replan_" <> task_id,
                agent: "planner",
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
