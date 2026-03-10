import embedding/types as embedding_types
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit
import gleeunit/should
import llm/types.{ToolCall, ToolFailure, ToolSuccess}
import simplifile
import tools/memory

const test_embed_config = embedding_types.EmbeddingConfig(
  model: "test",
  base_url: "http://localhost:0",
  dimensions: 768,
  fallback: "symbolic",
)

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn memory_tools_defined_test() {
  let tools = memory.all()
  tools |> list.length |> should.equal(14)
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

pub fn is_memory_tool_recall_cases_test() {
  memory.is_memory_tool("recall_cases") |> should.be_true
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
  let result =
    memory.execute(call, "/nonexistent/dir", None, None, test_embed_config, [])
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
  let result =
    memory.execute(
      call,
      "/nonexistent/narrative/dir",
      None,
      None,
      test_embed_config,
      [],
    )
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
  let result =
    memory.execute(
      call,
      "/nonexistent/narrative/dir",
      None,
      None,
      test_embed_config,
      [],
    )
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
  let result =
    memory.execute(
      call,
      "/nonexistent/narrative/dir",
      None,
      None,
      test_embed_config,
      [],
    )
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
  let result =
    memory.execute(call, "/nonexistent/dir", None, None, test_embed_config, [])
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
  let result =
    memory.execute(
      call,
      "/nonexistent/narrative/dir",
      None,
      None,
      test_embed_config,
      [],
    )
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
  let result =
    memory.execute(
      call,
      "/nonexistent/narrative/dir",
      None,
      None,
      test_embed_config,
      [],
    )
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
  let result = memory.execute(call, "/tmp", None, None, test_embed_config, [])
  case result {
    ToolFailure(..) -> Nil
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Facts tools — is_memory_tool
// ---------------------------------------------------------------------------

pub fn is_memory_tool_write_test() {
  memory.is_memory_tool("memory_write") |> should.be_true
}

pub fn is_memory_tool_read_test() {
  memory.is_memory_tool("memory_read") |> should.be_true
}

pub fn is_memory_tool_clear_test() {
  memory.is_memory_tool("memory_clear_key") |> should.be_true
}

pub fn is_memory_tool_query_test() {
  memory.is_memory_tool("memory_query_facts") |> should.be_true
}

pub fn is_memory_tool_trace_test() {
  memory.is_memory_tool("memory_trace_fact") |> should.be_true
}

// ---------------------------------------------------------------------------
// Facts tools — no context returns error
// ---------------------------------------------------------------------------

pub fn memory_write_no_context_test() {
  let call =
    ToolCall(
      id: "fw1",
      name: "memory_write",
      input_json: "{\"key\":\"rent\",\"value\":\"2340\",\"scope\":\"session\",\"confidence\":0.9}",
    )
  let result = memory.execute(call, "/tmp", None, None, test_embed_config, [])
  case result {
    ToolFailure(error: e, ..) ->
      should.be_true(string.contains(e, "not available"))
    _ -> should.fail()
  }
}

pub fn memory_clear_no_context_test() {
  let call =
    ToolCall(
      id: "fc1",
      name: "memory_clear_key",
      input_json: "{\"key\":\"rent\"}",
    )
  let result = memory.execute(call, "/tmp", None, None, test_embed_config, [])
  case result {
    ToolFailure(error: e, ..) ->
      should.be_true(string.contains(e, "not available"))
    _ -> should.fail()
  }
}

pub fn memory_trace_no_context_test() {
  let call =
    ToolCall(
      id: "ft1",
      name: "memory_trace_fact",
      input_json: "{\"key\":\"rent\"}",
    )
  let result = memory.execute(call, "/tmp", None, None, test_embed_config, [])
  case result {
    ToolFailure(error: e, ..) ->
      should.be_true(string.contains(e, "not available"))
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Facts tools — read with no facts returns not found
// ---------------------------------------------------------------------------

pub fn memory_read_not_found_test() {
  let call =
    ToolCall(
      id: "fr1",
      name: "memory_read",
      input_json: "{\"key\":\"nonexistent\"}",
    )
  let result = memory.execute(call, "/tmp", None, None, test_embed_config, [])
  case result {
    ToolSuccess(content: c, ..) ->
      should.be_true(string.contains(c, "No fact found"))
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Facts tools — query with no facts returns empty
// ---------------------------------------------------------------------------

pub fn memory_query_no_results_test() {
  let call =
    ToolCall(
      id: "fq1",
      name: "memory_query_facts",
      input_json: "{\"keyword\":\"nonexistent\"}",
    )
  let result = memory.execute(call, "/tmp", None, None, test_embed_config, [])
  case result {
    ToolSuccess(content: c, ..) ->
      should.be_true(string.contains(c, "No facts found"))
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Facts tools — write and read roundtrip (with context, no Librarian)
// ---------------------------------------------------------------------------

pub fn memory_write_and_read_roundtrip_test() {
  let dir = "/tmp/memory_tools_test_roundtrip"
  let _ = simplifile.create_directory_all(dir)
  // Clean up any previous test data
  let _ = simplifile.delete(dir <> "/facts.jsonl")

  let ctx =
    option.Some(memory.FactsContext(
      facts_dir: dir,
      cycle_id: "cycle-001",
      agent_id: "test-agent",
    ))

  // Write a fact
  let write_call =
    ToolCall(
      id: "wr1",
      name: "memory_write",
      input_json: "{\"key\":\"dublin_rent\",\"value\":\"2340\",\"scope\":\"session\",\"confidence\":0.9}",
    )
  let write_result =
    memory.execute(write_call, "/tmp", None, ctx, test_embed_config, [])
  case write_result {
    ToolSuccess(content: c, ..) ->
      should.be_true(string.contains(c, "dublin_rent"))
    _ -> should.fail()
  }

  // Read it back (without Librarian, falls back to JSONL)
  let read_call =
    ToolCall(
      id: "rd1",
      name: "memory_read",
      input_json: "{\"key\":\"dublin_rent\"}",
    )
  let read_result =
    memory.execute(read_call, "/tmp", None, ctx, test_embed_config, [])
  case read_result {
    ToolSuccess(content: c, ..) -> {
      should.be_true(string.contains(c, "dublin_rent"))
      should.be_true(string.contains(c, "2340"))
    }
    _ -> should.fail()
  }

  // Clean up
  let _ = simplifile.delete(dir <> "/facts.jsonl")
  Nil
}

// ---------------------------------------------------------------------------
// Facts tools — write, clear, read shows cleared
// ---------------------------------------------------------------------------

pub fn memory_write_clear_read_test() {
  let dir = "/tmp/memory_tools_test_clear"
  let _ = simplifile.create_directory_all(dir)
  let _ = simplifile.delete(dir <> "/facts.jsonl")

  let ctx =
    option.Some(memory.FactsContext(
      facts_dir: dir,
      cycle_id: "cycle-001",
      agent_id: "test-agent",
    ))

  // Write
  let write_call =
    ToolCall(
      id: "wc1",
      name: "memory_write",
      input_json: "{\"key\":\"temp\",\"value\":\"22C\",\"scope\":\"session\",\"confidence\":0.8}",
    )
  let _ = memory.execute(write_call, "/tmp", None, ctx, test_embed_config, [])

  // Clear
  let clear_call =
    ToolCall(
      id: "cc1",
      name: "memory_clear_key",
      input_json: "{\"key\":\"temp\"}",
    )
  let clear_result =
    memory.execute(clear_call, "/tmp", None, ctx, test_embed_config, [])
  case clear_result {
    ToolSuccess(content: c, ..) -> should.be_true(string.contains(c, "Cleared"))
    _ -> should.fail()
  }

  // Read should show not found
  let read_call =
    ToolCall(id: "rc1", name: "memory_read", input_json: "{\"key\":\"temp\"}")
  let read_result =
    memory.execute(read_call, "/tmp", None, ctx, test_embed_config, [])
  case read_result {
    ToolSuccess(content: c, ..) ->
      should.be_true(string.contains(c, "No fact found"))
    _ -> should.fail()
  }

  let _ = simplifile.delete(dir <> "/facts.jsonl")
  Nil
}

// ---------------------------------------------------------------------------
// Facts tools — trace shows history
// ---------------------------------------------------------------------------

pub fn memory_trace_shows_history_test() {
  let dir = "/tmp/memory_tools_test_trace"
  let _ = simplifile.create_directory_all(dir)
  let _ = simplifile.delete(dir <> "/facts.jsonl")

  let ctx =
    option.Some(memory.FactsContext(
      facts_dir: dir,
      cycle_id: "cycle-001",
      agent_id: "test-agent",
    ))

  // Write two versions
  let w1 =
    ToolCall(
      id: "tw1",
      name: "memory_write",
      input_json: "{\"key\":\"rent\",\"value\":\"2340\",\"scope\":\"session\",\"confidence\":0.8}",
    )
  let _ = memory.execute(w1, "/tmp", None, ctx, test_embed_config, [])

  let w2 =
    ToolCall(
      id: "tw2",
      name: "memory_write",
      input_json: "{\"key\":\"rent\",\"value\":\"2500\",\"scope\":\"session\",\"confidence\":0.9}",
    )
  let _ = memory.execute(w2, "/tmp", None, ctx, test_embed_config, [])

  // Trace
  let trace_call =
    ToolCall(
      id: "tt1",
      name: "memory_trace_fact",
      input_json: "{\"key\":\"rent\"}",
    )
  let trace_result =
    memory.execute(trace_call, "/tmp", None, ctx, test_embed_config, [])
  case trace_result {
    ToolSuccess(content: c, ..) -> {
      should.be_true(string.contains(c, "2 entries"))
      should.be_true(string.contains(c, "2340"))
      should.be_true(string.contains(c, "2500"))
    }
    _ -> should.fail()
  }

  let _ = simplifile.delete(dir <> "/facts.jsonl")
  Nil
}

// ---------------------------------------------------------------------------
// Facts tools — query finds matching facts
// ---------------------------------------------------------------------------

pub fn memory_query_finds_facts_test() {
  let dir = "/tmp/memory_tools_test_query"
  let _ = simplifile.create_directory_all(dir)
  let _ = simplifile.delete(dir <> "/facts.jsonl")

  let ctx =
    option.Some(memory.FactsContext(
      facts_dir: dir,
      cycle_id: "cycle-001",
      agent_id: "test-agent",
    ))

  // Write facts
  let w1 =
    ToolCall(
      id: "qw1",
      name: "memory_write",
      input_json: "{\"key\":\"dublin_rent\",\"value\":\"2340\",\"scope\":\"session\",\"confidence\":0.9}",
    )
  let _ = memory.execute(w1, "/tmp", None, ctx, test_embed_config, [])

  let w2 =
    ToolCall(
      id: "qw2",
      name: "memory_write",
      input_json: "{\"key\":\"cork_rent\",\"value\":\"1800\",\"scope\":\"session\",\"confidence\":0.8}",
    )
  let _ = memory.execute(w2, "/tmp", None, ctx, test_embed_config, [])

  // Query for "dublin" — should find dublin_rent
  let query_call =
    ToolCall(
      id: "qq1",
      name: "memory_query_facts",
      input_json: "{\"keyword\":\"dublin\"}",
    )
  let query_result =
    memory.execute(query_call, "/tmp", None, ctx, test_embed_config, [])
  case query_result {
    ToolSuccess(content: c, ..) -> {
      should.be_true(string.contains(c, "dublin_rent"))
      should.be_true(string.contains(c, "2340"))
    }
    _ -> should.fail()
  }

  let _ = simplifile.delete(dir <> "/facts.jsonl")
  Nil
}

// ---------------------------------------------------------------------------
// agent_status
// ---------------------------------------------------------------------------

pub fn agent_status_no_agents_test() {
  let call = ToolCall(id: "as1", name: "agent_status", input_json: "{}")
  let result = memory.execute(call, "/tmp", None, None, test_embed_config, [])
  case result {
    ToolSuccess(content: c, ..) -> c |> should.equal("No agents registered.")
    _ -> should.fail()
  }
}

pub fn agent_status_with_agents_test() {
  let entries = [
    memory.AgentStatusEntry(name: "researcher", status: "Running"),
    memory.AgentStatusEntry(name: "writer", status: "Stopped"),
  ]
  let call = ToolCall(id: "as2", name: "agent_status", input_json: "{}")
  let result =
    memory.execute(call, "/tmp", None, None, test_embed_config, entries)
  case result {
    ToolSuccess(content: c, ..) -> {
      should.be_true(string.contains(c, "researcher: Running"))
      should.be_true(string.contains(c, "writer: Stopped"))
      should.be_true(string.contains(c, "2"))
    }
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// list_recent_cycles (no librarian)
// ---------------------------------------------------------------------------

pub fn list_recent_cycles_no_librarian_test() {
  let call = ToolCall(id: "lrc1", name: "list_recent_cycles", input_json: "{}")
  let result = memory.execute(call, "/tmp", None, None, test_embed_config, [])
  case result {
    ToolFailure(error: e, ..) ->
      should.be_true(string.contains(e, "not available"))
    _ -> should.fail()
  }
}
