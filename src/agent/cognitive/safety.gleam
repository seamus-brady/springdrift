import agent/cognitive/llm as cognitive_llm
import agent/cognitive_state.{type CognitiveState, CognitiveState}
import agent/types.{
  type CognitiveReply, CognitiveReply, Idle, PendingThink, SafetyGateNotice,
  Thinking,
}
import agent/worker
import cycle_log
import dag/types as dag_types
import dprime/audit as dprime_audit
import dprime/gate
import dprime/meta
import dprime/output_gate
import dprime/types as dprime_types
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import llm/types as llm_types
import slog

/// Add a synthetic assistant message to state so message history stays
/// well-formed (alternating user/assistant) when going to Idle after an error.
fn with_assistant_error(state: CognitiveState, text: String) -> CognitiveState {
  let msg =
    llm_types.Message(role: llm_types.Assistant, content: [
      llm_types.TextContent(text:),
    ])
  CognitiveState(..state, messages: list.append(state.messages, [msg]))
}

/// Spawn a D' safety evaluation for tool calls (pre-dispatch gate).
pub fn spawn_safety_gate(
  state: CognitiveState,
  task_id: String,
  resp: llm_types.LlmResponse,
  calls: List(llm_types.ToolCall),
  reply_to: Subject(CognitiveReply),
  dprime_st: dprime_types.DprimeState,
) -> CognitiveState {
  slog.info(
    "cognitive",
    "spawn_safety_gate",
    "Spawning D' safety evaluation",
    state.cycle_id,
  )
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
    status: types.EvaluatingSafety(task_id:, response: resp, calls:, reply_to:),
  )
}

