import gleam/option
import gleeunit/should
import llm/adapters/scripted
import llm/provider
import llm/request
import llm/response
import llm/types.{ApiError, ToolUseContent, ToolUseRequested, UnknownError}

fn make_request() {
  request.new("test-model", 256)
  |> request.with_user_message("hello")
}

pub fn single_text_response_test() {
  let script = scripted.new([scripted.ok_text("hello back")])
  let prov = scripted.provider(script)

  let assert Ok(resp) = prov.chat(make_request())
  response.text(resp)
  |> should.equal("hello back")
}

pub fn multiple_responses_pop_in_order_test() {
  let script =
    scripted.new([
      scripted.ok_text("first"),
      scripted.ok_text("second"),
      scripted.ok_text("third"),
    ])
  let prov = scripted.provider(script)

  let assert Ok(r1) = prov.chat(make_request())
  response.text(r1) |> should.equal("first")

  let assert Ok(r2) = prov.chat(make_request())
  response.text(r2) |> should.equal("second")

  let assert Ok(r3) = prov.chat(make_request())
  response.text(r3) |> should.equal("third")
}

pub fn exhausted_script_returns_error_test() {
  let script = scripted.new([scripted.ok_text("only one")])
  let prov = scripted.provider(script)

  // Pop the single response
  let assert Ok(_) = prov.chat(make_request())

  // Next call should fail
  let result = prov.chat(make_request())
  result
  |> should.equal(Error(UnknownError(reason: "Scripted provider exhausted")))
}

pub fn tool_call_response_test() {
  let script =
    scripted.new([
      scripted.ok_tool_call("calculator", "{\"expression\":\"1+1\"}", "tool_1"),
    ])
  let prov = scripted.provider(script)

  let assert Ok(resp) = prov.chat(make_request())

  resp.stop_reason
  |> should.equal(option.Some(ToolUseRequested))

  let assert [ToolUseContent(id: id, name: name, input_json: input)] =
    resp.content
  id |> should.equal("tool_1")
  name |> should.equal("calculator")
  input |> should.equal("{\"expression\":\"1+1\"}")
}

pub fn error_response_test() {
  let error = ApiError(status_code: 500, message: "internal server error")
  let script = scripted.new([scripted.err(error)])
  let prov = scripted.provider(script)

  let result = prov.chat(make_request())
  result
  |> should.equal(
    Error(ApiError(status_code: 500, message: "internal server error")),
  )
}

pub fn mixed_responses_pop_in_order_test() {
  let script =
    scripted.new([
      scripted.ok_text("text reply"),
      scripted.ok_tool_call(
        "fetch_url",
        "{\"url\":\"https://example.com\"}",
        "t2",
      ),
      scripted.err(UnknownError(reason: "boom")),
    ])
  let prov = scripted.provider(script)

  // First: text
  let assert Ok(r1) = prov.chat(make_request())
  response.text(r1) |> should.equal("text reply")

  // Second: tool call
  let assert Ok(r2) = prov.chat(make_request())
  let assert [ToolUseContent(id: _, name: name, input_json: _)] = r2.content
  name |> should.equal("fetch_url")

  // Third: error
  let result = prov.chat(make_request())
  result |> should.equal(Error(UnknownError(reason: "boom")))
}

pub fn provider_name_is_scripted_test() {
  let script = scripted.new([])
  let prov = scripted.provider(script)

  provider.name(prov) |> should.equal("scripted")
}
