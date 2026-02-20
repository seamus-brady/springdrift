import gleam/list
import gleam/option.{Some}
import gleeunit
import gleeunit/should
import llm/adapters/mock
import llm/request
import llm/response
import llm/types.{ToolUseRequested}

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn text_provider_returns_text_test() {
  let p = mock.provider_with_text("Hello!")
  let req = request.new("test", 100) |> request.with_user_message("Hi")
  let result = p.chat(req)
  result |> should.be_ok
  let assert Ok(resp) = result
  response.text(resp) |> should.equal("Hello!")
}

pub fn error_provider_returns_error_test() {
  let p = mock.provider_with_error("something broke")
  let req = request.new("test", 100)
  p.chat(req) |> should.be_error
}

pub fn handler_receives_request_model_test() {
  let p =
    mock.provider_with_handler(fn(req) { Ok(mock.text_response(req.model)) })
  let req = request.new("my-model", 100) |> request.with_user_message("Hi")
  let assert Ok(resp) = p.chat(req)
  response.text(resp) |> should.equal("my-model")
}

pub fn handler_sequential_responses_test() {
  let p =
    mock.provider_with_handler(fn(req) {
      case list.length(req.messages) {
        1 -> Ok(mock.text_response("first response"))
        _ -> Ok(mock.text_response("second response"))
      }
    })

  let req1 = request.new("test", 100) |> request.with_user_message("First call")
  let assert Ok(resp1) = p.chat(req1)
  response.text(resp1) |> should.equal("first response")

  let req2 =
    request.new("test", 100)
    |> request.with_user_message("First message")
    |> request.with_assistant_message("A reply")
    |> request.with_user_message("Second message")
  let assert Ok(resp2) = p.chat(req2)
  response.text(resp2) |> should.equal("second response")
}

pub fn tool_call_response_sets_stop_reason_test() {
  let resp = mock.tool_call_response("my_tool", "{}", "call_1")
  resp.stop_reason |> should.equal(Some(ToolUseRequested))
}

pub fn provider_name_is_mock_test() {
  let p = mock.provider_with_text("hi")
  p.name |> should.equal("mock")
}
