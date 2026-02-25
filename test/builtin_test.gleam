import gleam/int
import gleam/string
import gleeunit/should
import llm/types.{type ToolCall, ToolFailure, ToolSuccess}
import tools/builtin

fn make_call(id: String, name: String, input: String) -> ToolCall {
  types.ToolCall(id:, name:, input_json: input)
}

// ---------------------------------------------------------------------------
// get_today_date — ISO 8601 format (YYYY-MM-DD, zero-padded month and day)
// ---------------------------------------------------------------------------

pub fn get_today_date_returns_iso8601_format_test() {
  let result = builtin.execute(make_call("id1", "get_today_date", "{}"))
  let assert ToolSuccess(tool_use_id: "id1", content: date_str) = result
  // Must be exactly 10 characters: YYYY-MM-DD
  string.length(date_str) |> should.equal(10)
  // Hyphens at positions 4 and 7
  string.slice(date_str, 4, 1) |> should.equal("-")
  string.slice(date_str, 7, 1) |> should.equal("-")
}

pub fn get_today_date_parts_have_correct_lengths_test() {
  let result = builtin.execute(make_call("id2", "get_today_date", "{}"))
  let assert ToolSuccess(content: date_str, ..) = result
  let parts = string.split(date_str, "-")
  let assert [year, month, day] = parts
  string.length(year) |> should.equal(4)
  string.length(month) |> should.equal(2)
  string.length(day) |> should.equal(2)
}

pub fn get_today_date_month_and_day_are_valid_test() {
  let result = builtin.execute(make_call("id3", "get_today_date", "{}"))
  let assert ToolSuccess(content: date_str, ..) = result
  let parts = string.split(date_str, "-")
  let assert [_, month_str, day_str] = parts
  let assert Ok(month) = int.parse(month_str)
  let assert Ok(day) = int.parse(day_str)
  { month >= 1 && month <= 12 } |> should.be_true
  { day >= 1 && day <= 31 } |> should.be_true
}

// ---------------------------------------------------------------------------
// calculator
// ---------------------------------------------------------------------------

pub fn calculator_add_test() {
  let result =
    builtin.execute(make_call(
      "c1",
      "calculator",
      "{\"a\":3.0,\"operator\":\"+\",\"b\":4.0}",
    ))
  result |> should.equal(ToolSuccess(tool_use_id: "c1", content: "7.0"))
}

pub fn calculator_subtract_test() {
  let result =
    builtin.execute(make_call(
      "c2",
      "calculator",
      "{\"a\":10.0,\"operator\":\"-\",\"b\":3.0}",
    ))
  result |> should.equal(ToolSuccess(tool_use_id: "c2", content: "7.0"))
}

pub fn calculator_multiply_test() {
  let result =
    builtin.execute(make_call(
      "c3",
      "calculator",
      "{\"a\":3.0,\"operator\":\"*\",\"b\":4.0}",
    ))
  result |> should.equal(ToolSuccess(tool_use_id: "c3", content: "12.0"))
}

pub fn calculator_divide_test() {
  let result =
    builtin.execute(make_call(
      "c4",
      "calculator",
      "{\"a\":10.0,\"operator\":\"/\",\"b\":2.0}",
    ))
  result |> should.equal(ToolSuccess(tool_use_id: "c4", content: "5.0"))
}

pub fn calculator_divide_by_zero_test() {
  let result =
    builtin.execute(make_call(
      "c5",
      "calculator",
      "{\"a\":5.0,\"operator\":\"/\",\"b\":0.0}",
    ))
  result
  |> should.equal(ToolFailure(tool_use_id: "c5", error: "Division by zero"))
}

pub fn calculator_int_operands_test() {
  let result =
    builtin.execute(make_call(
      "c6",
      "calculator",
      "{\"a\":6,\"operator\":\"+\",\"b\":4}",
    ))
  result |> should.equal(ToolSuccess(tool_use_id: "c6", content: "10.0"))
}

pub fn calculator_invalid_input_test() {
  let result =
    builtin.execute(make_call("c7", "calculator", "{\"bad\":\"input\"}"))
  result
  |> should.equal(ToolFailure(
    tool_use_id: "c7",
    error: "Invalid calculator input",
  ))
}

// ---------------------------------------------------------------------------
// unknown tool
// ---------------------------------------------------------------------------

pub fn unknown_tool_test() {
  let result = builtin.execute(make_call("u1", "nonexistent_tool", "{}"))
  result
  |> should.equal(ToolFailure(
    tool_use_id: "u1",
    error: "Unknown tool: nonexistent_tool",
  ))
}
