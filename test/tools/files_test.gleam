import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import llm/types.{type Tool, ToolCall, ToolFailure, ToolSuccess}
import tools/files

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn all_tools_defined_test() {
  let names = files.all() |> list.map(fn(t: Tool) { t.name })
  list.contains(names, "read_file") |> should.be_true
  list.contains(names, "write_file") |> should.be_true
  list.contains(names, "list_directory") |> should.be_true
}

pub fn read_file_tool_has_path_param_test() {
  let assert Ok(t) =
    list.find(files.all(), fn(t: Tool) { t.name == "read_file" })
  list.contains(t.required_params, "path") |> should.be_true
}

pub fn write_file_tool_has_required_params_test() {
  let assert Ok(t) =
    list.find(files.all(), fn(t: Tool) { t.name == "write_file" })
  list.contains(t.required_params, "path") |> should.be_true
  list.contains(t.required_params, "content") |> should.be_true
}

pub fn list_directory_tool_has_path_param_test() {
  let assert Ok(t) =
    list.find(files.all(), fn(t: Tool) { t.name == "list_directory" })
  list.contains(t.required_params, "path") |> should.be_true
}

// ---------------------------------------------------------------------------
// read_file
// ---------------------------------------------------------------------------

pub fn read_file_nonexistent_returns_failure_test() {
  let call =
    ToolCall(
      id: "t1",
      name: "read_file",
      input_json: "{\"path\":\"/tmp/springdrift_test_nonexistent_xyz.txt\"}",
    )
  let result = files.execute(call, False)
  case result {
    ToolFailure(..) -> Nil
    ToolSuccess(..) -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// write_file
// ---------------------------------------------------------------------------

pub fn write_file_outside_cwd_returns_failure_test() {
  let call =
    ToolCall(
      id: "t2",
      name: "write_file",
      input_json: "{\"path\":\"/tmp/springdrift_test_outside_cwd.txt\",\"content\":\"hello\"}",
    )
  let result = files.execute(call, False)
  case result {
    ToolFailure(error: msg, ..) ->
      string.contains(msg, "outside") |> should.be_true
    ToolSuccess(..) -> should.fail()
  }
}

pub fn write_file_outside_cwd_with_write_anywhere_succeeds_test() {
  let call =
    ToolCall(
      id: "t3",
      name: "write_file",
      input_json: "{\"path\":\"/tmp/springdrift_test_write_anywhere.txt\",\"content\":\"test\"}",
    )
  let result = files.execute(call, True)
  case result {
    ToolSuccess(..) -> Nil
    ToolFailure(error: msg, ..) ->
      // Acceptable only if it's a real filesystem error, not our CWD check
      string.contains(msg, "outside") |> should.be_false
  }
}

// ---------------------------------------------------------------------------
// list_directory
// ---------------------------------------------------------------------------

pub fn list_directory_current_dir_returns_success_test() {
  let call =
    ToolCall(id: "t4", name: "list_directory", input_json: "{\"path\":\".\"}")
  let result = files.execute(call, False)
  case result {
    ToolSuccess(..) -> Nil
    ToolFailure(..) -> should.fail()
  }
}
