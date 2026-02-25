import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/string
import llm/tool
import llm/types.{
  type Tool, type ToolCall, type ToolResult, ToolFailure, ToolSuccess,
}

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn all() -> List(Tool) {
  [calculator_tool(), date_tool(), human_input_tool()]
}

pub fn human_input_tool() -> Tool {
  tool.new("request_human_input")
  |> tool.with_description(
    "Ask the human a clarifying question and wait for their response before continuing",
  )
  |> tool.add_string_param("question", "The question to ask the human", True)
  |> tool.build()
}

pub fn calculator_tool() -> Tool {
  tool.new("calculator")
  |> tool.with_description(
    "Performs basic arithmetic: add, subtract, multiply, or divide two numbers",
  )
  |> tool.add_number_param("a", "The left-hand operand", True)
  |> tool.add_enum_param(
    "operator",
    "Arithmetic operator",
    ["+", "-", "*", "/"],
    True,
  )
  |> tool.add_number_param("b", "The right-hand operand", True)
  |> tool.build()
}

pub fn date_tool() -> Tool {
  tool.new("get_today_date")
  |> tool.with_description(
    "Returns today's date as an ISO 8601 string (YYYY-MM-DD)",
  )
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

pub fn execute(call: ToolCall) -> ToolResult {
  case call.name {
    "calculator" -> run_calculator(call)
    "get_today_date" -> ToolSuccess(tool_use_id: call.id, content: today_iso())
    _ -> ToolFailure(tool_use_id: call.id, error: "Unknown tool: " <> call.name)
  }
}

// ---------------------------------------------------------------------------
// Calculator
// ---------------------------------------------------------------------------

fn number_decoder() -> decode.Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

fn run_calculator(call: ToolCall) -> ToolResult {
  let decoder = {
    use a <- decode.field("a", number_decoder())
    use operator <- decode.field("operator", decode.string)
    use b <- decode.field("b", number_decoder())
    decode.success(#(a, operator, b))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Invalid calculator input")
    Ok(#(a, op, b)) ->
      case op {
        "+" -> ok_result(call.id, a +. b)
        "-" -> ok_result(call.id, a -. b)
        "*" -> ok_result(call.id, a *. b)
        "/" ->
          case b == 0.0 {
            True -> ToolFailure(tool_use_id: call.id, error: "Division by zero")
            False -> ok_result(call.id, a /. b)
          }
        _ ->
          ToolFailure(tool_use_id: call.id, error: "Unknown operator: " <> op)
      }
  }
}

fn ok_result(id: String, value: Float) -> ToolResult {
  ToolSuccess(tool_use_id: id, content: float.to_string(value))
}

// ---------------------------------------------------------------------------
// Date FFI + formatter
// ---------------------------------------------------------------------------

@external(erlang, "erlang", "date")
fn erlang_date() -> #(Int, Int, Int)

fn today_iso() -> String {
  let #(y, m, d) = erlang_date()
  int.to_string(y)
  <> "-"
  <> string.pad_start(int.to_string(m), 2, "0")
  <> "-"
  <> string.pad_start(int.to_string(d), 2, "0")
}
