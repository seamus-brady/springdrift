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
import dprime/deterministic.{Blocked, Escalated, Pass}
import dprime/gate
import dprime/meta
import dprime/output_gate
import dprime/types as dprime_types
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
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

/// Technical rejection notice for the agent — goes to notification channel,
/// DAG audit, and message history as a system note. Contains full feature
/// breakdown for pattern learning.
fn build_rejection_notice(
  gate_name: String,
  result: dprime_types.GateResult,
  content_type: String,
) -> String {
  let feature_triggers = case result.forecasts {
    [] -> ""
    forecasts -> {
      let fired =
        forecasts
        |> list.filter(fn(f) { f.magnitude > 0 })
        |> list.sort(fn(a, b) { int.compare(b.magnitude, a.magnitude) })
        |> list.map(fn(f) {
          f.feature_name <> "=" <> int.to_string(f.magnitude) <> "/3"
        })
        |> string.join(", ")
      case fired {
        "" -> ""
        triggers -> " Feature triggers: [" <> triggers <> "]."
      }
    }
  }
  "[D' "
  <> gate_name
  <> " gate: "
  <> case result.decision {
    dprime_types.Reject -> "REJECTED"
    dprime_types.Modify -> "MODIFIED"
    dprime_types.Accept -> "ACCEPTED"
  }
  <> " (score: "
  <> float.to_string(result.dprime_score)
  <> "). "
  <> result.explanation
  <> feature_triggers
  <> " Content type: "
  <> content_type
  <> ". Original text redacted from logs.]"
}

