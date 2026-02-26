/// Web tool: fetch_url.
import gleam/dynamic/decode
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
  [fetch_url_tool()]
}

fn fetch_url_tool() -> Tool {
  tool.new("fetch_url")
  |> tool.with_description(
    "Fetch the contents of a URL via HTTP GET. Returns the response body (truncated to 50 KB).",
  )
  |> tool.add_string_param(
    "url",
    "The URL to fetch (must start with http:// or https://)",
    True,
  )
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

pub fn execute(call: ToolCall) -> ToolResult {
  case call.name {
    "fetch_url" -> run_fetch_url(call)
    _ -> ToolFailure(tool_use_id: call.id, error: "Unknown tool: " <> call.name)
  }
}

// ---------------------------------------------------------------------------
// fetch_url
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "fetch_url")
fn fetch_url_ffi(url: String) -> Result(String, String)

fn run_fetch_url(call: ToolCall) -> ToolResult {
  let decoder = {
    use url <- decode.field("url", decode.string)
    decode.success(url)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid fetch_url input: missing url",
      )
    Ok(url) ->
      case
        string.starts_with(url, "http://")
        || string.starts_with(url, "https://")
      {
        False ->
          ToolFailure(
            tool_use_id: call.id,
            error: "fetch_url: URL must start with http:// or https://",
          )
        True ->
          case fetch_url_ffi(url) {
            Error(reason) ->
              ToolFailure(tool_use_id: call.id, error: "fetch_url: " <> reason)
            Ok(body) -> ToolSuccess(tool_use_id: call.id, content: body)
          }
      }
  }
}
