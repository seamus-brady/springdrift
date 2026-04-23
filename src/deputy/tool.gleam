//// The `ask_deputy` tool — specialist agents call this mid-task to
//// consult their deputy for help from memory. When a deputy is active
//// for the hierarchy, the framework routes the call to its process;
//// when no deputy is present, the tool returns an error explaining so.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import deputy/types as deputy_types
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/tool
import llm/types as llm_types

/// Tool declaration — visible on the framework's tool-registration path
/// for specialist agents that are in an active deputy hierarchy.
pub fn ask_deputy_tool() -> llm_types.Tool {
  tool.new("ask_deputy")
  |> tool.with_description(
    "Ask your deputy for help from memory — prior CBR cases, facts, or "
    <> "recent narrative that might bear on what you're doing. The deputy "
    <> "is a read-only reasoning agent that watches your delegation. Use "
    <> "this when you're stuck, uncertain, or want pre-validation. The "
    <> "deputy answers concisely from memory or admits it doesn't know.",
  )
  |> tool.add_string_param(
    "question",
    "The question to ask. Be specific: cite what you're working on.",
    True,
  )
  |> tool.add_string_param(
    "context",
    "Optional brief context (1-2 sentences). Leave empty if not needed.",
    False,
  )
  |> tool.build()
}

/// True if the tool name is `ask_deputy`. Used by the framework to
/// short-circuit execution when the call needs deputy access.
pub fn is_ask_deputy(name: String) -> Bool {
  name == "ask_deputy"
}

/// Execute an ask_deputy tool call by forwarding to the deputy subject.
///
/// When `deputy_subject` is None (no deputy for this hierarchy, or
/// briefing failed), returns a ToolFailure that tells the agent the
/// feature isn't available right now.
pub fn execute(
  call: llm_types.ToolCall,
  deputy_subject: Option(Subject(deputy_types.DeputyMessage)),
  timeout_ms: Int,
) -> llm_types.ToolResult {
  case deputy_subject {
    None ->
      llm_types.ToolFailure(
        tool_use_id: call.id,
        error: "ask_deputy unavailable: no active deputy for this delegation",
      )
    Some(subj) -> {
      let decoder = {
        use question <- decode.field("question", decode.string)
        use context <- decode.optional_field("context", "", decode.string)
        decode.success(#(question, context))
      }
      case json.parse(call.input_json, decoder) {
        Error(_) ->
          llm_types.ToolFailure(
            tool_use_id: call.id,
            error: "Invalid ask_deputy input: expected {question, context?}",
          )
        Ok(#(question, context)) -> {
          let trimmed = string.trim(question)
          case trimmed {
            "" ->
              llm_types.ToolFailure(
                tool_use_id: call.id,
                error: "question must not be empty",
              )
            _ -> {
              let reply = process.new_subject()
              process.send(
                subj,
                deputy_types.AskQuestion(
                  question: trimmed,
                  context: string.trim(context),
                  reply_to: reply,
                ),
              )
              case process.receive(reply, timeout_ms) {
                Ok(Ok(answer)) ->
                  llm_types.ToolSuccess(tool_use_id: call.id, content: answer)
                Ok(Error(reason)) ->
                  llm_types.ToolFailure(
                    tool_use_id: call.id,
                    error: "Deputy couldn't answer: " <> reason,
                  )
                Error(_) ->
                  llm_types.ToolFailure(
                    tool_use_id: call.id,
                    error: "Timeout waiting for deputy response",
                  )
              }
            }
          }
        }
      }
    }
  }
}
