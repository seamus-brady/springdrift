import gleam/list
import gleeunit
import gleeunit/should
import llm/types.{ToolCall, ToolFailure}
import tools/brave

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn all_tools_count_test() {
  let tools = brave.all()
  tools |> list.length |> should.equal(5)
}

pub fn brave_web_search_tool_defined_test() {
  let tools = brave.all()
  let names = list.map(tools, fn(t) { t.name })
  list.contains(names, "brave_web_search") |> should.be_true
}

pub fn brave_news_search_tool_defined_test() {
  let tools = brave.all()
  let names = list.map(tools, fn(t) { t.name })
  list.contains(names, "brave_news_search") |> should.be_true
}

pub fn brave_llm_context_tool_defined_test() {
  let tools = brave.all()
  let names = list.map(tools, fn(t) { t.name })
  list.contains(names, "brave_llm_context") |> should.be_true
}

pub fn brave_summarizer_tool_defined_test() {
  let tools = brave.all()
  let names = list.map(tools, fn(t) { t.name })
  list.contains(names, "brave_summarizer") |> should.be_true
}

pub fn brave_answer_tool_defined_test() {
  let tools = brave.all()
  let names = list.map(tools, fn(t) { t.name })
  list.contains(names, "brave_answer") |> should.be_true
}

pub fn brave_web_search_has_query_param_test() {
  let tools = brave.all()
  let assert [t, ..] = tools
  t.name |> should.equal("brave_web_search")
  list.contains(t.required_params, "query") |> should.be_true
}

// ---------------------------------------------------------------------------
// is_brave_tool
// ---------------------------------------------------------------------------

pub fn is_brave_tool_true_test() {
  brave.is_brave_tool("brave_web_search") |> should.be_true
  brave.is_brave_tool("brave_news_search") |> should.be_true
  brave.is_brave_tool("brave_llm_context") |> should.be_true
  brave.is_brave_tool("brave_summarizer") |> should.be_true
  brave.is_brave_tool("brave_answer") |> should.be_true
}

pub fn is_brave_tool_false_test() {
  brave.is_brave_tool("web_search") |> should.be_false
  brave.is_brave_tool("fetch_url") |> should.be_false
  brave.is_brave_tool("unknown") |> should.be_false
}

// ---------------------------------------------------------------------------
// Missing input
// ---------------------------------------------------------------------------

pub fn brave_web_search_missing_query_test() {
  let call = ToolCall(id: "b1", name: "brave_web_search", input_json: "{}")
  let result = brave.execute(call)
  case result {
    ToolFailure(error: e, ..) ->
      e
      |> should.equal(
        "BRAVE_SEARCH_API_KEY not set. Set this environment variable to use Brave Search.",
      )
    _ -> should.fail()
  }
}

pub fn brave_news_search_missing_query_test() {
  let call = ToolCall(id: "b2", name: "brave_news_search", input_json: "{}")
  let result = brave.execute(call)
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}

pub fn brave_llm_context_missing_query_test() {
  let call = ToolCall(id: "b3", name: "brave_llm_context", input_json: "{}")
  let result = brave.execute(call)
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}

pub fn brave_summarizer_missing_query_test() {
  let call = ToolCall(id: "b4", name: "brave_summarizer", input_json: "{}")
  let result = brave.execute(call)
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}

pub fn brave_answer_missing_query_test() {
  let call = ToolCall(id: "b5", name: "brave_answer", input_json: "{}")
  let result = brave.execute(call)
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Missing API key (all brave tools should fail without env var)
// ---------------------------------------------------------------------------

pub fn brave_web_search_no_api_key_test() {
  let call =
    ToolCall(
      id: "k1",
      name: "brave_web_search",
      input_json: "{\"query\":\"test\"}",
    )
  let result = brave.execute(call)
  case result {
    ToolFailure(error: e, ..) -> {
      e
      |> should.equal(
        "BRAVE_SEARCH_API_KEY not set. Set this environment variable to use Brave Search.",
      )
    }
    _ -> should.fail()
  }
}

pub fn brave_answer_no_api_key_test() {
  let call =
    ToolCall(
      id: "k2",
      name: "brave_answer",
      input_json: "{\"query\":\"what is gleam\"}",
    )
  let result = brave.execute(call)
  case result {
    ToolFailure(error: e, ..) -> {
      e
      |> should.equal(
        "BRAVE_ANSWERS_API_KEY not set. Set this environment variable to use Brave Answers.",
      )
    }
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Unknown tool
// ---------------------------------------------------------------------------

pub fn unknown_brave_tool_returns_failure_test() {
  let call = ToolCall(id: "u1", name: "brave_unknown", input_json: "{}")
  let result = brave.execute(call)
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}
