import agent/cognitive_state.{type CognitiveState, CognitiveState}
import agent/types.{type CognitiveReply, CognitiveReply, PendingThink, Thinking}
import agent/worker
import context
import cycle_log
import dag/types as dag_types
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import llm/request
import llm/types as llm_types
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
) -> CognitiveState {
  slog.info(
    "cognitive",
    "proceed_with_model",
    "Using model: " <> model,
    Some(cycle_id),
  )
  // Refresh system prompt from Curator if available
  let state = case state.curator {
    Some(cur) -> {
      let prompt = curator.build_system_prompt(cur, state.system)
      CognitiveState(..state, system: prompt)
    }
    None -> state
  }

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
  case state.librarian {
    Some(lib) ->
      process.send(
        lib,
        librarian.IndexNode(node: dag_types.CycleNode(
          cycle_id: cycle_id,
          parent_id: None,
          node_type: dag_types.CognitiveCycle,
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
        )),
      )
    None -> Nil
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
          let error_text = "[Error: " <> error <> "]"
          process.send(
            rt,
            CognitiveReply(
              response: error_text,
              model: state.model,
              usage: None,
            ),
          )
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
      process.send(
        rt,
        CognitiveReply(response: error_text, model: state.model, usage: None),
      )
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
  let trimmed = case state.max_context_messages {
    None -> context.ensure_alternation(messages)
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
