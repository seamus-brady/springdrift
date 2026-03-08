/// Web tools: fetch_url, web_search.
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import llm/tool
import llm/types.{
  type Tool, type ToolCall, type ToolResult, ToolFailure, ToolSuccess,
}
import slog

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn all() -> List(Tool) {
  [fetch_url_tool(), web_search_tool()]
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

fn web_search_tool() -> Tool {
  tool.new("web_search")
  |> tool.with_description(
    "Search the web for current information. Returns a list of result titles, URLs, and snippets. Use fetch_url to retrieve the full page content of any result.",
  )
  |> tool.add_string_param("query", "The search query", True)
  |> tool.add_integer_param(
    "max_results",
    "Maximum number of results to return (1-10, default 5)",
    False,
  )
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

pub fn execute(call: ToolCall) -> ToolResult {
  slog.debug("web", "execute", "tool=" <> call.name, option.None)
  case call.name {
    "fetch_url" -> run_fetch_url(call)
    "web_search" -> run_web_search(call)
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

// ---------------------------------------------------------------------------
// web_search
// ---------------------------------------------------------------------------

fn run_web_search(call: ToolCall) -> ToolResult {
  let decoder = {
    use query <- decode.field("query", decode.string)
    use max <- decode.optional_field("max_results", 5, decode.int)
    decode.success(#(query, max))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid web_search input: missing query",
      )
    Ok(#(query, max_results)) -> {
      let clamped = int.min(10, int.max(1, max_results))
      let url = "https://html.duckduckgo.com/html/?q=" <> uri_encode(query)
      case fetch_url_ffi(url) {
        Error(reason) ->
          ToolFailure(tool_use_id: call.id, error: "web_search: " <> reason)
        Ok(body) -> {
          let results = parse_ddg_html(body, clamped)
          ToolSuccess(tool_use_id: call.id, content: results)
        }
      }
    }
  }
}

@external(erlang, "springdrift_ffi", "uri_encode")
fn uri_encode(text: String) -> String

/// Parse DuckDuckGo HTML results into a formatted string.
/// Extracts result titles, URLs, and snippets from the HTML response.
fn parse_ddg_html(html: String, max_results: Int) -> String {
  let results = extract_ddg_results(html)
  let limited = list.take(results, max_results)
  case limited {
    [] -> "No results found."
    _ ->
      list.index_map(limited, fn(r, i) {
        int.to_string(i + 1)
        <> ". "
        <> r.title
        <> "\n   "
        <> r.url
        <> "\n   "
        <> r.snippet
      })
      |> string.join("\n\n")
  }
}

pub type SearchResult {
  SearchResult(title: String, url: String, snippet: String)
}

/// Extract search results from DuckDuckGo HTML response.
/// Parses the result links and snippets from the page.
fn extract_ddg_results(html: String) -> List(SearchResult) {
  // DuckDuckGo HTML results have class="result__a" for links
  // and class="result__snippet" for snippets
  extract_ddg_results_ffi(html)
}

@external(erlang, "springdrift_ffi", "extract_ddg_results")
fn extract_ddg_results_ffi(html: String) -> List(SearchResult)
