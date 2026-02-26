import gleam/list
import gleam/option.{None}
import gleeunit
import gleeunit/should
import llm/types.{ToolCall, ToolFailure}
import tools/shell

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn run_shell_tool_defined_test() {
  let tools = shell.all()
  tools |> should.not_equal([])
}

pub fn run_shell_tool_has_command_param_test() {
  let assert [t, ..] = shell.all()
  t.name |> should.equal("run_shell")
  list.contains(t.required_params, "command") |> should.be_true
}

// ---------------------------------------------------------------------------
// No sandbox → ToolFailure
// ---------------------------------------------------------------------------

pub fn execute_without_sandbox_returns_failure_test() {
  let call =
    ToolCall(
      id: "s1",
      name: "run_shell",
      input_json: "{\"command\":\"echo hello\"}",
    )
  let result = shell.execute(call, None)
  case result {
    ToolFailure(error: msg, ..) ->
      msg |> should.equal("Docker sandbox not available")
    _ -> should.fail()
  }
}
