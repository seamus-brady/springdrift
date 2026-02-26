import gleam/option.{type Option}

// Roles — Anthropic has no System role in messages; system goes in the request field
pub type Role {
  User
  Assistant
}

// Content blocks — same 4 variants as anthropic/message.ContentBlock
pub type ContentBlock {
  TextContent(text: String)
  ImageContent(media_type: String, data: String)
  ToolUseContent(id: String, name: String, input_json: String)
  ToolResultContent(tool_use_id: String, content: String, is_error: Bool)
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
  Usage(input_tokens: Int, output_tokens: Int, thinking_tokens: Int)
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
