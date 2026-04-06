// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/option.{type Option}

// Roles — Anthropic has no System role in messages; system goes in the request field
pub type Role {
  User
  Assistant
}

// Content blocks — extends anthropic/message.ContentBlock with thinking
pub type ContentBlock {
  TextContent(text: String)
  ImageContent(media_type: String, data: String)
  ToolUseContent(id: String, name: String, input_json: String)
  ToolResultContent(tool_use_id: String, content: String, is_error: Bool)
  ThinkingContent(text: String)
}

pub type Message {
  Message(role: Role, content: List(ContentBlock))
}

// Tool schema — PropertyType avoids stringly-typed "string"/"number"/etc.
pub type PropertyType {
  StringProperty
  NumberProperty
  IntegerProperty
  BooleanProperty
  ArrayProperty
  ObjectProperty
}

pub type ParameterSchema {
  ParameterSchema(
    param_type: PropertyType,
    description: Option(String),
    enum_values: Option(List(String)),
  )
}

pub type Tool {
  Tool(
    name: String,
    description: Option(String),
    parameters: List(#(String, ParameterSchema)),
    required_params: List(String),
  )
}

pub type ToolChoice {
  AutoToolChoice
  AnyToolChoice
  NoToolChoice
  SpecificToolChoice(name: String)
}

pub type ToolCall {
  ToolCall(id: String, name: String, input_json: String)
}

pub type ToolResult {
  ToolSuccess(tool_use_id: String, content: String)
  ToolFailure(tool_use_id: String, error: String)
}

pub type StopReason {
  EndTurn
  MaxTokens
  StopSequenceReached
  ToolUseRequested
}

pub type Usage {
  Usage(
    input_tokens: Int,
    output_tokens: Int,
    thinking_tokens: Int,
    cache_creation_tokens: Int,
    cache_read_tokens: Int,
  )
}

pub type LlmRequest {
  LlmRequest(
    model: String,
    messages: List(Message),
    max_tokens: Int,
    system: Option(String),
    temperature: Option(Float),
    top_p: Option(Float),
    stop_sequences: Option(List(String)),
    tools: Option(List(Tool)),
    tool_choice: Option(ToolChoice),
    thinking_budget_tokens: Option(Int),
  )
}

pub type LlmResponse {
  LlmResponse(
    id: String,
    content: List(ContentBlock),
    model: String,
    stop_reason: Option(StopReason),
    usage: Usage,
  )
}

pub type LlmError {
  ApiError(status_code: Int, message: String)
  NetworkError(reason: String)
  ConfigError(reason: String)
  DecodeError(reason: String)
  TimeoutError
  RateLimitError(message: String)
  UnknownError(reason: String)
}