/// Human-friendly response for the user. Maps the highest-scoring feature
/// to a contextual, actionable message. No jargon, no scores, no thresholds.
fn build_user_response(result: dprime_types.GateResult) -> String {
  // Find the highest-magnitude fired feature
  let top_feature = case result.forecasts {
    [] -> ""
    forecasts ->
      forecasts
      |> list.filter(fn(f) { f.magnitude > 0 })
      |> list.sort(fn(a, b) { int.compare(b.magnitude, a.magnitude) })
      |> list.first
      |> option.from_result
      |> option.map(fn(f) { f.feature_name })
      |> option.unwrap("")
  }
  case top_feature {
    "harmful_request" -> "I can't help with that — it involves potential harm."
    "prompt_injection" ->
      "That looks like it's trying to override my instructions. I can't process it."
    "scope_violation" -> "That's outside what I'm set up to help with."
    "data_exfiltration" ->
      "I can't execute that — it could expose sensitive data."
    "unauthorized_write" ->
      "I can't execute that — it would modify files outside the permitted scope."
    "sandbox_escape" ->
      "I can't run that code — it could break container isolation."
    "unsourced_claim" ->
      "I need to revise my response — it contained unsupported claims."
    "accuracy" ->
      "I need to revise my response — it may contain inaccurate information."
    "privacy_leak" | "privacy" ->
      "I've held back my response — it could expose private information."
    "harmful_content" ->
      "I've held back my response — it may contain harmful material."
    "certainty_overstatement" ->
      "I need to revise my response — it overstated certainty on uncertain data."
    "user_safety" -> "I can't help with that — it could put someone at risk."
    "legal_compliance" ->
      "I can't help with that — it may involve legal or compliance issues."
    "resource_abuse" ->
      "That request would consume excessive resources. Please refine it."
    "network_access" ->
      "I can't run that code — it attempts to access the network."
    "resource_consumption" ->
      "I can't run that code — it would use excessive resources."
    "credential_exposure" ->
      "I can't do that search — it could expose credentials."
    "excessive_crawling" ->
      "I'm rate-limiting my web requests to avoid overloading the source."
    "sensitive_domain" ->
      "I can't access that source — it may contain sensitive content."
    _ -> "I've flagged a concern with that request and can't proceed as asked."
  }
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

  // Build context from recent messages (character-budget walker, all content types)
  let ctx = build_context_string(state.messages, 2000)

  let det_config = state.config.deterministic_config
  let redact_secrets = state.redact_secrets

  // TODO(BF-12): Gate processes have no timeout. If the LLM call inside
  // gate.evaluate hangs, the cognitive loop waits forever. A timeout
  // mechanism (e.g. process.send_after with a new message type) should be
  // added to cancel stalled gate evaluations.
  process.spawn_unlinked(fn() {
    // Deterministic pre-filter for tool calls
    let det_result = case det_config {
      Some(dc) -> {
        let combined =
          list.map(calls, fn(c) { c.name <> " " <> c.input_json })
          |> string.join("; ")
        deterministic.check_tool(combined, "", dc)
      }
      None -> Pass
    }
    case det_result {
      Blocked(rule_id, _reason) -> {
        slog.warn(
          "cognitive",
          "spawn_safety_gate",
          "Deterministic tool block: rule " <> rule_id,
          Some(cycle_id),
        )
        cycle_log.log_dprime_layer(
          cycle_id,
          "deterministic_tool",
          "reject",
          1.0,
          "Deterministic block: banned tool pattern detected",
        )
        let reject_result =
          dprime_types.GateResult(
            decision: dprime_types.Reject,
            dprime_score: 1.0,
            forecasts: [],
            explanation: "Deterministic block: banned tool pattern detected",
            layer: dprime_types.Reactive,
            canary_result: None,
          )
        process.send(
          self,
          types.SafetyGateComplete(
            task_id:,
            result: reject_result,
            response: resp,
            calls:,
            reply_to:,
          ),
        )
      }
      Escalated(_rule_id, det_context) -> {
        slog.info(
          "cognitive",
          "spawn_safety_gate",
          "Deterministic tool escalation, adding context",
          Some(cycle_id),
        )
        let enriched_ctx = det_context <> "\n" <> ctx
        let result =
          gate.evaluate(
            instruction,
            enriched_ctx,
            dprime_st,
            provider,
            model,
            cycle_id,
            verbose,
            redact_secrets,
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
      }
      Pass -> {
        let result =
          gate.evaluate(
            instruction,
            ctx,
            dprime_st,
            provider,
            model,
            cycle_id,
            verbose,
            redact_secrets,
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
      }
    }
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
      case state.tool_dprime_state {
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
  let new_dprime_state = case state.tool_dprime_state {
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
  // Increment session-level D' counters
  let state = case result.decision {
    dprime_types.Modify ->
      CognitiveState(
        ..state,
        session_dprime_modifications: state.session_dprime_modifications + 1,
      )
    dprime_types.Reject ->
      CognitiveState(
        ..state,
        session_dprime_rejections: state.session_dprime_rejections + 1,
      )
    dprime_types.Accept -> state
  }
  let state =
    CognitiveState(
      ..state,
      tool_dprime_state: new_dprime_state,
      dprime_decisions: [record, ..state.dprime_decisions],
    )

  // Extract node_type from existing PendingThink
  let pending_node_type = case dict.get(state.pending, task_id) {
    Ok(PendingThink(node_type:, ..)) -> node_type
    _ -> dag_types.CognitiveCycle
  }

  case result.decision {
    dprime_types.Accept -> {
      // Proceed normally — delegate to the dispatch function
      dispatch_fn(state, task_id, resp, calls, reply_to)
    }

    dprime_types.Modify -> {
      // Check meta-management before allowing re-evaluation
      let intervention = case new_dprime_state {
        Some(ds) -> meta.should_intervene(ds)
        None -> dprime_types.NoIntervention
      }
      case intervention {
        dprime_types.AbortMaxIterations -> {
          // Too many MODIFY iterations — escalate to reject
          slog.warn(
            "cognitive",
            "handle_safety_gate_complete",
            "D' MODIFY aborted after max iterations — escalating to reject",
            Some(cycle_id),
          )
          let error_results =
            list.map(calls, fn(call) {
              llm_types.ToolFailure(
                tool_use_id: call.id,
                error: "[D' REJECT: exceeded maximum modification attempts. "
                  <> result.explanation
                  <> "]",
              )
            })
          let assistant_msg =
            llm_types.Message(role: llm_types.Assistant, content: resp.content)
          let result_blocks =
            list.map(error_results, fn(r) {
              case r {
                llm_types.ToolSuccess(tool_use_id:, content:) ->
                  llm_types.ToolResultContent(
                    tool_use_id:,
                    content:,
                    is_error: False,
                  )
                llm_types.ToolFailure(tool_use_id:, error: err) ->
                  llm_types.ToolResultContent(
                    tool_use_id:,
                    content: err,
                    is_error: True,
                  )
              }
            })
          let user_msg =
            llm_types.Message(role: llm_types.User, content: result_blocks)
          let messages = list.append(state.messages, [assistant_msg, user_msg])
          let new_task_id = cycle_log.generate_uuid()
          let req = cognitive_llm.build_request(state, messages)
          worker.spawn_think(
            new_task_id,
            req,
            state.provider,
            state.self,
            state.config.retry_config,
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
                node_type: pending_node_type,
              ),
            ),
          )
        }
        _ -> {
          // Normal MODIFY — append caution instruction and re-think
          let assistant_msg =
            llm_types.Message(role: llm_types.Assistant, content: resp.content)
          let modify_msg =
            llm_types.Message(role: llm_types.User, content: [
              llm_types.TextContent(
                text: build_rejection_notice("tool", result, "tool dispatch")
                <> " Please reconsider your approach and proceed with additional caution.",
              ),
            ])
          let messages =
            list.append(state.messages, [assistant_msg, modify_msg])
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
            state.config.retry_config,
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
                node_type: pending_node_type,
              ),
            ),
          )
        }
      }
    }

    dprime_types.Reject -> {
      // Generate error tool results for all calls and continue
      let assistant_msg =
        llm_types.Message(role: llm_types.Assistant, content: resp.content)
      let error_blocks =
        list.map(calls, fn(call) {
          llm_types.ToolResultContent(
            tool_use_id: call.id,
            content: build_rejection_notice(
              "tool",
              result,
              "tool call: " <> call.name,
            ),
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
        state.config.retry_config,
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
            node_type: pending_node_type,
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

  // Build context from recent messages (character-budget walker, all content types)
  let ctx = build_context_string(state.messages, 2000)

  let det_config = state.config.deterministic_config
  let redact_secrets = state.redact_secrets

  // TODO(BF-12): Gate processes have no timeout. If the LLM call inside
  // gate.evaluate hangs, the cognitive loop waits forever. A timeout
  // mechanism (e.g. process.send_after with a new message type) should be
  // added to cancel stalled gate evaluations.
  process.spawn_unlinked(fn() {
    let result =
      gate.evaluate_with_deterministic(
        instruction,
        ctx,
        dprime_st,
        provider,
        scorer_model,
        cycle_id,
        verbose,
        redact_secrets,
        det_config,
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

  // Emit audit record (BF-07)
  let input_audit_record =
    dprime_audit.build_record(
      cycle_id,
      text,
      result,
      case state.input_dprime_state {
        Some(ds) -> ds.config.features
        None -> []
      },
      None,
      None,
    )
  dprime_audit.log_record(input_audit_record, cycle_id)

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
  let new_dprime_state = case state.input_dprime_state {
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
  // Increment session-level D' counters for input gate
  let state = case result.decision {
    dprime_types.Modify ->
      CognitiveState(
        ..state,
        session_dprime_modifications: state.session_dprime_modifications + 1,
      )
    dprime_types.Reject ->
      CognitiveState(
        ..state,
        session_dprime_rejections: state.session_dprime_rejections + 1,
      )
    dprime_types.Accept -> state
  }
  let state =
    CognitiveState(
      ..state,
      input_dprime_state: new_dprime_state,
      dprime_decisions: [record, ..state.dprime_decisions],
    )

  case result.decision {
    dprime_types.Accept -> {
      // Proceed normally with the LLM call
      cognitive_llm.proceed_with_model(
        state,
        model,
        text,
        cycle_id,
        reply_to,
        dag_types.CognitiveCycle,
      )
    }

    dprime_types.Modify -> {
      // Inject a caution message into history, then proceed
      let caution_msg =
        llm_types.Message(role: llm_types.User, content: [
          llm_types.TextContent(
            text: build_rejection_notice("input", result, "user query")
            <> " Please proceed with additional caution.",
          ),
        ])
      let messages = list.append(state.messages, [caution_msg])
      cognitive_llm.proceed_with_model(
        CognitiveState(..state, messages:),
        model,
        text,
        cycle_id,
        reply_to,
        dag_types.CognitiveCycle,
      )
    }

    dprime_types.Reject -> {
      // User sees a clean, contextual message
      let user_text = build_user_response(result)
      // Agent's history gets the technical details for pattern learning
      let agent_text = build_rejection_notice("input", result, "user query")
      process.send(
        reply_to,
        CognitiveReply(response: user_text, model:, usage: None),
      )
      let state = cognitive_state.apply_meta_observation(state, 0)
      let state = with_assistant_error(state, agent_text)
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

  // Emit audit record (BF-07)
  let post_exec_audit_record =
    dprime_audit.build_record(
      cycle_id,
      "post-execution re-check",
      result,
      case state.tool_dprime_state {
        Some(ds) -> ds.config.features
        None -> []
      },
      Some(pre_score),
      None,
    )
  dprime_audit.log_record(post_exec_audit_record, cycle_id)

  // Update D' state history
  let new_dprime_state = case state.tool_dprime_state {
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
    CognitiveState(
      ..state,
      tool_dprime_state: new_dprime_state,
      dprime_decisions: [record, ..state.dprime_decisions],
    )

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
      let intervention = case state.tool_dprime_state {
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
          let new_ds = case state.tool_dprime_state {
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
          CognitiveState(..state, tool_dprime_state: new_ds)
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
  let model = state.task_model
  let verbose = state.verbose
  // Use the most recent user message as query context, not the potentially
  // stale last_user_input which may predate multiple tool turns (BF-05).
  let query =
    list.reverse(state.messages)
    |> list.find_map(fn(m) {
      case m.role {
        llm_types.User ->
          case m.content {
            [llm_types.TextContent(text: t), ..] -> Ok(t)
            _ -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })
    |> option.from_result
    |> option.unwrap(state.last_user_input)
  let det_config = state.config.deterministic_config
  let redact_secrets = state.redact_secrets
  // TODO(BF-12): Gate processes have no timeout. If the LLM call inside
  // output_gate.evaluate hangs, the cognitive loop waits forever. A timeout
  // mechanism (e.g. process.send_after with a new message type) should be
  // added to cancel stalled gate evaluations.
  process.spawn_unlinked(fn() {
    let result =
      output_gate.evaluate_with_deterministic(
        report_text,
        query,
        output_state,
        provider,
        model,
        cycle_id,
        verbose,
        redact_secrets,
        det_config,
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
  cycle_id: String,
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

  // Emit audit record (BF-07)
  let output_audit_record =
    dprime_audit.build_record(
      cycle_id,
      report_text,
      result,
      case state.output_dprime_state {
        Some(ds) -> ds.config.features
        None -> []
      },
      None,
      None,
    )
  dprime_audit.log_record(output_audit_record, cycle_id)

  let max_modifications = case state.output_dprime_state {
    Some(ds) -> ds.config.max_output_modifications
    None -> 2
  }
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
      let state = cognitive_state.apply_meta_observation(state, 0)
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
          let state = cognitive_state.apply_meta_observation(state, 0)
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
                text: "[SYSTEM: Your response was NOT delivered to the user. The quality gate flagged the following issues. Please revise and produce an updated response.]\n\n"
                <> explanation,
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
            new_state.config.retry_config,
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
                node_type: dag_types.CognitiveCycle,
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
      // User sees a clean, contextual message
      let user_text = build_user_response(result)
      // Agent's history gets the technical details + explicit non-delivery notice
      let agent_text =
        "[SYSTEM: Your response was NOT delivered to the user — it was rejected by the quality gate.] "
        <> build_rejection_notice("output", result, "agent response")
      process.send(
        reply_to,
        CognitiveReply(response: user_text, model: state.model, usage: None),
      )
      let state = cognitive_state.apply_meta_observation(state, 0)
      let state = with_assistant_error(state, agent_text)
      CognitiveState(..state, status: Idle)
    }
  }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Build a context string from messages using a character budget (BF-04).
/// Walks messages most-recent-first, includes all content types (text,
/// tool use summaries, tool results), stops when budget is exhausted.
fn build_context_string(
  messages: List(llm_types.Message),
  budget: Int,
) -> String {
  let reversed = list.reverse(messages)
  build_context_loop(reversed, budget, [])
  |> string.join("\n")
}

fn build_context_loop(
  messages: List(llm_types.Message),
  remaining: Int,
  acc: List(String),
) -> List(String) {
  case remaining <= 0 || messages == [] {
    True -> list.reverse(acc)
    False ->
      case messages {
        [] -> list.reverse(acc)
        [msg, ..rest] -> {
          let text = extract_message_content(msg)
          let len = string.length(text)
          case len > remaining {
            True -> {
              let truncated = string.slice(text, 0, remaining)
              list.reverse([truncated, ..acc])
            }
            False -> build_context_loop(rest, remaining - len, [text, ..acc])
          }
        }
      }
  }
}

/// Extract a text summary from all content blocks in a message.
fn extract_message_content(msg: llm_types.Message) -> String {
  list.filter_map(msg.content, fn(block) {
    case block {
      llm_types.TextContent(text: t) -> Ok(t)
      llm_types.ToolUseContent(id: _, name: n, input_json: input) ->
        Ok("[tool_use: " <> n <> " " <> string.slice(input, 0, 200) <> "]")
      llm_types.ToolResultContent(tool_use_id: _, content: c, is_error: _) ->
        Ok("[tool_result: " <> string.slice(c, 0, 200) <> "]")
      llm_types.ImageContent(media_type: _, data: _) -> Error(Nil)
    }
  })
  |> string.join(" ")
}
