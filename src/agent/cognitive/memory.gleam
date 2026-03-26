import agent/cognitive_state.{type CognitiveState, CognitiveState}
import agent/types.{SaveResult, SaveWarning}
import dag/types as dag_types
import gleam/erlang/process
import gleam/float
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/types as llm_types
import narrative/archivist
import storage

/// Handle the result of an async save operation.
pub fn handle_save_result(
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

/// Queue or immediately spawn an async save of messages.
pub fn request_save(
  state: CognitiveState,
  messages: List(llm_types.Message),
) -> CognitiveState {
  // Strip transient gate injection messages before persisting.
  // MODIFY/REJECT injections are control signals — preserving them in session
  // history creates a feedback loop where the agent learns to self-censor.
  let clean_messages = filter_gate_injections(messages)
  case state.save_in_progress {
    True -> {
      // Queue for when current save completes
      CognitiveState(..state, save_pending: Some(clean_messages))
    }
    False -> {
      do_spawn_save(state, clean_messages)
      CognitiveState(..state, save_in_progress: True)
    }
  }
}

/// Remove output gate injection messages from the message list.
/// These are transient control signals (MODIFY corrections, REJECT notices)
/// that should not persist into session history.
fn filter_gate_injections(
  messages: List(llm_types.Message),
) -> List(llm_types.Message) {
  list.filter(messages, fn(msg) { !is_gate_injection(msg) })
}

fn is_gate_injection(msg: llm_types.Message) -> Bool {
  case msg.content {
    [llm_types.TextContent(text: t), ..] ->
      // MODIFY correction (User message)
      string.starts_with(t, "[SYSTEM: Your response was NOT delivered")
      // REJECT/MODIFY notice (Assistant message via with_assistant_error)
      || string.starts_with(t, "[D' output gate: REJECTED")
      || string.starts_with(t, "[D' output gate: MODIFIED")
      // Input gate rejection (Assistant message)
      || string.starts_with(t, "[D' input gate: REJECTED")
    _ -> False
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

/// Spawn the Archivist after each reply. Called after sending CognitiveReply.
pub fn maybe_spawn_archivist(
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
      tool_calls: list.flat_map(state.agent_completions, fn(c) { c.tools_used })
        |> list.length,
      dprime_decisions: list.map(
        list.reverse(state.dprime_decisions),
        fn(r: dag_types.DprimeDecisionRecord) {
          "["
          <> r.gate
          <> "] "
          <> string.uppercase(r.decision)
          <> " (d'="
          <> float.to_string(r.score)
          <> ") — "
          <> r.explanation
        },
      ),
      thread_index_json: "",
      retrieved_case_ids: state.retrieved_case_ids,
    )
  archivist.spawn(
    ctx,
    state.provider,
    state.archivist_model,
    state.archivist_max_tokens,
    state.memory.narrative_dir,
    state.memory.cbr_dir,
    state.verbose,
    state.memory.librarian,
    state.memory.curator,
    state.config.threading_config,
    state.redact_secrets,
  )
}
