import gleam/list
import gleam/option.{None}
import gleeunit
import gleeunit/should
import llm/types.{ToolCall, ToolFailure}
import tools/sandbox_mgmt

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn all_tools_defined_test() {
  let tools = sandbox_mgmt.all()
  list.length(tools) |> should.equal(5)
}

pub fn sandbox_status_tool_has_no_required_params_test() {
  let tools = sandbox_mgmt.all()
  let assert Ok(t) = list.find(tools, fn(t) { t.name == "sandbox_status" })
  t.required_params |> should.equal([])
}

pub fn sandbox_logs_has_optional_lines_param_test() {
  let tools = sandbox_mgmt.all()
  let assert Ok(t) = list.find(tools, fn(t) { t.name == "sandbox_logs" })
  // lines is optional (not in required_params)
  list.contains(t.required_params, "lines") |> should.be_false
  // but it is defined as a parameter
  list.any(t.parameters, fn(p) { p.0 == "lines" }) |> should.be_true
}

pub fn restart_sandbox_tool_has_no_required_params_test() {
  let tools = sandbox_mgmt.all()
  let assert Ok(t) = list.find(tools, fn(t) { t.name == "restart_sandbox" })
  t.required_params |> should.equal([])
}

// ---------------------------------------------------------------------------
// None sandbox → ToolFailure
// ---------------------------------------------------------------------------

pub fn sandbox_status_without_sandbox_returns_failure_test() {
  let call = ToolCall(id: "t1", name: "sandbox_status", input_json: "{}")
  case sandbox_mgmt.execute(call, None) {
    ToolFailure(error: msg, ..) ->
      msg |> should.equal("Docker sandbox not available")
    _ -> should.fail()
  }
}

pub fn sandbox_logs_without_sandbox_returns_failure_test() {
  let call = ToolCall(id: "t2", name: "sandbox_logs", input_json: "{}")
  case sandbox_mgmt.execute(call, None) {
    ToolFailure(error: msg, ..) ->
      msg |> should.equal("Docker sandbox not available")
    _ -> should.fail()
  }
}

pub fn restart_sandbox_without_sandbox_returns_failure_test() {
  let call = ToolCall(id: "t3", name: "restart_sandbox", input_json: "{}")
  case sandbox_mgmt.execute(call, None) {
    ToolFailure(error: msg, ..) ->
      msg |> should.equal("Docker sandbox not available")
    _ -> should.fail()
  }
}

pub fn sandbox_logs_with_lines_param_without_sandbox_returns_failure_test() {
  let call =
    ToolCall(id: "t4", name: "sandbox_logs", input_json: "{\"lines\":100}")
  case sandbox_mgmt.execute(call, None) {
    ToolFailure(error: msg, ..) ->
      msg |> should.equal("Docker sandbox not available")
    _ -> should.fail()
  }
}

pub fn copy_from_sandbox_tool_has_required_container_path_test() {
  let tools = sandbox_mgmt.all()
  let assert Ok(t) = list.find(tools, fn(t) { t.name == "copy_from_sandbox" })
  list.contains(t.required_params, "container_path") |> should.be_true
}

pub fn copy_to_sandbox_tool_has_required_host_path_test() {
  let tools = sandbox_mgmt.all()
  let assert Ok(t) = list.find(tools, fn(t) { t.name == "copy_to_sandbox" })
  list.contains(t.required_params, "host_path") |> should.be_true
  list.contains(t.required_params, "container_dest") |> should.be_false
}

pub fn copy_from_sandbox_without_sandbox_returns_failure_test() {
  let call =
    ToolCall(
      id: "t5",
      name: "copy_from_sandbox",
      input_json: "{\"container_path\":\"/tmp/out.txt\"}",
    )
  case sandbox_mgmt.execute(call, None) {
    ToolFailure(error: msg, ..) ->
      msg |> should.equal("Docker sandbox not available")
    _ -> should.fail()
  }
}

pub fn copy_to_sandbox_without_sandbox_returns_failure_test() {
  let call =
    ToolCall(
      id: "t6",
      name: "copy_to_sandbox",
      input_json: "{\"host_path\":\"data/input.csv\"}",
    )
  case sandbox_mgmt.execute(call, None) {
    ToolFailure(error: msg, ..) ->
      msg |> should.equal("Docker sandbox not available")
    _ -> should.fail()
  }
}
