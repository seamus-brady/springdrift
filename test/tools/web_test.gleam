import gleam/list
import gleam/option
import gleam/string
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

// ---------------------------------------------------------------------------
// web_search
// ---------------------------------------------------------------------------

pub fn web_search_tool_defined_test() {
  let tools = web.all()
  let names = list.map(tools, fn(t) { t.name })
  list.contains(names, "web_search") |> should.be_true
}

pub fn web_search_missing_query_returns_failure_test() {
  let call = ToolCall(id: "s1", name: "web_search", input_json: "{}")
  let result = web.execute(call)
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Tool definitions — new tools
// ---------------------------------------------------------------------------

pub fn all_tools_count_test() {
  let tools = web.all()
  tools |> list.length |> should.equal(5)
}

pub fn exa_search_tool_defined_test() {
  let tools = web.all()
  let names = list.map(tools, fn(t) { t.name })
  list.contains(names, "exa_search") |> should.be_true
}

pub fn tavily_search_tool_defined_test() {
  let tools = web.all()
  let names = list.map(tools, fn(t) { t.name })
  list.contains(names, "tavily_search") |> should.be_true
}

pub fn firecrawl_extract_tool_defined_test() {
  let tools = web.all()
  let names = list.map(tools, fn(t) { t.name })
  list.contains(names, "firecrawl_extract") |> should.be_true
}

pub fn exa_search_has_query_param_test() {
  let tools = web.all()
  let assert Ok(t) = list.find(tools, fn(t) { t.name == "exa_search" })
  list.contains(t.required_params, "query") |> should.be_true
}

pub fn tavily_search_has_query_param_test() {
  let tools = web.all()
  let assert Ok(t) = list.find(tools, fn(t) { t.name == "tavily_search" })
  list.contains(t.required_params, "query") |> should.be_true
}

pub fn firecrawl_extract_has_url_param_test() {
  let tools = web.all()
  let assert Ok(t) = list.find(tools, fn(t) { t.name == "firecrawl_extract" })
  list.contains(t.required_params, "url") |> should.be_true
}

// ---------------------------------------------------------------------------
// Input validation — new tools
// ---------------------------------------------------------------------------

pub fn exa_search_missing_query_returns_failure_test() {
  let call = ToolCall(id: "e1", name: "exa_search", input_json: "{}")
  let result = web.execute(call)
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}

pub fn tavily_search_missing_query_returns_failure_test() {
  let call = ToolCall(id: "t1", name: "tavily_search", input_json: "{}")
  let result = web.execute(call)
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}

pub fn firecrawl_extract_missing_url_returns_failure_test() {
  let call = ToolCall(id: "f1", name: "firecrawl_extract", input_json: "{}")
  let result = web.execute(call)
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Missing API keys — returns clear error
// ---------------------------------------------------------------------------

pub fn exa_search_no_api_key_returns_failure_test() {
  let call =
    ToolCall(
      id: "e2",
      name: "exa_search",
      input_json: "{\"query\": \"test query\"}",
    )
  let result = web.execute(call)
  case result {
    ToolFailure(error: e, ..) ->
      should.be_true(string.contains(e, "EXA_API_KEY"))
    _ -> should.fail()
  }
}

pub fn tavily_search_no_api_key_returns_failure_test() {
  let call =
    ToolCall(
      id: "t2",
      name: "tavily_search",
      input_json: "{\"query\": \"test query\"}",
    )
  let result = web.execute(call)
  case result {
    ToolFailure(error: e, ..) ->
      should.be_true(string.contains(e, "TAVILY_API_KEY"))
    _ -> should.fail()
  }
}

pub fn firecrawl_extract_no_api_key_returns_failure_test() {
  let call =
    ToolCall(
      id: "f2",
      name: "firecrawl_extract",
      input_json: "{\"url\": \"https://example.com\"}",
    )
  let result = web.execute(call)
  case result {
    ToolFailure(error: e, ..) ->
      should.be_true(string.contains(e, "FIRECRAWL_API_KEY"))
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Unknown tool
// ---------------------------------------------------------------------------

pub fn unknown_web_tool_returns_failure_test() {
  let call = ToolCall(id: "u1", name: "unknown_search", input_json: "{}")
  let result = web.execute(call)
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Response parsers — exa
// ---------------------------------------------------------------------------

pub fn parse_exa_empty_results_test() {
  // Calling exa_search directly with no env var set
  let result = web.exa_search("test", option.None)
  case result {
    Error(msg) -> should.be_true(string.contains(msg, "EXA_API_KEY"))
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Response parsers — tavily
// ---------------------------------------------------------------------------

pub fn parse_tavily_no_key_test() {
  let result = web.tavily_search("test", option.None)
  case result {
    Error(msg) -> should.be_true(string.contains(msg, "TAVILY_API_KEY"))
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Response parsers — firecrawl
// ---------------------------------------------------------------------------

pub fn parse_firecrawl_no_key_test() {
  let result = web.firecrawl_extract("https://example.com", option.None)
  case result {
    Error(msg) -> should.be_true(string.contains(msg, "FIRECRAWL_API_KEY"))
    _ -> should.fail()
  }
}
