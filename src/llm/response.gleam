import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import llm/types.{
  type LlmError, type LlmResponse, type ToolCall, ApiError, ConfigError,
  DecodeError, MaxTokens, NetworkError, RateLimitError, TextContent,
  TimeoutError, ToolCall, ToolUseContent, ToolUseRequested, UnknownError,
}

/// Join all TextContent blocks into a single string
pub fn text(response: LlmResponse) -> String {
  response.content
  |> list.filter_map(fn(block) {
    case block {
      TextContent(text: t) -> Ok(t)
      _ -> Error(Nil)
    }
  })
  |> string.join("")
}

/// Returns True if the model stopped to request tool execution
pub fn needs_tool_execution(response: LlmResponse) -> Bool {
  case response.stop_reason {
    Some(ToolUseRequested) -> True
    _ -> False
  }
}

/// Extract all ToolCall records from ToolUseContent blocks
pub fn tool_calls(response: LlmResponse) -> List(ToolCall) {
  list.filter_map(response.content, fn(block) {
    case block {
      ToolUseContent(id: id, name: name, input_json: input_json) ->
        Ok(ToolCall(id: id, name: name, input_json: input_json))
      _ -> Error(Nil)
    }
  })
}

/// Return the first tool call, or Error(Nil) if none
pub fn first_tool_call(response: LlmResponse) -> Result(ToolCall, Nil) {
  list.first(tool_calls(response))
}

/// Returns True if the response was cut off by the max_tokens limit
pub fn was_truncated(response: LlmResponse) -> Bool {
  case response.stop_reason {
    Some(MaxTokens) -> True
    _ -> False
  }
}

/// Total token count (input + output)
pub fn total_tokens(response: LlmResponse) -> Int {
  response.usage.input_tokens + response.usage.output_tokens
}

/// Human-readable description of an LlmError
pub fn error_message(error: LlmError) -> String {
  case error {
    ApiError(status_code: code, message: msg) ->
      "API error (" <> int.to_string(code) <> "): " <> msg
    NetworkError(reason: reason) -> "Network error: " <> reason
    ConfigError(reason: reason) -> "Configuration error: " <> reason
    DecodeError(reason: reason) -> "Decode error: " <> reason
    TimeoutError -> "Request timed out"
    RateLimitError(message: msg) -> "Rate limited: " <> msg
    UnknownError(reason: reason) -> "Unknown error: " <> reason
  }
}
