import gleam/list
import gleeunit
import gleeunit/should
import llm/types.{ToolCall, ToolFailure, ToolSuccess}
import tools/memory

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn memory_tools_defined_test() {
  let tools = memory.all()
  tools |> list.length |> should.equal(3)
}

pub fn recall_recent_tool_exists_test() {
  let tools = memory.all()
  let names = list.map(tools, fn(t) { t.name })
  list.contains(names, "recall_recent") |> should.be_true
}

pub fn recall_search_tool_exists_test() {
  let tools = memory.all()
  let names = list.map(tools, fn(t) { t.name })
  list.contains(names, "recall_search") |> should.be_true
}

pub fn recall_threads_tool_exists_test() {
  let tools = memory.all()
  let names = list.map(tools, fn(t) { t.name })
  list.contains(names, "recall_threads") |> should.be_true
}

// ---------------------------------------------------------------------------
// is_memory_tool
// ---------------------------------------------------------------------------

pub fn is_memory_tool_recall_recent_test() {
  memory.is_memory_tool("recall_recent") |> should.be_true
}

pub fn is_memory_tool_recall_search_test() {
  memory.is_memory_tool("recall_search") |> should.be_true
}

pub fn is_memory_tool_recall_threads_test() {
  memory.is_memory_tool("recall_threads") |> should.be_true
}

pub fn is_memory_tool_unknown_test() {
  memory.is_memory_tool("calculator") |> should.be_false
}

pub fn is_memory_tool_agent_test() {
  memory.is_memory_tool("agent_researcher") |> should.be_false
}

// ---------------------------------------------------------------------------
// recall_recent — input validation
// ---------------------------------------------------------------------------

pub fn recall_recent_missing_period_test() {
  let call = ToolCall(id: "m1", name: "recall_recent", input_json: "{}")
  let result = memory.execute(call, "/nonexistent/dir")
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}

pub fn recall_recent_empty_dir_returns_no_entries_test() {
  let call =
    ToolCall(
      id: "m2",
      name: "recall_recent",
      input_json: "{\"period\": \"today\"}",
    )
  let result = memory.execute(call, "/nonexistent/narrative/dir")
  case result {
    ToolSuccess(content: c, ..) -> {
      c |> should.equal("No narrative entries found for today.")
    }
    _ -> should.fail()
  }
}

pub fn recall_recent_yesterday_empty_test() {
  let call =
    ToolCall(
      id: "m3",
      name: "recall_recent",
      input_json: "{\"period\": \"yesterday\"}",
    )
  let result = memory.execute(call, "/nonexistent/narrative/dir")
  case result {
    ToolSuccess(content: c, ..) -> {
      c |> should.equal("No narrative entries found for yesterday.")
    }
    _ -> should.fail()
  }
}

pub fn recall_recent_this_week_empty_test() {
  let call =
    ToolCall(
      id: "m4",
      name: "recall_recent",
      input_json: "{\"period\": \"this_week\"}",
    )
  let result = memory.execute(call, "/nonexistent/narrative/dir")
  case result {
    ToolSuccess(content: c, ..) -> {
      c |> should.equal("No narrative entries found for this_week.")
    }
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// recall_search — input validation
// ---------------------------------------------------------------------------

pub fn recall_search_missing_query_test() {
  let call = ToolCall(id: "s1", name: "recall_search", input_json: "{}")
  let result = memory.execute(call, "/nonexistent/dir")
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}

pub fn recall_search_empty_dir_returns_no_results_test() {
  let call =
    ToolCall(
      id: "s2",
      name: "recall_search",
      input_json: "{\"query\": \"dublin property\"}",
    )
  let result = memory.execute(call, "/nonexistent/narrative/dir")
  case result {
    ToolSuccess(content: c, ..) -> {
      c
      |> should.equal(
        "No narrative entries found matching \"dublin property\".",
      )
    }
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// recall_threads — empty state
// ---------------------------------------------------------------------------

pub fn recall_threads_empty_dir_test() {
  let call = ToolCall(id: "t1", name: "recall_threads", input_json: "{}")
  let result = memory.execute(call, "/nonexistent/narrative/dir")
  case result {
    ToolSuccess(content: c, ..) -> {
      c |> should.equal("No active threads in narrative memory.")
    }
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Unknown tool
// ---------------------------------------------------------------------------

pub fn unknown_memory_tool_test() {
  let call = ToolCall(id: "u1", name: "recall_unknown", input_json: "{}")
  let result = memory.execute(call, "/tmp")
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}
