import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import llm/response
import llm/types.{
  ApiError, EndTurn, LlmResponse, MaxTokens, RateLimitError, TextContent,
  TimeoutError, ToolUseContent, ToolUseRequested, Usage,
}

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn text_joins_content_blocks_test() {
  let resp =
    LlmResponse(
      id: "id1",
      content: [TextContent(text: "Hello "), TextContent(text: "world")],
      model: "test",
      stop_reason: Some(EndTurn),
      usage: Usage(input_tokens: 10, output_tokens: 10),
    )
  response.text(resp) |> should.equal("Hello world")
}

pub fn needs_tool_execution_false_for_text_test() {
  let resp =
    LlmResponse(
      id: "id1",
      content: [TextContent(text: "hello")],
      model: "test",
      stop_reason: Some(EndTurn),
      usage: Usage(input_tokens: 10, output_tokens: 10),
    )
  response.needs_tool_execution(resp) |> should.equal(False)
}

pub fn needs_tool_execution_true_for_tool_call_test() {
  let resp =
    LlmResponse(
      id: "id1",
      content: [ToolUseContent(id: "id1", name: "tool1", input_json: "{}")],
      model: "test",
      stop_reason: Some(ToolUseRequested),
      usage: Usage(input_tokens: 10, output_tokens: 10),
    )
  response.needs_tool_execution(resp) |> should.equal(True)
}

pub fn tool_calls_extracts_all_test() {
  let resp =
    LlmResponse(
      id: "id1",
      content: [
        ToolUseContent(id: "call1", name: "tool_a", input_json: "{}"),
        TextContent(text: "some text"),
        ToolUseContent(id: "call2", name: "tool_b", input_json: "{\"x\":1}"),
      ],
      model: "test",
      stop_reason: Some(ToolUseRequested),
      usage: Usage(input_tokens: 10, output_tokens: 10),
    )
  let calls = response.tool_calls(resp)
  list.length(calls) |> should.equal(2)
  let assert [first, _] = calls
  first.name |> should.equal("tool_a")
  first.id |> should.equal("call1")
}

pub fn was_truncated_test() {
  let resp =
    LlmResponse(
      id: "id1",
      content: [TextContent(text: "truncated")],
      model: "test",
      stop_reason: Some(MaxTokens),
      usage: Usage(input_tokens: 10, output_tokens: 10),
    )
  response.was_truncated(resp) |> should.equal(True)
}

pub fn total_tokens_sums_usage_test() {
  let resp =
    LlmResponse(
      id: "id1",
      content: [],
      model: "test",
      stop_reason: None,
      usage: Usage(input_tokens: 10, output_tokens: 10),
    )
  response.total_tokens(resp) |> should.equal(20)
}

pub fn error_message_api_error_test() {
  let err = ApiError(status_code: 429, message: "Too many requests")
  response.error_message(err) |> should.equal("API error (429): Too many requests")
}

pub fn error_message_timeout_test() {
  response.error_message(TimeoutError) |> should.equal("Request timed out")
}

pub fn error_message_rate_limit_test() {
  let err = RateLimitError(message: "Too fast")
  response.error_message(err) |> should.equal("Rate limited: Too fast")
}
