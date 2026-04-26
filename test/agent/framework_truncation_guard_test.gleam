//// Sub-agent truncation guard tests.
////
//// The framework must not return a truncated mid-sentence response
//// to the orchestrator as if it were a successful outcome. When an
//// agent's LLM response hits MaxTokens with no tool calls, the react
//// loop retries once with a scope-down nudge; on the second hit it
//// ships a deterministic admission that embeds the agent's
//// accumulated partial work so the orchestrator and operator can see
//// what was produced.
////
//// Test layers:
////  1. Pure: `build_truncation_admission` is deterministic — assert
////     its output shape directly.
////  2. End-to-end: drive a real agent via `framework.start_agent`
////     with a mock provider that returns MaxTokens responses on a
////     controlled schedule, observe what shows up on AgentComplete.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/framework
import agent/types.{
  type AgentSpec, type CognitiveMessage, AgentComplete, AgentFailure, AgentSpec,
  AgentSuccess, AgentTask, Temporary,
}
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/string
import gleeunit/should
import llm/adapters/mock
import llm/types as llm_types

// ---------------------------------------------------------------------------
// Pure: build_truncation_admission
// ---------------------------------------------------------------------------

pub fn admission_starts_with_operator_facing_prefix_test() {
  // The `[truncation_guard:<agent>]` prefix is load-bearing — operators
  // and orchestrators recognise the failure mode by it. If renamed
  // without updating downstream rendering / instructions, the failure
  // becomes invisible again.
  let admission =
    framework.build_truncation_admission("writer", "opus", 4096, 4096, "")
  admission |> string.starts_with("[truncation_guard:writer]") |> should.be_true
}

pub fn admission_includes_agent_model_and_token_numbers_test() {
  // Operator needs to know which agent + which model + actual vs limit
  // tokens to act (raise max_tokens, narrow scope, or accept partial).
  let admission =
    framework.build_truncation_admission(
      "researcher",
      "claude-haiku",
      2048,
      2048,
      "",
    )
  admission |> string.contains("researcher") |> should.be_true
  admission |> string.contains("claude-haiku") |> should.be_true
  admission |> string.contains("2048") |> should.be_true
}

pub fn admission_embeds_partial_when_short_test() {
  // Short partial output should appear verbatim in the admission so
  // the orchestrator can pick it up directly.
  let partial = "Section 1 findings: A B C. Section 2 findings: D E F."
  let admission =
    framework.build_truncation_admission("writer", "opus", 100, 200, partial)
  admission |> string.contains(partial) |> should.be_true
}

pub fn admission_elides_middle_when_partial_is_long_test() {
  // When the partial output exceeds the admission preview limit, the
  // head and tail are kept and the middle is elided. The exact size
  // limit is internal but the elision marker is the contract.
  let long_partial = string.repeat("X", 8000)
  let admission =
    framework.build_truncation_admission(
      "writer",
      "opus",
      100,
      200,
      long_partial,
    )
  admission |> string.contains("chars elided") |> should.be_true
}

pub fn admission_handles_empty_partial_test() {
  // Cycle that hit the cap before producing any text — admission
  // should still be readable, not show a stray empty content block.
  let admission =
    framework.build_truncation_admission("writer", "opus", 100, 200, "")
  admission
  |> string.contains("(no text was produced before truncation)")
  |> should.be_true
}

pub fn admission_includes_recovery_suggestions_test() {
  // The point of the admission is actionable next steps. Pin them.
  let admission =
    framework.build_truncation_admission("writer", "opus", 100, 200, "")
  admission |> string.contains("narrower scope") |> should.be_true
  admission |> string.contains("max_tokens") |> should.be_true
  admission |> string.contains("store_result") |> should.be_true
}

// ---------------------------------------------------------------------------
// End-to-end: agent with mock provider
// ---------------------------------------------------------------------------

fn noop_executor(call: llm_types.ToolCall) -> llm_types.ToolResult {
  llm_types.ToolFailure(tool_use_id: call.id, error: "no tools")
}

fn make_spec(provider) -> AgentSpec {
  AgentSpec(
    name: "writer",
    human_name: "Writer",
    description: "A test writer.",
    system_prompt: "You write reports.",
    provider:,
    model: "mock",
    max_tokens: 256,
    max_turns: 3,
    max_consecutive_errors: 2,
    max_context_messages: option.None,
    tools: [],
    restart: Temporary,
    tool_executor: noop_executor,
    inter_turn_delay_ms: 0,
    redact_secrets: False,
  )
}

