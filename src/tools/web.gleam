/// Web tools: fetch_url, web_search, exa_search, tavily_search, firecrawl_extract.
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
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
  [
    fetch_url_tool(),
    web_search_tool(),
    exa_search_tool(),
    tavily_search_tool(),
    firecrawl_extract_tool(),
  ]
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

fn exa_search_tool() -> Tool {
  tool.new("exa_search")
  |> tool.with_description(
    "Semantic web search using neural embeddings. Use when the query is conceptual, exploratory, or when you need to discover relevant sources by meaning rather than exact keywords. Returns up to 10 results with text snippets and source URLs.",
  )
  |> tool.add_string_param(
    "query",
    "The search query. Write it as a natural language description of what you are looking for, not as keywords.",
    True,
  )
  |> tool.build()
}

fn tavily_search_tool() -> Tool {
  tool.new("tavily_search")
  |> tool.with_description(
    "Fast factual web search optimised for LLM consumption. Use for quick lookups: current prices, recent news, dates, status of something, or any specific factual question. Results include a direct answer and ranked source snippets.",
  )
  |> tool.add_string_param(
    "query",
    "The factual question or lookup. Specific questions work better than broad topics.",
    True,
  )
  |> tool.build()
}

fn firecrawl_extract_tool() -> Tool {
  tool.new("firecrawl_extract")
  |> tool.with_description(
    "Deep extraction of full page content from a specific URL. Returns clean markdown with JavaScript-rendered content, stripping navigation and boilerplate. Use ONLY after a search has returned a URL that warrants reading in full.",
  )
  |> tool.add_string_param(
    "url",
    "The full URL to extract. Must be https://. Only call this with URLs returned from a prior search step.",
    True,
  )
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

/// Whether a tool name belongs to the web tool set.
pub fn is_web_tool(name: String) -> Bool {
  name == "fetch_url"
  || name == "web_search"
  || name == "exa_search"
  || name == "tavily_search"
  || name == "firecrawl_extract"
}

pub fn execute(call: ToolCall) -> ToolResult {
  slog.debug("web", "execute", "tool=" <> call.name, option.None)
  case call.name {
    "fetch_url" -> run_fetch_url(call)
    "web_search" -> run_web_search(call)
    "exa_search" -> run_exa_search(call)
    "tavily_search" -> run_tavily_search(call)
    "firecrawl_extract" -> run_firecrawl_extract(call)
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

@external(erlang, "springdrift_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

// ---------------------------------------------------------------------------
// exa_search
// ---------------------------------------------------------------------------

fn run_exa_search(call: ToolCall) -> ToolResult {
  let decoder = {
    use query <- decode.field("query", decode.string)
    decode.success(query)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid exa_search input: missing query",
      )
    Ok(query) ->
      case exa_search(query, option.None) {
        Error(msg) -> ToolFailure(tool_use_id: call.id, error: msg)
        Ok(content) -> ToolSuccess(tool_use_id: call.id, content:)
      }
  }
}

pub fn exa_search(
  query: String,
  cycle_id: Option(String),
) -> Result(String, String) {
  use key <- result.try(
    get_env("EXA_API_KEY")
    |> result.replace_error(
      "EXA_API_KEY is not set. Add it to your environment to use exa_search.",
    ),
  )

  let body =
    json.object([
      #("query", json.string(query)),
      #("numResults", json.int(10)),
      #(
        "contents",
        json.object([
          #("text", json.bool(True)),
          #("highlights", json.bool(True)),
        ]),
      ),
    ])
    |> json.to_string

  let req =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_host("api.exa.ai")
    |> request.set_path("/search")
    |> request.set_scheme(http.Https)
    |> request.set_body(body)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("x-api-key", key)

  slog.debug("tools/web", "exa_search", "query: " <> query, cycle_id)

  case httpc.send(req) {
    Error(e) -> {
      let msg = "exa_search HTTP error: " <> string.inspect(e)
      slog.log_error("tools/web", "exa_search", msg, cycle_id)
      Error(msg)
    }
    Ok(resp) ->
      case resp.status {
        200 -> parse_exa_response(resp.body)
        status -> {
          let msg =
            "exa_search returned status "
            <> string.inspect(status)
            <> ": "
            <> resp.body
          slog.log_error("tools/web", "exa_search", msg, cycle_id)
          Error(msg)
        }
      }
  }
}

fn parse_exa_response(body: String) -> Result(String, String) {
  let result_decoder = {
    use title <- decode.field("title", decode.optional(decode.string))
    use url <- decode.field("url", decode.string)
    use text <- decode.field("text", decode.optional(decode.string))
    use highlights <- decode.field(
      "highlights",
      decode.optional(decode.list(decode.string)),
    )
    decode.success(#(title, url, text, highlights))
  }

  let results_decoder = {
    use results <- decode.field("results", decode.list(result_decoder))
    decode.success(results)
  }

  case json.parse(body, results_decoder) {
    Error(_) -> Error("exa_search: failed to parse response: " <> body)
    Ok(results) -> {
      let formatted =
        results
        |> list.index_map(fn(item, i) {
          let #(title, url, text, highlights) = item
          let title_str = option.unwrap(title, "Untitled")
          let snippet = case highlights {
            Some([first, ..]) -> first
            Some([]) | None ->
              option.unwrap(text, "")
              |> string.slice(0, 400)
          }
          string.join(
            [
              string.inspect(i + 1) <> ". " <> title_str,
              "   URL: " <> url,
              "   " <> snippet,
            ],
            "\n",
          )
        })
        |> string.join("\n\n")

      Ok("Exa search results:\n\n" <> formatted)
    }
  }
}

// ---------------------------------------------------------------------------
// tavily_search
// ---------------------------------------------------------------------------

fn run_tavily_search(call: ToolCall) -> ToolResult {
  let decoder = {
    use query <- decode.field("query", decode.string)
    decode.success(query)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid tavily_search input: missing query",
      )
    Ok(query) ->
      case tavily_search(query, option.None) {
        Error(msg) -> ToolFailure(tool_use_id: call.id, error: msg)
        Ok(content) -> ToolSuccess(tool_use_id: call.id, content:)
      }
  }
}

pub fn tavily_search(
  query: String,
  cycle_id: Option(String),
) -> Result(String, String) {
  use key <- result.try(
    get_env("TAVILY_API_KEY")
    |> result.replace_error(
      "TAVILY_API_KEY is not set. Add it to your environment to use tavily_search.",
    ),
  )

  let body =
    json.object([
      #("query", json.string(query)),
      #("search_depth", json.string("basic")),
      #("include_answer", json.bool(True)),
      #("max_results", json.int(6)),
    ])
    |> json.to_string

  let req =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_host("api.tavily.com")
    |> request.set_path("/search")
    |> request.set_scheme(http.Https)
    |> request.set_body(body)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("authorization", "Bearer " <> key)

  slog.debug("tools/web", "tavily_search", "query: " <> query, cycle_id)

  case httpc.send(req) {
    Error(e) -> {
      let msg = "tavily_search HTTP error: " <> string.inspect(e)
      slog.log_error("tools/web", "tavily_search", msg, cycle_id)
      Error(msg)
    }
    Ok(resp) ->
      case resp.status {
        200 -> parse_tavily_response(resp.body)
        status -> {
          let msg =
            "tavily_search returned status "
            <> string.inspect(status)
            <> ": "
            <> resp.body
          slog.log_error("tools/web", "tavily_search", msg, cycle_id)
          Error(msg)
        }
      }
  }
}

fn parse_tavily_response(body: String) -> Result(String, String) {
  let result_decoder = {
    use title <- decode.field("title", decode.string)
    use url <- decode.field("url", decode.string)
    use content <- decode.field("content", decode.string)
    use score <- decode.field("score", decode.float)
    decode.success(#(title, url, content, score))
  }

  let response_decoder = {
    use answer <- decode.field("answer", decode.optional(decode.string))
    use results <- decode.field("results", decode.list(result_decoder))
    decode.success(#(answer, results))
  }

  case json.parse(body, response_decoder) {
    Error(_) -> Error("tavily_search: failed to parse response: " <> body)
    Ok(#(answer, results)) -> {
      let answer_section = case answer {
        Some(a) -> "Direct answer: " <> a <> "\n\n"
        None -> ""
      }

      let formatted =
        results
        |> list.index_map(fn(item, i) {
          let #(title, url, content, _score) = item
          string.join(
            [
              string.inspect(i + 1) <> ". " <> title,
              "   URL: " <> url,
              "   " <> string.slice(content, 0, 500),
            ],
            "\n",
          )
        })
        |> string.join("\n\n")

      Ok("Tavily search results:\n\n" <> answer_section <> formatted)
    }
  }
}

// ---------------------------------------------------------------------------
// firecrawl_extract
// ---------------------------------------------------------------------------

fn run_firecrawl_extract(call: ToolCall) -> ToolResult {
  let decoder = {
    use url <- decode.field("url", decode.string)
    decode.success(url)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid firecrawl_extract input: missing url",
      )
    Ok(url) ->
      case firecrawl_extract(url, option.None) {
        Error(msg) -> ToolFailure(tool_use_id: call.id, error: msg)
        Ok(content) -> ToolSuccess(tool_use_id: call.id, content:)
      }
  }
}

pub fn firecrawl_extract(
  url: String,
  cycle_id: Option(String),
) -> Result(String, String) {
  use key <- result.try(
    get_env("FIRECRAWL_API_KEY")
    |> result.replace_error(
      "FIRECRAWL_API_KEY is not set. Add it to your environment to use firecrawl_extract.",
    ),
  )

  let body =
    json.object([
      #("url", json.string(url)),
      #("formats", json.array(["markdown"], json.string)),
    ])
    |> json.to_string

  let req =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_host("api.firecrawl.dev")
    |> request.set_path("/v1/scrape")
    |> request.set_scheme(http.Https)
    |> request.set_body(body)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("authorization", "Bearer " <> key)

  slog.debug("tools/web", "firecrawl_extract", "url: " <> url, cycle_id)

  case httpc.send(req) {
    Error(e) -> {
      let msg = "firecrawl_extract HTTP error: " <> string.inspect(e)
      slog.log_error("tools/web", "firecrawl_extract", msg, cycle_id)
      Error(msg)
    }
    Ok(resp) ->
      case resp.status {
        200 -> parse_firecrawl_response(resp.body, url)
        429 -> Error("firecrawl_extract: rate limited. Retry after a moment.")
        status -> {
          let msg =
            "firecrawl_extract returned status "
            <> string.inspect(status)
            <> ": "
            <> resp.body
          slog.log_error("tools/web", "firecrawl_extract", msg, cycle_id)
          Error(msg)
        }
      }
  }
}

/// Parse Firecrawl v1 response envelope: { success, data: { markdown, metadata: { title } } }
fn parse_firecrawl_response(body: String, url: String) -> Result(String, String) {
  let data_decoder = {
    use markdown <- decode.field("markdown", decode.optional(decode.string))
    use title <- decode.field("metadata", {
      use title <- decode.field("title", decode.optional(decode.string))
      decode.success(title)
    })
    decode.success(#(markdown, title))
  }

  let response_decoder = {
    use success <- decode.field("success", decode.bool)
    use data <- decode.field("data", data_decoder)
    decode.success(#(success, data))
  }

  case json.parse(body, response_decoder) {
    Error(_) -> Error("firecrawl_extract: failed to parse response: " <> body)
    Ok(#(False, _)) ->
      Error("firecrawl_extract: API returned success=false for " <> url)
    Ok(#(True, #(markdown, title))) -> {
      let title_str = option.unwrap(title, url)
      let content = option.unwrap(markdown, "")
      // Cap at ~50KB to stay within context limits
      let truncated = case string.length(content) > 50_000 {
        True ->
          string.slice(content, 0, 50_000) <> "\n\n[Content truncated at 50KB]"
        False -> content
      }
      Ok("# " <> title_str <> "\nSource: " <> url <> "\n\n" <> truncated)
    }
  }
}