/// Handle completion of the D' tool-call safety gate.
/// Takes a dispatch_fn callback to handle tool dispatch on Accept.
pub fn handle_safety_gate_complete(
  state: CognitiveState,
  task_id: String,
  result: dprime_types.GateResult,
  resp: llm_types.LlmResponse,
  calls: List(llm_types.ToolCall),
  reply_to: Subject(CognitiveReply),
  dispatch_fn: fn(
    CognitiveState,
    String,
    llm_types.LlmResponse,
    List(llm_types.ToolCall),
    Subject(CognitiveReply),
  ) ->
    CognitiveState,
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
  let record =
    dag_types.DprimeDecisionRecord(
      gate: "tool",
      decision: case result.decision {
        dprime_types.Accept -> "accept"
        dprime_types.Modify -> "modify"
        dprime_types.Reject -> "reject"
      },
      score: result.dprime_score,
      explanation: result.explanation,
    )
  let state =
    CognitiveState(..state, dprime_state: new_dprime_state, dprime_decisions: [
      record,
      ..state.dprime_decisions
    ])

  case result.decision {
    dprime_types.Accept -> {
      // Proceed normally — delegate to the dispatch function
      dispatch_fn(state, task_id, resp, calls, reply_to)
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
      let req = cognitive_llm.build_request(state, messages)
      case state.verbose {
        True -> cycle_log.log_llm_request(cycle_id, req)
        False -> Nil
      }
      worker.spawn_think(
        new_task_id,
        req,
        state.provider,
        state.self,
        state.retry_config,
      )

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
      let req = cognitive_llm.build_request(state, messages)
      case state.verbose {
        True -> cycle_log.log_llm_request(cycle_id, req)
        False -> Nil
      }
      worker.spawn_think(
        new_task_id,
        req,
        state.provider,
        state.self,
        state.retry_config,
      )

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

/// Spawn an input-level D' safety evaluation.
pub fn spawn_input_safety_gate(
  state: CognitiveState,
  cycle_id: String,
  model: String,
  text: String,
  reply_to: Subject(CognitiveReply),
  dprime_st: dprime_types.DprimeState,
) -> CognitiveState {
  slog.info(
    "cognitive",
    "spawn_input_safety_gate",
    "Spawning D' input safety evaluation",
    Some(cycle_id),
  )
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
    status: types.EvaluatingInputSafety(cycle_id:, model:, text:, reply_to:),
  )
}

/// Handle completion of the input-level D' safety gate.
pub fn handle_input_safety_gate_complete(
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
  let record =
    dag_types.DprimeDecisionRecord(
      gate: "input",
      decision: case result.decision {
        dprime_types.Accept -> "accept"
        dprime_types.Modify -> "modify"
        dprime_types.Reject -> "reject"
      },
      score: result.dprime_score,
      explanation: result.explanation,
    )
  let state =
    CognitiveState(..state, dprime_state: new_dprime_state, dprime_decisions: [
      record,
      ..state.dprime_decisions
    ])

  case result.decision {
    dprime_types.Accept -> {
      // Proceed normally with the LLM call
      cognitive_llm.proceed_with_model(state, model, text, cycle_id, reply_to)
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
      cognitive_llm.proceed_with_model(
        CognitiveState(..state, messages:),
        model,
        text,
        cycle_id,
        reply_to,
      )
    }

    dprime_types.Reject -> {
      // Reply directly with refusal — no LLM call
      let reject_text =
        "[Safety system: query rejected (D' score: "
        <> float.to_string(result.dprime_score)
        <> "). "
        <> result.explanation
        <> "]"
      process.send(
        reply_to,
        CognitiveReply(response: reject_text, model:, usage: None),
      )
      let state = with_assistant_error(state, reject_text)
      CognitiveState(..state, status: Idle)
    }
  }
}

/// Handle completion of the post-execution D' re-check.
pub fn handle_post_execution_gate_complete(
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
  let record =
    dag_types.DprimeDecisionRecord(
      gate: "post_execution",
      decision: case result.decision {
        dprime_types.Accept -> "accept"
        dprime_types.Modify -> "modify"
        dprime_types.Reject -> "reject"
      },
      score: result.dprime_score,
      explanation: result.explanation,
    )
  let state =
    CognitiveState(..state, dprime_state: new_dprime_state, dprime_decisions: [
      record,
      ..state.dprime_decisions
    ])

  // Check if D' improved (decreased) or worsened
  case result.dprime_score <=. pre_score {
    True -> {
      slog.debug(
        "cognitive",
        "handle_post_execution_gate_complete",
        "D' improved, continuing normally",
        Some(cycle_id),
      )
      state
    }
    False -> {
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

/// Spawn an output gate evaluation.
pub fn spawn_output_gate(
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

/// Handle completion of the output quality gate.
pub fn handle_output_gate_complete(
  state: CognitiveState,
  _cycle_id: String,
  result: dprime_types.GateResult,
  report_text: String,
  modification_count: Int,
  reply_to: Subject(CognitiveReply),
) -> CognitiveState {
  let record =
    dag_types.DprimeDecisionRecord(
      gate: "output",
      decision: case result.decision {
        dprime_types.Accept -> "accept"
        dprime_types.Modify -> "modify"
        dprime_types.Reject -> "reject"
      },
      score: result.dprime_score,
      explanation: result.explanation,
    )
  let state =
    CognitiveState(..state, dprime_decisions: [record, ..state.dprime_decisions])
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
      let state = with_assistant_error(state, report_text)
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
          let full_text = report_text <> warning
          process.send(
            reply_to,
            CognitiveReply(response: full_text, model: state.model, usage: None),
          )
          let state = with_assistant_error(state, full_text)
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
          let req = cognitive_llm.build_request(new_state, messages)
          worker.spawn_think(
            task_id,
            req,
            new_state.provider,
            new_state.self,
            new_state.retry_config,
          )
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
      let reject_text =
        "[Report rejected by quality gate: " <> explanation <> "]"
      process.send(
        reply_to,
        CognitiveReply(response: reject_text, model: state.model, usage: None),
      )
      let state = with_assistant_error(state, reject_text)
      CognitiveState(..state, status: Idle)
    }
  }
}