fn dispatch(
  spec: AgentSpec,
  instruction: String,
) -> Result(types.CognitiveMessage, Nil) {
  let assert Ok(#(_pid, task_subj)) = framework.start_agent(spec)
  let cognitive_subj: process.Subject(CognitiveMessage) = process.new_subject()
  let task =
    AgentTask(
      task_id: "task-trunc",
      tool_use_id: "tool-trunc",
      instruction:,
      context: "",
      parent_cycle_id: "cycle-trunc",
      reply_to: cognitive_subj,
      depth: 1,
      max_turns_override: option.None,
      deputy_subject: option.None,
    )
  process.send(task_subj, task)
  process.receive(cognitive_subj, 5000)
}

fn request_contains(req: llm_types.LlmRequest, needle: String) -> Bool {
  list.any(req.messages, fn(m: llm_types.Message) {
    list.any(m.content, fn(c) {
      case c {
        llm_types.TextContent(text:) -> string.contains(text, needle)
        _ -> False
      }
    })
  })
}

fn request_contains_truncation_nudge(req: llm_types.LlmRequest) -> Bool {
  // Sentinel string from the truncation nudge inside framework.do_react.
  // Tied to the framework code — if that prose is rewritten, update here.
  request_contains(req, "previous response was cut off at the token cap")
}

pub fn first_max_tokens_triggers_retry_then_clean_reply_test() {
  // Provider returns MaxTokens on the first call, normal text on the
  // retry. The agent must NOT return the truncated text — the
  // orchestrator should only see the recovered response. If retry
  // isn't wired, this test fails by getting "partial cut off mid-".
  let provider =
    mock.provider_with_handler(fn(req) {
      case request_contains_truncation_nudge(req) {
        True -> Ok(mock.text_response("recovered with tighter scope"))
        False -> Ok(mock.truncated_text_response("partial cut off mid-"))
      }
    })

  let spec = make_spec(provider)
  let assert Ok(msg) = dispatch(spec, "Write a long thing")
  case msg {
    AgentComplete(outcome:) ->
      case outcome {
        AgentSuccess(result:, ..) -> {
          result
          |> string.contains("recovered with tighter scope")
          |> should.be_true
          // Did NOT get the truncated text.
          result |> string.contains("partial cut off mid-") |> should.be_false
          // Did NOT get the deterministic admission (retry succeeded).
          result |> string.contains("[truncation_guard:") |> should.be_false
        }
        AgentFailure(..) -> should.fail()
      }
    _ -> should.fail()
  }
}

pub fn second_max_tokens_ships_deterministic_admission_test() {
  // Both calls return MaxTokens. Retry didn't help, so the framework
  // must ship the admission instead of either of the two truncated
  // outputs. The agent name in the prefix is the observable signal.
  let provider =
    mock.provider_with_handler(fn(_req) {
      Ok(mock.truncated_text_response("partial truncated text"))
    })

  let spec = make_spec(provider)
  let assert Ok(msg) = dispatch(spec, "Write something huge")
  case msg {
    AgentComplete(outcome:) ->
      case outcome {
        AgentSuccess(result:, ..) -> {
          // Admission with this agent's name in the prefix.
          result
          |> string.contains("[truncation_guard:writer]")
          |> should.be_true
          // Admission references the cap-tuning suggestion.
          result |> string.contains("max_tokens") |> should.be_true
          // Embeds at least some of the partial work for inspection.
          result |> string.contains("partial truncated text") |> should.be_true
        }
        AgentFailure(..) -> should.fail()
      }
    _ -> should.fail()
  }
}

pub fn admission_carries_truncated_flag_test() {
  // The framework already flags truncation on AgentSuccess — verify
  // that flag stays True when the admission ships, so an orchestrator
  // checking `truncated` still knows the cycle was capped (even
  // though the result text is the admission, not the raw truncated
  // text).
  let provider =
    mock.provider_with_handler(fn(_req) {
      Ok(mock.truncated_text_response("partial"))
    })

  let spec = make_spec(provider)
  let assert Ok(msg) = dispatch(spec, "Write")
  case msg {
    AgentComplete(outcome:) ->
      case outcome {
        AgentSuccess(truncated:, ..) -> truncated |> should.be_true
        AgentFailure(..) -> should.fail()
      }
    _ -> should.fail()
  }
}

pub fn truncation_retry_does_not_burn_max_turns_test() {
  // An agent with max_turns=1 should still get its one full turn AFTER
  // the truncation retry. If the retry burned a turn, the agent would
  // hit "max turns reached" before producing real output. The provider
  // here returns MaxTokens on the first call, then a clean response —
  // the retry should re-invoke and the agent should receive the
  // recovered text.
  let provider =
    mock.provider_with_handler(fn(req) {
      case request_contains_truncation_nudge(req) {
        True -> Ok(mock.text_response("recovered"))
        False -> Ok(mock.truncated_text_response("partial"))
      }
    })

  let spec = AgentSpec(..make_spec(provider), max_turns: 1)
  let assert Ok(msg) = dispatch(spec, "Write")
  case msg {
    AgentComplete(outcome:) ->
      case outcome {
        AgentSuccess(result:, ..) ->
          result |> string.contains("recovered") |> should.be_true
        AgentFailure(error:, ..) -> {
          echo error
          should.fail()
        }
      }
    _ -> should.fail()
  }
}
