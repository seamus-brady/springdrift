// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/cognitive/output
import agent/cognitive_state.{type CognitiveState, CognitiveState}
import agent/registry
import agent/types.{
  type CognitiveReply, PendingThink, SensoryEvent, Thinking,
}
import agent/worker
import context
import cycle_log
import dag/types as dag_types
import dprime/types as dprime_types
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import llm/request
import llm/types as llm_types
import meta/types as meta_types
import narrative/curator
import narrative/librarian
import slog

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

/// Build a user message, spawn a think worker with the given model,
/// and transition to Thinking status.
pub fn proceed_with_model(
  state: CognitiveState,
  model: String,
  text: String,
  cycle_id: String,
  reply_to: Subject(CognitiveReply),
  node_type: dag_types.CycleNodeType,
) -> CognitiveState {
  slog.info(
    "cognitive",
    "proceed_with_model",
    "Using model: " <> model,
    Some(cycle_id),
  )
  // Refresh system prompt from Curator if available, passing cycle context
  let state = case state.memory.curator {
    Some(cur) -> {
      let input_source = case node_type {
        dag_types.SchedulerCycle -> "scheduler"
        _ -> "user"
      }
      let cycle_context =
        curator.CycleContext(
          input_source:,
          queue_depth: list.length(state.input_queue),
          session_since: state.identity.session_since,
          agents_active: registry.count_running(state.registry),
          message_count: list.length(state.messages),
          sensory_events: state.pending_sensory_events,
          active_delegations: dict.values(state.active_delegations),
          sandbox_enabled: state.config.sandbox_enabled,
          sandbox_slots: [],
          last_user_input: state.last_user_input,
          cycle_id:,
          cycle_tokens_in: state.cycle_tokens_in,
          cycle_tokens_out: state.cycle_tokens_out,
        )
      let prompt =
        curator.build_system_prompt(cur, state.system, Some(cycle_context))
      // Clear consumed sensory events
      CognitiveState(..state, system: prompt, pending_sensory_events: [])
    }
    None -> state
  }

  // Consume pending Layer 3b meta intervention if any
  let state = consume_meta_intervention(state, cycle_id)

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
  // Index NodePending in DAG
  case state.memory.librarian {
    Some(lib) ->
      process.send(
        lib,
        librarian.IndexNode(node: dag_types.CycleNode(
          cycle_id: cycle_id,
          parent_id: None,
          node_type: node_type,
          timestamp: get_datetime(),
          outcome: dag_types.NodePending,
          model:,
          complexity: "",
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
    None -> Nil
  }

  worker.spawn_think(
    task_id,
    req,
    state.provider,
    state.self,
    state.config.retry_config,
  )

  let wd_gen = state.watchdog_generation + 1
  let wd_timeout_ms = state.config.gate_timeout_ms * 3
  process.send_after(
    state.self,
    wd_timeout_ms,
    types.WatchdogTimeout(generation: wd_gen),
  )
  CognitiveState(
    ..state,
    model:,
    messages:,
    cycle_id: Some(cycle_id),
    watchdog_generation: wd_gen,
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
        node_type:,
      ),
    ),
  )
}

/// Handle a think worker error (retryable or not).
pub fn handle_think_error(
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
    Ok(PendingThink(model: failed_model, reply_to: rt, node_type:, ..)) -> {
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
                model: state.task_model,
                fallback_from: Some(failed_model),
                reply_to: rt,
                output_gate_count: 0,
                empty_retried: False,
                node_type:,
              ),
            ),
          )
        }
        False -> {
          let error_text = "[Error: " <> error <> "]"
          output.send_reply(state, rt, error_text, state.model, None, [])
          // Add synthetic assistant message so message history stays
          // well-formed (alternating user/assistant). Without this, the
          // next user input would create two consecutive user messages
          // and the API would reject the request.
          let error_msg =
            llm_types.Message(role: llm_types.Assistant, content: [
              llm_types.TextContent(text: error_text),
            ])
          let messages = list.append(state.messages, [error_msg])
          CognitiveState(
            ..state,
            messages:,
            status: types.Idle,
            pending: dict.delete(state.pending, task_id),
          )
        }
      }
    }
    Ok(_) -> state
  }
}

/// Handle a think worker process crash.
pub fn handle_think_down(
  state: CognitiveState,
  task_id: String,
  reason: String,
) -> CognitiveState {
  // Only act if we still have this pending (may already be resolved)
  case dict.get(state.pending, task_id) {
    Error(_) -> state
    Ok(PendingThink(reply_to: rt, ..)) -> {
      let error_text = "[Error: think worker crashed: " <> reason <> "]"
      output.send_reply(state, rt, error_text, state.model, None, [])
      let error_msg =
        llm_types.Message(role: llm_types.Assistant, content: [
          llm_types.TextContent(text: error_text),
        ])
      let messages = list.append(state.messages, [error_msg])
      CognitiveState(
        ..state,
        messages:,
        status: types.Idle,
        pending: dict.delete(state.pending, task_id),
      )
    }
    Ok(_) -> state
  }
}

