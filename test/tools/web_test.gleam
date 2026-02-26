import gleam/list
import gleeunit
import gleeunit/should
import llm/types.{ToolCall, ToolFailure}
import tools/web

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn fetch_url_tool_defined_test() {
  let tools = web.all()
  tools |> should.not_equal([])
}

pub fn fetch_url_tool_has_url_param_test() {
  let tools = web.all()
  let assert [t, ..] = tools
  t.name |> should.equal("fetch_url")
  list.contains(t.required_params, "url") |> should.be_true
}

// ---------------------------------------------------------------------------
// URL validation
// ---------------------------------------------------------------------------

pub fn fetch_url_non_http_scheme_returns_failure_test() {
  let call =
    ToolCall(
      id: "w1",
      name: "fetch_url",
      input_json: "{\"url\":\"ftp://example.com/file\"}",
    )
  let result = web.execute(call)
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}

pub fn fetch_url_file_scheme_returns_failure_test() {
  let call =
    ToolCall(
      id: "w2",
      name: "fetch_url",
      input_json: "{\"url\":\"file:///etc/passwd\"}",
    )
  let result = web.execute(call)
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}

pub fn fetch_url_missing_input_returns_failure_test() {
  let call = ToolCall(id: "w3", name: "fetch_url", input_json: "{}")
  let result = web.execute(call)
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}
