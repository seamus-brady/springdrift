// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import affect/monitor as affect_monitor
import affect/types as affect_types
import agent/cognitive_state.{type CognitiveState}
import dag/types as dag_types
import gleam/float
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/types as llm_types
import narrative/archivist
import narrative/curator as narrative_curator
import paths

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

  // Compute affect snapshot and send to Curator
  case affect_monitor.after_cycle(state, paths.affect_dir()) {
    option.Some(snapshot) ->
      case state.memory.curator {
        option.Some(cur) ->
          narrative_curator.update_affect(
            cur,
            affect_types.format_reading(snapshot),
          )
        option.None -> Nil
      }
    option.None -> Nil
  }
}
