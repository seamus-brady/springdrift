import gleam/option.{Some}
import llm/provider.{type Provider, Provider}
import llm/types.{
  type LlmError, type LlmRequest, type LlmResponse, EndTurn, LlmResponse,
  TextContent, ToolUseContent, ToolUseRequested, UnknownError, Usage,
}

/// Build a mock text response
pub fn text_response(text: String) -> LlmResponse {
  LlmResponse(
    id: "mock_msg_text",
    content: [TextContent(text: text)],
    model: "mock",
    stop_reason: Some(EndTurn),
    usage: Usage(input_tokens: 10, output_tokens: 10, thinking_tokens: 0),
  )
}

/// Build a mock tool-call response
pub fn tool_call_response(
  name: String,
  input_json: String,
  id: String,
) -> LlmResponse {
  LlmResponse(
    id: "mock_msg_tool",
    content: [ToolUseContent(id: id, name: name, input_json: input_json)],
    model: "mock",
    stop_reason: Some(ToolUseRequested),
    usage: Usage(input_tokens: 15, output_tokens: 20, thinking_tokens: 0),
  )
}

/// Provider that always returns a fixed text response
pub fn provider_with_text(text: String) -> Provider {
  Provider(name: "mock", chat: fn(_req) { Ok(text_response(text)) })
}

/// Provider that always returns an error
pub fn provider_with_error(reason: String) -> Provider {
  Provider(name: "mock", chat: fn(_req) { Error(UnknownError(reason: reason)) })
}

/// Provider that delegates to a custom handler function.
/// The handler can inspect the request (e.g. `list.length(req.messages)`)
/// to return different responses on successive turns.
pub fn provider_with_handler(
  handler: fn(LlmRequest) -> Result(LlmResponse, LlmError),
) -> Provider {
  Provider(name: "mock", chat: handler)
}
