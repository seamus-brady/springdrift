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

/// Human-readable description of an LlmError (for logs and diagnostics)
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

/// User-facing error message shown in the chat window.
/// Explains what went wrong and what the user can do about it.
pub fn user_facing_error_message(error: LlmError) -> String {
  case error {
    TimeoutError ->
      "Sorry, that request took too long to complete. This can happen with complex tasks or during peak API usage. Please try again, or try breaking the task into smaller steps."
    RateLimitError(message: _) ->
      "Sorry, the API rate limit was reached. Please wait a moment and try again."
    NetworkError(reason: _) ->
      "Sorry, there was a network error communicating with the AI service. Please check your connection and try again."
    ApiError(status_code: 529, message: _) ->
      "Sorry, the AI service is currently overloaded. Please try again in a moment."
    ApiError(status_code: code, message: msg) ->
      "Sorry, the AI service returned an error (HTTP "
      <> int.to_string(code)
      <> "). "
      <> msg
    DecodeError(reason: _) ->
      "Sorry, there was an unexpected response from the AI service. Please try again."
    ConfigError(reason: reason) ->
      "Sorry, there is a configuration problem: " <> reason
    UnknownError(reason: "Agent loop: maximum turns reached") ->
      "Sorry, I reached the maximum number of steps for this task. Try asking for a simpler version, or increase the --max-turns setting."
    UnknownError(reason: "Agent loop: too many consecutive tool errors") ->
      "Sorry, I encountered repeated errors using tools and stopped to avoid a loop. Check springdrift.log for details. You can try again, restart the sandbox with `r` in the Sandbox tab, or rephrase the request."
    UnknownError(reason: "LLM worker crashed unexpectedly") ->
      "Sorry, an internal error occurred. Please try again."
    UnknownError(reason: reason) -> "Sorry, an error occurred: " <> reason
  }
}
