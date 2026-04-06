// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleam/option.{None, Some}
import llm/types.{
  type ContentBlock, type LlmRequest, type Message, type Tool, type ToolChoice,
  type ToolResult, Assistant, LlmRequest, Message, TextContent, ToolFailure,
  ToolResultContent, ToolSuccess, User,
}

/// Create a new request with required fields; all optionals default to None
pub fn new(model: String, max_tokens: Int) -> LlmRequest {
  LlmRequest(
    model: model,
    messages: [],
    max_tokens: max_tokens,
    system: None,
    temperature: None,
    top_p: None,
    stop_sequences: None,
    tools: None,
    tool_choice: None,
    thinking_budget_tokens: None,
  )
}

/// Set thinking budget tokens (enables extended thinking)
pub fn with_thinking_budget(req: LlmRequest, budget: Int) -> LlmRequest {
  LlmRequest(..req, thinking_budget_tokens: Some(budget))
}

/// Replace the message list
pub fn with_messages(req: LlmRequest, messages: List(Message)) -> LlmRequest {
  LlmRequest(..req, messages: messages)
}

/// Append a single message
pub fn with_message(req: LlmRequest, message: Message) -> LlmRequest {
  LlmRequest(..req, messages: list.append(req.messages, [message]))
}

/// Append a user text message
pub fn with_user_message(req: LlmRequest, text: String) -> LlmRequest {
  with_message(req, Message(role: User, content: [TextContent(text: text)]))
}

/// Append an assistant text message (useful for few-shot prompting)
pub fn with_assistant_message(req: LlmRequest, text: String) -> LlmRequest {
  with_message(
    req,
    Message(role: Assistant, content: [TextContent(text: text)]),
  )
}

/// Add an assistant turn (with tool-use content) and a user turn (with tool results).
/// Use this to continue a conversation after executing tools.
pub fn with_tool_results(
  req: LlmRequest,
  assistant_content: List(ContentBlock),
  results: List(ToolResult),
) -> LlmRequest {
  let assistant_msg = Message(role: Assistant, content: assistant_content)
  let result_blocks =
    list.map(results, fn(result) {
      case result {
        ToolSuccess(tool_use_id: id, content: content) ->
          ToolResultContent(tool_use_id: id, content: content, is_error: False)
        ToolFailure(tool_use_id: id, error: err) ->
          ToolResultContent(tool_use_id: id, content: err, is_error: True)
      }
    })
  let user_msg = Message(role: User, content: result_blocks)
  LlmRequest(
    ..req,
    messages: list.append(req.messages, [assistant_msg, user_msg]),
  )
}

/// Set the system prompt
pub fn with_system(req: LlmRequest, system: String) -> LlmRequest {
  LlmRequest(..req, system: Some(system))
}

/// Set the sampling temperature
pub fn with_temperature(req: LlmRequest, temperature: Float) -> LlmRequest {
  LlmRequest(..req, temperature: Some(temperature))
}

/// Set top-p sampling
pub fn with_top_p(req: LlmRequest, top_p: Float) -> LlmRequest {
  LlmRequest(..req, top_p: Some(top_p))
}

/// Set stop sequences
pub fn with_stop_sequences(
  req: LlmRequest,
  sequences: List(String),
) -> LlmRequest {
  LlmRequest(..req, stop_sequences: Some(sequences))
}

/// Set the available tools
pub fn with_tools(req: LlmRequest, tools: List(Tool)) -> LlmRequest {
  LlmRequest(..req, tools: Some(tools))
}

/// Set the tool choice
pub fn with_tool_choice(req: LlmRequest, choice: ToolChoice) -> LlmRequest {
  LlmRequest(..req, tool_choice: Some(choice))
}