/// Build an LLM request using the current model.
pub fn build_request(
  state: CognitiveState,
  messages: List(llm_types.Message),
) -> llm_types.LlmRequest {
  build_request_with_model(state, state.model, messages)
}

/// Build an LLM request with a specific model.
pub fn build_request_with_model(
  state: CognitiveState,
  model: String,
  messages: List(llm_types.Message),
) -> llm_types.LlmRequest {
  // Message count trim (configurable)
  let trimmed = case state.max_context_messages {
    None -> context.ensure_alternation(messages)
    Some(max) -> context.trim(messages, max)
  }
  // Token budget safety net — hard cap to prevent API 400 errors.
  // System prompt + tools + response budget need headroom, so cap messages
  // at 150k tokens (leaves ~50k for system/tools/output on a 200k model).
  let trimmed = context.trim_to_token_budget(trimmed, 150_000)
  let base =
    request.new(model, state.max_tokens)
    |> request.with_system(state.system)
    |> request.with_messages(trimmed)
  let base = case model == state.reasoning_model, state.thinking_budget_tokens {
    True, Some(budget) if budget < state.max_tokens ->
      request.with_thinking_budget(base, budget)
    _, _ -> base
  }
  case state.tools {
    [] -> base
    tools -> request.with_tools(base, tools)
  }
}

// ---------------------------------------------------------------------------
// Layer 3b meta intervention
// ---------------------------------------------------------------------------

/// Consume any pending Layer 3b meta intervention and apply it.
fn consume_meta_intervention(
  state: CognitiveState,
  cycle_id: String,
) -> CognitiveState {
  case state.meta_state {
    None -> state
    Some(ms) -> {
      let #(intervention, new_ms) = meta_types.consume_intervention(ms)
      let state = CognitiveState(..state, meta_state: Some(new_ms))
      case intervention {
        meta_types.NoIntervention -> state

        meta_types.EscalateToUser(title:, body:) -> {
          slog.warn(
            "cognitive",
            "consume_meta_intervention",
            "Meta escalation: " <> title,
            Some(cycle_id),
          )
          let event =
            SensoryEvent(name: "meta_escalation", title:, body:, fired_at: "")
          CognitiveState(
            ..state,
            pending_sensory_events: list.append(state.pending_sensory_events, [
              event,
            ]),
          )
        }

        meta_types.InjectCaution(message:) -> {
          slog.info(
            "cognitive",
            "consume_meta_intervention",
            "Meta caution injected",
            Some(cycle_id),
          )
          CognitiveState(
            ..state,
            system: state.system <> "\n\n[META CAUTION: " <> message <> "]",
          )
        }

        meta_types.TightenAllGates(factor:) -> {
          slog.warn(
            "cognitive",
            "consume_meta_intervention",
            "Meta tightening all gates by factor " <> float.to_string(factor),
            Some(cycle_id),
          )
          let tighten = fn(ds: dprime_types.DprimeState) -> dprime_types.DprimeState {
            let cfg = ds.config
            // Apply floor — never tighten below min thresholds
            let new_modify =
              float_max(
                ds.current_modify_threshold *. factor,
                cfg.min_modify_threshold,
              )
            let new_reject =
              float_max(
                ds.current_reject_threshold *. factor,
                cfg.min_reject_threshold,
              )
            dprime_types.DprimeState(
              ..ds,
              current_modify_threshold: new_modify,
              current_reject_threshold: new_reject,
              config: dprime_types.DprimeConfig(
                ..cfg,
                modify_threshold: float_max(
                  cfg.modify_threshold *. factor,
                  cfg.min_modify_threshold,
                ),
                reject_threshold: float_max(
                  cfg.reject_threshold *. factor,
                  cfg.min_reject_threshold,
                ),
              ),
            )
          }
          let input_ds = case state.input_dprime_state {
            Some(ds) -> Some(tighten(ds))
            None -> None
          }
          let tool_ds = case state.tool_dprime_state {
            Some(ds) -> Some(tighten(ds))
            None -> None
          }
          let output_ds = case state.output_dprime_state {
            Some(ds) -> Some(tighten(ds))
            None -> None
          }
          CognitiveState(
            ..state,
            input_dprime_state: input_ds,
            tool_dprime_state: tool_ds,
            output_dprime_state: output_ds,
          )
        }

        meta_types.ForceCooldown(delay_ms:) -> {
          slog.warn(
            "cognitive",
            "consume_meta_intervention",
            "Meta cooldown: sleeping " <> int.to_string(delay_ms) <> "ms",
            Some(cycle_id),
          )
          process.sleep(delay_ms)
          state
        }
      }
    }
  }
}

fn float_max(a: Float, b: Float) -> Float {
  case a >. b {
    True -> a
    False -> b
  }
}
