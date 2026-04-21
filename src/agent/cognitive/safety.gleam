// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import affect/correlation as affect_correlation
import agent/cognitive/llm as cognitive_llm
import agent/cognitive/memory as cognitive_memory
import agent/cognitive/output
import agent/cognitive_state.{type CognitiveState, CognitiveState}
import agent/types.{
  type CognitiveReply, Idle, PendingThink, SafetyGateNotice, SensoryEvent,
  Thinking,
}
import agent/worker
import cycle_log
import dag/types as dag_types
import dprime/audit as dprime_audit
import dprime/canary
import dprime/deterministic.{Blocked, Escalated, Pass}
import dprime/gate
import dprime/meta
import dprime/output_gate
import dprime/types as dprime_types
import facts/log as facts_log
import facts/types as facts_types
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import llm/provider
import llm/types as llm_types
import narrative/librarian
import normative/drift as normative_drift
import normative/types as normative_types
import paths
import slog

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

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
  _content_type: String,
) -> String {
  // Terse notice for agent message history — full explanation is in the cycle log.
  // Verbose rejection notices eat context window and teach the agent to self-censor.
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
        triggers -> " Triggers: [" <> triggers <> "]."
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
  <> ")."
  <> feature_triggers
  <> "]"
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
  let instruction = text
  let base_ctx = build_context_string(state.messages, 2000)
  // Phase D follow-up — meta-learning. Prepend any persisted
  // affect-performance correlation warnings (negative r ≤ -0.4) so the
  // input gate's LLM scorer can weight risk against the agent's known
  // maladaptive emotional patterns. Empty when no warnings exist.
  let ctx = case affect_warnings_context() {
    "" -> base_ctx
    w -> w <> "\n\n" <> base_ctx
  }
  let det_config = state.config.deterministic_config
  let redact_secrets = state.redact_secrets
  let gate_timeout_ms = state.config.gate_timeout_ms

  // BF-12: Gate timeout
  let _ =
    process.send_after(
      self,
      gate_timeout_ms,
      types.GateTimeout(task_id: cycle_id, gate: "input"),
    )

  // Input gate strategy:
  // - Interactive cycles: configured regex rules only (no structural/payload
  //   heuristics — operator may legitimately paste technical content about
  //   safety systems). Block rules demoted to Escalate so canary probes
  //   decide, since operator-typed input is trusted.
  // - Autonomous cycles: full deterministic check (regex + structural +
  //   payload) + escalation triggers full LLM evaluation. Block stays hard.
  let is_autonomous = state.cycle_node_type == dag_types.SchedulerCycle
  process.spawn_unlinked(fn() {
    // Step 1: Deterministic pre-filter
    let raw_det_result = case det_config {
      Some(dc) ->
        case is_autonomous {
          True -> deterministic.check_input(instruction, dc)
          False -> deterministic.check_input_interactive(instruction, dc)
        }
      None -> Pass
    }

    // For interactive input, demote Blocked to Escalated so the canary
    // probes decide. Operator-typed content is trusted at a higher level
    // than scheduler input; genuine hijacks are caught by canaries, and
    // legitimate meta-conversation (discussing adversarial patterns,
    // security research, jailbreak techniques) is no longer hard-blocked
    // by substring regex. Scheduler input keeps hard-block semantics.
    let det_result = case is_autonomous, raw_det_result {
      False, Blocked(rule_id, reason) -> {
        slog.info(
          "cognitive",
          "spawn_input_safety_gate",
          "Deterministic block demoted to escalate for interactive: rule "
            <> rule_id,
          Some(cycle_id),
        )
        Escalated(rule_id, reason)
      }
      _, other -> other
    }

    let result = case det_result {
      // Blocked — reject immediately, no LLM calls (always, both modes)
      Blocked(rule_id, _reason) -> {
        slog.warn(
          "cognitive",
          "spawn_input_safety_gate",
          "Deterministic block: rule " <> rule_id,
          Some(cycle_id),
        )
        cycle_log.log_dprime_layer(
          cycle_id,
          "deterministic_input",
          "reject",
          1.0,
          "Deterministic block: banned input pattern detected",
        )
        dprime_types.GateResult(
          decision: dprime_types.Reject,
          dprime_score: 1.0,
          forecasts: [],
          explanation: "Deterministic block: banned input pattern detected",
          layer: dprime_types.Reactive,
          canary_result: None,
        )
      }

      // Escalated — suspicious pattern
      Escalated(_rule_id, _det_context) -> {
        case is_autonomous {
          // Autonomous: run full LLM evaluation (scheduler input may carry
          // indirect injection from web content or external sources)
          True -> {
            slog.info(
              "cognitive",
              "spawn_input_safety_gate",
              "Deterministic escalation — running full LLM evaluation (autonomous)",
              Some(cycle_id),
            )
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
          }
          // Interactive: treat escalation as pass — operator is not a threat.
          // Run canaries only (below), skip LLM scorer.
          False -> {
            slog.info(
              "cognitive",
              "spawn_input_safety_gate",
              "Deterministic escalation — skipping LLM scorer (interactive, operator input)",
              Some(cycle_id),
            )
            run_canaries_and_accept(
              instruction,
              dprime_st,
              provider,
              scorer_model,
              cycle_id,
              verbose,
              redact_secrets,
            )
          }
        }
      }

      // Pass — run canaries only, then fast-accept (no LLM scorer)
      Pass ->
        run_canaries_and_accept(
          instruction,
          dprime_st,
          provider,
          scorer_model,
          cycle_id,
          verbose,
          redact_secrets,
        )
    }

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

/// Run canary probes and fast-accept if clean. Used by both the Pass and
/// interactive Escalated paths in the input gate.
fn run_canaries_and_accept(
  instruction: String,
  dprime_st: dprime_types.DprimeState,
  provider: provider.Provider,
  scorer_model: String,
  cycle_id: String,
  verbose: Bool,
  redact_secrets: Bool,
) -> dprime_types.GateResult {
  let canary_result = case dprime_st.config.canary_enabled {
    True -> {
      slog.debug(
        "cognitive",
        "run_canaries_and_accept",
        "Running canary probes",
        Some(cycle_id),
      )
      let probe =
        canary.run_probes(
          instruction,
          provider,
          scorer_model,
          cycle_id,
          verbose,
          redact_secrets,
        )
      cycle_log.log_dprime_canary(
        cycle_id,
        probe.hijack_detected,
        probe.leakage_detected,
        probe.details,
      )
      Some(probe)
    }
    False -> None
  }

  case canary_result {
    Some(probe) if probe.hijack_detected || probe.leakage_detected -> {
      slog.warn(
        "cognitive",
        "run_canaries_and_accept",
        "Canary probe detected: " <> probe.details,
        Some(cycle_id),
      )
      dprime_types.GateResult(
        decision: dprime_types.Reject,
        dprime_score: 1.0,
        forecasts: [],
        explanation: "Canary probe detected: " <> probe.details,
        layer: dprime_types.Reactive,
        canary_result:,
      )
    }
    _ -> {
      slog.debug(
        "cognitive",
        "run_canaries_and_accept",
        "Input gate fast-accept: canaries clean",
        Some(cycle_id),
      )
      cycle_log.log_dprime_layer(
        cycle_id,
        "input_gate",
        "accept",
        0.0,
        "Fast-accept: canaries clean",
      )
      dprime_types.GateResult(
        decision: dprime_types.Accept,
        dprime_score: 0.0,
        forecasts: [],
        explanation: "Fast-accept: canaries clean",
        layer: dprime_types.Reactive,
        canary_result:,
      )
    }
  }
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
  // Track canary probe failures for operator alerting
  let state = case result.canary_result {
    Some(probe) if probe.probe_failed -> {
      let new_count = state.consecutive_probe_failures + 1
      slog.warn(
        "cognitive",
        "handle_input_safety_gate_complete",
        "Canary probe failed (consecutive: " <> int.to_string(new_count) <> ")",
        Some(cycle_id),
      )
      let state = CognitiveState(..state, consecutive_probe_failures: new_count)
      // Emit sensory event at threshold (3 consecutive failures)
      case new_count >= 3 {
        True -> {
          process.send(
            state.self,
            types.QueuedSensoryEvent(event: types.SensoryEvent(
              name: "canary_probe_degraded",
              title: "Canary probes degraded",
              body: "Canary probes have failed "
                <> int.to_string(new_count)
                <> " times consecutively — the safety probe LLM may be degraded",
              fired_at: "",
            )),
          )
          state
        }
        False -> state
      }
    }
    Some(_) ->
      // Probe succeeded — reset counter
      CognitiveState(..state, consecutive_probe_failures: 0)
    None -> state
  }

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
      output.send_reply(state, reply_to, user_text, model, None, [])
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

/// Check only deterministic rules for short conversational replies.
/// Skips the LLM scorer entirely. If deterministic rules block, sends a
/// Reject via OutputGateComplete. Otherwise delivers the reply directly.
pub fn check_deterministic_only(
  state: CognitiveState,
  reply_text: String,
  reply_to: Subject(CognitiveReply),
  messages: List(llm_types.Message),
  task_id: String,
  usage: llm_types.Usage,
) -> CognitiveState {
  let cycle_id = option.unwrap(state.cycle_id, task_id)

  // Run deterministic output rules if configured
  let blocked = case state.config.deterministic_config {
    Some(dc) -> {
      let det_result = deterministic.check_output(reply_text, dc)
      case det_result {
        Blocked(rule_id, _reason) -> {
          slog.warn(
            "cognitive/safety",
            "check_deterministic_only",
            "Short reply blocked by deterministic rule: " <> rule_id,
            Some(cycle_id),
          )
          True
        }
        Escalated(_, _) | Pass -> False
      }
    }
    None -> False
  }

  case blocked {
    True -> {
      // Route through normal OutputGateComplete handling for consistent flow
      let self = state.self
      process.send(
        self,
        types.OutputGateComplete(
          cycle_id:,
          result: dprime_types.GateResult(
            decision: dprime_types.Reject,
            dprime_score: 1.0,
            forecasts: [],
            explanation: "Deterministic block: banned output pattern detected",
            layer: dprime_types.Reactive,
            canary_result: None,
          ),
          report_text: reply_text,
          modification_count: 0,
          reply_to:,
        ),
      )
      CognitiveState(
        ..state,
        messages:,
        status: Thinking(task_id:),
        pending_output_reply: Some(#(reply_to, reply_text)),
      )
    }
    False -> {
      // Clean — deliver reply directly (same as no-output-gate path)
      slog.info(
        "cognitive/safety",
        "check_deterministic_only",
        "Short reply ("
          <> int.to_string(string.length(reply_text))
          <> " chars) — skipped LLM output gate",
        Some(cycle_id),
      )
      // Finalise DAG node with token counts
      finalise_dag_node(
        state,
        usage.input_tokens,
        usage.output_tokens,
        state.model,
      )
      output.send_reply(
        state,
        reply_to,
        reply_text,
        state.model,
        Some(usage),
        list.map(state.cycle_tool_calls, fn(t) { t.name }),
      )
      // Spawn Archivist (fire-and-forget narrative + CBR generation)
      cognitive_memory.maybe_spawn_archivist(
        state,
        reply_text,
        state.model,
        Some(usage),
      )
      let state =
        cognitive_state.apply_meta_observation(
          state,
          usage.input_tokens + usage.output_tokens,
        )
      let state = with_assistant_error(state, reply_text)
      CognitiveState(..state, messages:, status: Idle)
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
  // BF-12: Gate timeout — if the scorer LLM hangs, send a synthetic Accept
  // after gate_timeout_ms so the agent doesn't block forever. The gate process
  // may still complete later, but by then the cognitive loop has moved to Idle
  // so the late GateTimeout is ignored (status != Thinking(task_id)).
  let gate_timeout_ms = state.config.gate_timeout_ms
  let _ =
    process.send_after(
      self,
      gate_timeout_ms,
      types.GateTimeout(task_id:, gate: "output"),
    )
  let character_spec = state.config.character_spec
  let normative_enabled = state.config.normative_calculus_enabled
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
        character_spec,
        normative_enabled,
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
    "Spawned output gate evaluation (timeout: "
      <> int.to_string(gate_timeout_ms)
      <> "ms)",
    state.cycle_id,
  )
  CognitiveState(
    ..state,
    messages:,
    status: Thinking(task_id:),
    pending: dict.delete(state.pending, task_id),
    pending_output_reply: Some(#(reply_to, report_text)),
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
  // Clear the pending output reply — the gate completed normally
  let state = CognitiveState(..state, pending_output_reply: None)
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

  // Record normative verdict for drift tracking (when normative calculus enabled)
  let state = record_normative_verdict(state, result.decision)

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
      // Finalise DAG node with stashed usage
      let usage = state.pending_output_usage
      let #(tokens_in, tokens_out) = case usage {
        Some(u) -> #(u.input_tokens, u.output_tokens)
        None -> #(0, 0)
      }
      finalise_dag_node(state, tokens_in, tokens_out, state.model)
      output.send_reply(
        state,
        reply_to,
        report_text,
        state.model,
        usage,
        list.map(state.cycle_tool_calls, fn(t) { t.name }),
      )
      // Spawn Archivist (fire-and-forget narrative + CBR generation)
      cognitive_memory.maybe_spawn_archivist(
        state,
        report_text,
        state.model,
        usage,
      )
      let state =
        cognitive_state.apply_meta_observation(state, tokens_in + tokens_out)
      // Note: state.messages already contains the assistant response
      // (added by spawn_output_gate). Do NOT call with_assistant_error here
      // — that would duplicate the response in the session.
      let new_state =
        CognitiveState(
          ..state,
          status: Idle,
          pending_output_usage: None,
          output_gate_rejections: 0,
          cycles_today: state.cycles_today + 1,
        )
      new_state
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
          let usage = state.pending_output_usage
          let #(tokens_in, tokens_out) = case usage {
            Some(u) -> #(u.input_tokens, u.output_tokens)
            None -> #(0, 0)
          }
          finalise_dag_node(state, tokens_in, tokens_out, state.model)
          output.send_reply(
            state,
            reply_to,
            full_text,
            state.model,
            usage,
            list.map(state.cycle_tool_calls, fn(t) { t.name }),
          )
          cognitive_memory.maybe_spawn_archivist(
            state,
            full_text,
            state.model,
            usage,
          )
          let state =
            cognitive_state.apply_meta_observation(
              state,
              tokens_in + tokens_out,
            )
          // Note: state.messages already contains the assistant response
          // (added by spawn_output_gate). Do NOT call with_assistant_error here.
          let new_state =
            CognitiveState(
              ..state,
              status: Idle,
              pending_output_usage: None,
              cycles_today: state.cycles_today + 1,
            )
          new_state
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
                text: "[SYSTEM: Your response was NOT delivered to the user. The quality gate flagged specific issues listed below. IMPORTANT: Fix ONLY the flagged issues. Preserve all other content, structure, and tone from your original response. Do not remove information that was not flagged. Do not add unnecessary hedging or caveats. Produce a corrected version of your full response.]\n\nFlagged issues:\n"
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
                node_type: state.cycle_node_type,
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
      // Agent's history gets a terse notice — full details in cycle log
      let agent_text =
        build_rejection_notice("output", result, "agent response")
      let usage = state.pending_output_usage
      let #(tokens_in, tokens_out) = case usage {
        Some(u) -> #(u.input_tokens, u.output_tokens)
        None -> #(0, 0)
      }
      finalise_dag_node(state, tokens_in, tokens_out, state.model)
      output.send_reply(
        state,
        reply_to,
        user_text,
        state.model,
        usage,
        list.map(state.cycle_tool_calls, fn(t) { t.name }),
      )
      let state =
        cognitive_state.apply_meta_observation(state, tokens_in + tokens_out)
      let state = with_assistant_error(state, agent_text)
      let new_state =
        CognitiveState(
          ..state,
          status: Idle,
          pending_output_usage: None,
          output_gate_rejections: state.output_gate_rejections + 1,
          cycles_today: state.cycles_today + 1,
        )
      new_state
    }
  }
}

/// Handle a gate timeout — the spawned gate process didn't respond in time.
/// Fail-open: deliver the report rather than blocking the agent forever.
pub fn handle_gate_timeout(
  state: CognitiveState,
  task_id: String,
  gate: String,
) -> CognitiveState {
  // Only act if we're still waiting — check if we're in Thinking state
  // for this task. If the gate already completed, ignore the timeout.
  case state.status {
    Thinking(task_id: current_task_id) if current_task_id == task_id -> {
      slog.warn(
        "cognitive",
        "handle_gate_timeout",
        gate
          <> " gate timed out (task "
          <> task_id
          <> ") — delivering report (fail-open)",
        state.cycle_id,
      )
      // Use the stored pending_output_reply to deliver the report
      case state.pending_output_reply {
        Some(#(reply_to, report_text)) -> {
          output.send_reply(
            state,
            reply_to,
            report_text,
            state.model,
            None,
            list.map(state.cycle_tool_calls, fn(t) { t.name }),
          )
          let new_state =
            CognitiveState(
              ..state,
              status: Idle,
              pending_output_reply: None,
              cycles_today: state.cycles_today + 1,
            )
          new_state
        }
        None -> {
          // No pending output — just unblock
          CognitiveState(..state, status: Idle)
        }
      }
    }
    _ -> {
      // Gate already completed before timeout — ignore
      state
    }
  }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Build the affect-warnings context block — meta-learning Phase D
/// follow-up. Reads `affect_corr_*` facts written by the Remembrancer's
/// `analyze_affect_performance` tool and produces a short prompt block
/// listing strongly negative correlations (r ≤ -0.4) so the input D'
/// gate scorer can factor them into risk evaluation. Returns "" when
/// no warnings meet the threshold.
fn affect_warnings_context() -> String {
  let facts = facts_log.resolve_current(paths.facts_dir(), None)
  let warnings =
    facts
    |> list.filter(fn(f) {
      string.starts_with(f.key, "affect_corr_")
      && f.operation == facts_types.Write
    })
    |> list.filter_map(fn(f) {
      case affect_correlation.parse_fact_value(f.value) {
        Ok(#(r, n, inconclusive)) ->
          case inconclusive || r >. -0.4 {
            True -> Error(Nil)
            False ->
              Ok(
                "- "
                <> f.key
                <> ": r="
                <> float.to_string(r)
                <> " (n="
                <> int.to_string(n)
                <> ")",
              )
          }
        Error(_) -> Error(Nil)
      }
    })
  case warnings {
    [] -> ""
    _ ->
      "[affect_warnings — historical maladaptive patterns, weight risk accordingly]\n"
      <> string.join(warnings, "\n")
  }
}

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
      llm_types.ThinkingContent(text: _) -> Error(Nil)
    }
  })
  |> string.join(" ")
}

// ---------------------------------------------------------------------------
// Normative drift tracking
// ---------------------------------------------------------------------------

/// Record a normative verdict and check for drift.
/// When drift is detected, emits a sensory event for the sensorium.
@external(erlang, "springdrift_ffi", "monotonic_now_ms")
fn monotonic_now_ms() -> Int

/// Finalise the root cycle DAG node with success outcome and token counts.
/// This must be called on every delivery path (Accept, Modify-max, Reject,
/// deterministic-only) or the cycle stays permanently "pending" with 0/0 tokens.
fn finalise_dag_node(
  state: CognitiveState,
  tokens_in: Int,
  tokens_out: Int,
  model: String,
) -> Nil {
  let cycle_id = option.unwrap(state.cycle_id, "unknown")
  let duration_ms = case state.cycle_started_ms {
    0 -> 0
    started -> monotonic_now_ms() - started
  }
  case state.memory.librarian {
    Some(lib) ->
      process.send(
        lib,
        librarian.UpdateNode(node: dag_types.CycleNode(
          cycle_id:,
          parent_id: None,
          node_type: state.cycle_node_type,
          timestamp: "",
          outcome: dag_types.NodeSuccess,
          model:,
          complexity: "",
          tool_calls: state.cycle_tool_calls,
          dprime_gates: list.map(state.dprime_decisions, fn(d) {
            dag_types.GateSummary(
              gate: d.gate,
              decision: d.decision,
              score: d.score,
            )
          }),
          tokens_in:,
          tokens_out:,
          duration_ms:,
          agent_output: None,
          instance_name: state.identity.agent_name,
          instance_id: string.slice(state.identity.agent_uuid, 0, 8),
        )),
      )
    None -> Nil
  }
}

fn drift_signal_type_label(signal: normative_drift.DriftSignal) -> String {
  case signal.signal_type {
    normative_drift.HighConstraintRate -> "high constraint rate"
    normative_drift.HighProhibitionRate -> "high prohibition rate"
    normative_drift.RepeatedAxiom -> "repeated axiom"
    normative_drift.OverRestriction -> "over-restriction"
  }
}

fn record_normative_verdict(
  state: CognitiveState,
  decision: dprime_types.GateDecision,
) -> CognitiveState {
  case state.drift_state {
    None -> state
    Some(ds) -> {
      let verdict = case decision {
        dprime_types.Accept -> normative_types.Flourishing
        dprime_types.Modify -> normative_types.Constrained
        dprime_types.Reject -> normative_types.Prohibited
      }
      let ds = normative_drift.record_verdict(ds, verdict, [])
      let state = CognitiveState(..state, drift_state: Some(ds))

      // Check for drift and emit sensory event if detected
      case normative_drift.detect_drift(ds) {
        Some(signal) -> {
          slog.warn(
            "cognitive/safety",
            "record_normative_verdict",
            "Virtue drift detected: " <> signal.description,
            state.cycle_id,
          )
          let event =
            SensoryEvent(
              name: "normative_drift",
              title: "Virtue drift: " <> drift_signal_type_label(signal),
              body: signal.description,
              fired_at: get_datetime(),
            )
          CognitiveState(..state, pending_sensory_events: [
            event,
            ..state.pending_sensory_events
          ])
        }
        None -> state
      }
    }
  }
}
