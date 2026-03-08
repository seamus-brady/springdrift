//// Memory tools — query the narrative log for past research cycles,
//// and manage semantic facts in the facts store.
////
//// These tools let the cognitive loop interrogate its own memory:
//// what it worked on yesterday, last week, or for a specific topic.
//// The facts tools (memory_write, memory_read, memory_clear_key,
//// memory_query_facts, memory_trace_fact) let the loop explicitly
//// manage its working memory.

import facts/log as facts_log
import facts/types as facts_types
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/tool
import llm/types.{
  type Tool, type ToolCall, type ToolResult, ToolFailure, ToolSuccess,
}
import narrative/librarian.{type LibrarianMessage}
import narrative/log as narrative_log
import narrative/types as narrative_types
import slog

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

@external(erlang, "springdrift_ffi", "days_ago_date")
fn days_ago_date(days: Int) -> String

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

pub fn all() -> List(Tool) {
  [
    recall_recent_tool(),
    recall_search_tool(),
    recall_threads_tool(),
    memory_write_tool(),
    memory_read_tool(),
    memory_clear_tool(),
    memory_query_tool(),
    memory_trace_tool(),
  ]
}

fn recall_recent_tool() -> Tool {
  tool.new("recall_recent")
  |> tool.with_description(
    "Recall recent narrative entries from memory. Returns summaries of what the system worked on during a time period. Use this to understand recent activity, check what happened yesterday, or review the past week's work.",
  )
  |> tool.add_enum_param(
    "period",
    "Time period to recall",
    ["today", "yesterday", "this_week", "last_week", "last_30_days"],
    True,
  )
  |> tool.add_integer_param(
    "max_entries",
    "Maximum number of entries to return (default 20, max 50)",
    False,
  )
  |> tool.build()
}

fn recall_search_tool() -> Tool {
  tool.new("recall_search")
  |> tool.with_description(
    "Search narrative memory by keyword. Matches against entry summaries and keywords. Use this to find past research on a specific topic, entity, or domain.",
  )
  |> tool.add_string_param(
    "query",
    "Search term to match against summaries and keywords",
    True,
  )
  |> tool.add_integer_param(
    "max_entries",
    "Maximum number of entries to return (default 20, max 50)",
    False,
  )
  |> tool.build()
}

fn recall_threads_tool() -> Tool {
  tool.new("recall_threads")
  |> tool.with_description(
    "List active research threads from narrative memory. Each thread is an ongoing line of investigation that groups related research cycles. Shows thread name, cycle count, domains, locations, keywords, and last activity.",
  )
  |> tool.build()
}

fn memory_write_tool() -> Tool {
  tool.new("memory_write")
  |> tool.with_description(
    "Store a fact in memory. Persistent facts survive session restarts. "
    <> "Session facts are cleared when the session ends. "
    <> "Ephemeral facts are cleared at the end of the current cycle.",
  )
  |> tool.add_string_param(
    "key",
    "Unique key for the fact (e.g. 'dublin_rent', 'user_preference_format')",
    True,
  )
  |> tool.add_string_param("value", "The fact value to store", True)
  |> tool.add_enum_param(
    "scope",
    "Memory scope",
    ["persistent", "session", "ephemeral"],
    True,
  )
  |> tool.add_number_param(
    "confidence",
    "Confidence in the fact (0.0 to 1.0)",
    True,
  )
  |> tool.build()
}

fn memory_read_tool() -> Tool {
  tool.new("memory_read")
  |> tool.with_description(
    "Read the current value of a fact by key. Returns the latest non-superseded value.",
  )
  |> tool.add_string_param("key", "The key to look up", True)
  |> tool.build()
}

fn memory_clear_tool() -> Tool {
  tool.new("memory_clear_key")
  |> tool.with_description(
    "Remove a fact from memory by key. The fact history is preserved for auditing.",
  )
  |> tool.add_string_param("key", "The key to clear", True)
  |> tool.build()
}

fn memory_query_tool() -> Tool {
  tool.new("memory_query_facts")
  |> tool.with_description(
    "Search memory for facts matching a keyword. Searches both keys and values.",
  )
  |> tool.add_string_param(
    "keyword",
    "Search term to match against fact keys and values",
    True,
  )
  |> tool.build()
}

fn memory_trace_tool() -> Tool {
  tool.new("memory_trace_fact")
  |> tool.with_description(
    "Show the full history of a key, including all versions, supersessions, and clears. "
    <> "Useful for understanding how a fact changed over time.",
  )
  |> tool.add_string_param("key", "The key to trace", True)
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

/// Check if a tool call is a memory tool.
pub fn is_memory_tool(name: String) -> Bool {
  name == "recall_recent"
  || name == "recall_search"
  || name == "recall_threads"
  || name == "memory_write"
  || name == "memory_read"
  || name == "memory_clear_key"
  || name == "memory_query_facts"
  || name == "memory_trace_fact"
}

/// Context for facts-based memory tools.
pub type FactsContext {
  FactsContext(facts_dir: String, cycle_id: String, agent_id: String)
}

/// Execute a memory tool call. Uses the Librarian if available,
/// otherwise falls back to direct JSONL reads.
pub fn execute(
  call: ToolCall,
  narrative_dir: String,
  lib: Option(Subject(LibrarianMessage)),
  facts_ctx: Option(FactsContext),
) -> ToolResult {
  slog.debug("memory", "execute", "tool=" <> call.name, None)
  case call.name {
    "recall_recent" -> run_recall_recent(call, narrative_dir, lib)
    "recall_search" -> run_recall_search(call, narrative_dir, lib)
    "recall_threads" -> run_recall_threads(call, narrative_dir, lib)
    "memory_write" -> run_memory_write(call, lib, facts_ctx)
    "memory_read" -> run_memory_read(call, lib, facts_ctx)
    "memory_clear_key" -> run_memory_clear(call, lib, facts_ctx)
    "memory_query_facts" -> run_memory_query(call, lib, facts_ctx)
    "memory_trace_fact" -> run_memory_trace(call, facts_ctx)
    _ -> ToolFailure(tool_use_id: call.id, error: "Unknown tool: " <> call.name)
  }
}

// ---------------------------------------------------------------------------
// recall_recent
// ---------------------------------------------------------------------------

fn run_recall_recent(
  call: ToolCall,
  dir: String,
  lib: Option(Subject(LibrarianMessage)),
) -> ToolResult {
  let decoder = {
    use period <- decode.field("period", decode.string)
    use max <- decode.optional_field("max_entries", 20, decode.int)
    decode.success(#(period, max))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid recall_recent input: missing period",
      )
    Ok(#(period, max_entries)) -> {
      let clamped = int.min(50, int.max(1, max_entries))
      let #(from, to) = date_range_for_period(period)
      let entries = case lib {
        Some(l) -> librarian.load_entries(l, from, to)
        None -> narrative_log.load_entries(dir, from, to)
      }
      let limited = take_last(entries, clamped)
      let formatted = format_entries(limited, period)
      ToolSuccess(tool_use_id: call.id, content: formatted)
    }
  }
}

fn date_range_for_period(period: String) -> #(String, String) {
  let today = get_date()
  case period {
    "today" -> #(today, today)
    "yesterday" -> {
      let yesterday = days_ago_date(1)
      #(yesterday, yesterday)
    }
    "this_week" -> {
      let week_ago = days_ago_date(7)
      #(week_ago, today)
    }
    "last_week" -> {
      let two_weeks_ago = days_ago_date(14)
      let week_ago = days_ago_date(7)
      #(two_weeks_ago, week_ago)
    }
    "last_30_days" -> {
      let thirty_ago = days_ago_date(30)
      #(thirty_ago, today)
    }
    _ -> #(today, today)
  }
}

// ---------------------------------------------------------------------------
// recall_search
// ---------------------------------------------------------------------------

fn run_recall_search(
  call: ToolCall,
  dir: String,
  lib: Option(Subject(LibrarianMessage)),
) -> ToolResult {
  let decoder = {
    use query <- decode.field("query", decode.string)
    use max <- decode.optional_field("max_entries", 20, decode.int)
    decode.success(#(query, max))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid recall_search input: missing query",
      )
    Ok(#(query, max_entries)) -> {
      let clamped = int.min(50, int.max(1, max_entries))
      let entries = case lib {
        Some(l) -> librarian.search(l, query)
        None -> narrative_log.search(dir, query)
      }
      let limited = take_last(entries, clamped)
      case limited {
        [] ->
          ToolSuccess(
            tool_use_id: call.id,
            content: "No narrative entries found matching \"" <> query <> "\".",
          )
        _ -> {
          let formatted =
            "Found "
            <> int.to_string(list.length(entries))
            <> " entries matching \""
            <> query
            <> "\""
            <> case list.length(entries) > clamped {
              True -> " (showing last " <> int.to_string(clamped) <> ")"
              False -> ""
            }
            <> ":\n\n"
            <> format_entry_list(limited)
          ToolSuccess(tool_use_id: call.id, content: formatted)
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// recall_threads
// ---------------------------------------------------------------------------

fn run_recall_threads(
  call: ToolCall,
  dir: String,
  lib: Option(Subject(LibrarianMessage)),
) -> ToolResult {
  let index = case lib {
    Some(l) -> librarian.load_thread_index(l)
    None -> narrative_log.load_thread_index(dir)
  }
  case index.threads {
    [] ->
      ToolSuccess(
        tool_use_id: call.id,
        content: "No active threads in narrative memory.",
      )
    threads -> {
      let formatted =
        "Active threads ("
        <> int.to_string(list.length(threads))
        <> "):\n\n"
        <> string.join(list.map(threads, format_thread_state), "\n\n")
      ToolSuccess(tool_use_id: call.id, content: formatted)
    }
  }
}

fn format_thread_state(ts: narrative_types.ThreadState) -> String {
  let domains = case ts.domains {
    [] -> ""
    d -> "  Domains: " <> string.join(d, ", ") <> "\n"
  }
  let locations = case ts.locations {
    [] -> ""
    l -> "  Locations: " <> string.join(l, ", ") <> "\n"
  }
  let keywords = case ts.keywords {
    [] -> ""
    k -> "  Keywords: " <> string.join(list.take(k, 10), ", ") <> "\n"
  }
  let data_points = case ts.last_data_points {
    [] -> ""
    dps ->
      "  Last data points:\n"
      <> string.join(
        list.map(dps, fn(dp) {
          "    - " <> dp.label <> ": " <> dp.value <> " " <> dp.unit
        }),
        "\n",
      )
      <> "\n"
  }
  "## "
  <> ts.thread_name
  <> " ["
  <> ts.thread_id
  <> "]\n"
  <> "  Cycles: "
  <> int.to_string(ts.cycle_count)
  <> " | Last: "
  <> ts.last_cycle_at
  <> "\n"
  <> domains
  <> locations
  <> keywords
  <> data_points
}

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

fn format_entries(
  entries: List(narrative_types.NarrativeEntry),
  period: String,
) -> String {
  case entries {
    [] -> "No narrative entries found for " <> period <> "."
    _ ->
      int.to_string(list.length(entries))
      <> " entries for "
      <> period
      <> ":\n\n"
      <> format_entry_list(entries)
  }
}

fn format_entry_list(entries: List(narrative_types.NarrativeEntry)) -> String {
  string.join(list.map(entries, format_entry), "\n---\n")
}

fn format_entry(entry: narrative_types.NarrativeEntry) -> String {
  let status = case entry.outcome.status {
    narrative_types.Success -> "success"
    narrative_types.Partial -> "partial"
    narrative_types.Failure -> "failure"
  }
  let thread_info = case entry.thread {
    Some(t) -> "  Thread: " <> t.thread_name <> "\n"
    None -> ""
  }
  let keywords = case entry.keywords {
    [] -> ""
    k -> "  Keywords: " <> string.join(k, ", ") <> "\n"
  }
  let entities = format_entry_entities(entry.entities)
  let delegation = case entry.delegation_chain {
    [] -> ""
    chain ->
      "  Agents: "
      <> string.join(list.map(chain, fn(d) { d.agent }), ", ")
      <> "\n"
  }
  let continuity = case entry.thread {
    Some(t) if t.continuity_note != "" ->
      "  Continuity: " <> t.continuity_note <> "\n"
    _ -> ""
  }
  "["
  <> entry.timestamp
  <> "] "
  <> status
  <> " | "
  <> entry.intent.domain
  <> "\n"
  <> "  "
  <> entry.summary
  <> "\n"
  <> thread_info
  <> keywords
  <> entities
  <> delegation
  <> continuity
}

fn format_entry_entities(e: narrative_types.Entities) -> String {
  let locations = case e.locations {
    [] -> ""
    l -> "  Locations: " <> string.join(l, ", ") <> "\n"
  }
  let orgs = case e.organisations {
    [] -> ""
    o -> "  Organisations: " <> string.join(o, ", ") <> "\n"
  }
  let dps = case e.data_points {
    [] -> ""
    points ->
      "  Data points: "
      <> string.join(
        list.map(points, fn(dp) { dp.label <> "=" <> dp.value <> dp.unit }),
        ", ",
      )
      <> "\n"
  }
  locations <> orgs <> dps
}

fn take_last(items: List(a), n: Int) -> List(a) {
  let len = list.length(items)
  case len > n {
    True -> list.drop(items, len - n)
    False -> items
  }
}

// ---------------------------------------------------------------------------
// Facts tool implementations
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_id() -> String

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

fn run_memory_write(
  call: ToolCall,
  lib: Option(Subject(LibrarianMessage)),
  facts_ctx: Option(FactsContext),
) -> ToolResult {
  case facts_ctx {
    None ->
      ToolFailure(
        tool_use_id: call.id,
        error: "memory_write not available: facts store not configured",
      )
    Some(ctx) -> {
      let number_decoder =
        decode.one_of(decode.float, [
          decode.int |> decode.map(int.to_float),
        ])
      let decoder = {
        use key <- decode.field("key", decode.string)
        use value <- decode.field("value", decode.string)
        use scope_str <- decode.field("scope", decode.string)
        use confidence <- decode.field("confidence", number_decoder)
        decode.success(#(key, value, scope_str, confidence))
      }
      case json.parse(call.input_json, decoder) {
        Error(_) ->
          ToolFailure(tool_use_id: call.id, error: "Invalid memory_write input")
        Ok(#(key, value, scope_str, confidence)) -> {
          let scope = parse_scope(scope_str)
          let fact =
            facts_types.MemoryFact(
              schema_version: 1,
              fact_id: generate_id(),
              timestamp: get_datetime(),
              cycle_id: ctx.cycle_id,
              agent_id: Some(ctx.agent_id),
              key:,
              value:,
              scope:,
              operation: facts_types.Write,
              supersedes: None,
              confidence:,
              source: "memory_write_tool",
            )

          // Write to JSONL
          facts_log.append(ctx.facts_dir, fact)
          // Index in Librarian
          case lib {
            Some(l) -> librarian.notify_new_fact(l, fact)
            None -> Nil
          }

          ToolSuccess(
            tool_use_id: call.id,
            content: "Stored fact '"
              <> key
              <> "' = '"
              <> value
              <> "' (scope: "
              <> scope_str
              <> ")",
          )
        }
      }
    }
  }
}

fn run_memory_read(
  call: ToolCall,
  lib: Option(Subject(LibrarianMessage)),
  facts_ctx: Option(FactsContext),
) -> ToolResult {
  let decoder = {
    use key <- decode.field("key", decode.string)
    decode.success(key)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Invalid memory_read input")
    Ok(key) -> {
      // Try Librarian first, fall back to JSONL
      let result = case lib {
        Some(l) -> librarian.get_fact(l, key)
        None ->
          case facts_ctx {
            Some(ctx) -> {
              let current = facts_log.resolve_current(ctx.facts_dir, None)
              list.find(current, fn(f: facts_types.MemoryFact) { f.key == key })
            }
            None -> Error(Nil)
          }
      }
      case result {
        Ok(fact) ->
          ToolSuccess(tool_use_id: call.id, content: format_fact(fact))
        Error(_) ->
          ToolSuccess(
            tool_use_id: call.id,
            content: "No fact found for key '" <> key <> "'",
          )
      }
    }
  }
}

fn run_memory_clear(
  call: ToolCall,
  lib: Option(Subject(LibrarianMessage)),
  facts_ctx: Option(FactsContext),
) -> ToolResult {
  case facts_ctx {
    None ->
      ToolFailure(
        tool_use_id: call.id,
        error: "memory_clear_key not available: facts store not configured",
      )
    Some(ctx) -> {
      let decoder = {
        use key <- decode.field("key", decode.string)
        decode.success(key)
      }
      case json.parse(call.input_json, decoder) {
        Error(_) ->
          ToolFailure(
            tool_use_id: call.id,
            error: "Invalid memory_clear_key input",
          )
        Ok(key) -> {
          let fact =
            facts_types.MemoryFact(
              schema_version: 1,
              fact_id: generate_id(),
              timestamp: get_datetime(),
              cycle_id: ctx.cycle_id,
              agent_id: Some(ctx.agent_id),
              key:,
              value: "",
              scope: facts_types.Session,
              operation: facts_types.Clear,
              supersedes: None,
              confidence: 0.0,
              source: "memory_clear_tool",
            )

          facts_log.append(ctx.facts_dir, fact)
          case lib {
            Some(l) -> librarian.notify_new_fact(l, fact)
            None -> Nil
          }

          ToolSuccess(
            tool_use_id: call.id,
            content: "Cleared fact for key '" <> key <> "'",
          )
        }
      }
    }
  }
}

fn run_memory_query(
  call: ToolCall,
  lib: Option(Subject(LibrarianMessage)),
  facts_ctx: Option(FactsContext),
) -> ToolResult {
  let decoder = {
    use keyword <- decode.field("keyword", decode.string)
    decode.success(keyword)
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid memory_query_facts input",
      )
    Ok(keyword) -> {
      let facts = case lib {
        Some(l) -> librarian.search_facts(l, keyword)
        None ->
          case facts_ctx {
            Some(ctx) -> {
              let all = facts_log.resolve_current(ctx.facts_dir, None)
              let lower = string.lowercase(keyword)
              list.filter(all, fn(f: facts_types.MemoryFact) {
                string.contains(string.lowercase(f.key), lower)
                || string.contains(string.lowercase(f.value), lower)
              })
            }
            None -> []
          }
      }
      case facts {
        [] ->
          ToolSuccess(
            tool_use_id: call.id,
            content: "No facts found matching '" <> keyword <> "'",
          )
        _ ->
          ToolSuccess(tool_use_id: call.id, content: format_facts_list(facts))
      }
    }
  }
}

fn run_memory_trace(
  call: ToolCall,
  facts_ctx: Option(FactsContext),
) -> ToolResult {
  case facts_ctx {
    None ->
      ToolFailure(
        tool_use_id: call.id,
        error: "memory_trace_fact not available: facts store not configured",
      )
    Some(ctx) -> {
      let decoder = {
        use key <- decode.field("key", decode.string)
        decode.success(key)
      }
      case json.parse(call.input_json, decoder) {
        Error(_) ->
          ToolFailure(
            tool_use_id: call.id,
            error: "Invalid memory_trace_fact input",
          )
        Ok(key) -> {
          let history = facts_log.trace_key(ctx.facts_dir, key)
          case history {
            [] ->
              ToolSuccess(
                tool_use_id: call.id,
                content: "No history found for key '" <> key <> "'",
              )
            _ ->
              ToolSuccess(
                tool_use_id: call.id,
                content: format_trace(key, history),
              )
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Facts formatting
// ---------------------------------------------------------------------------

fn parse_scope(s: String) -> facts_types.FactScope {
  case s {
    "persistent" -> facts_types.Persistent
    "ephemeral" -> facts_types.Ephemeral
    _ -> facts_types.Session
  }
}

fn format_fact(f: facts_types.MemoryFact) -> String {
  "key: "
  <> f.key
  <> "\nvalue: "
  <> f.value
  <> "\nscope: "
  <> scope_to_string(f.scope)
  <> "\nconfidence: "
  <> float.to_string(f.confidence)
  <> "\nsource: "
  <> f.source
  <> "\ntimestamp: "
  <> f.timestamp
}

fn format_facts_list(facts: List(facts_types.MemoryFact)) -> String {
  facts
  |> list.map(fn(f: facts_types.MemoryFact) {
    f.key
    <> " = "
    <> f.value
    <> " (confidence: "
    <> float.to_string(f.confidence)
    <> ")"
  })
  |> string.join("\n")
}

fn format_trace(key: String, history: List(facts_types.MemoryFact)) -> String {
  "History for '"
  <> key
  <> "' ("
  <> int.to_string(list.length(history))
  <> " entries):\n"
  <> {
    history
    |> list.map(fn(f: facts_types.MemoryFact) {
      f.timestamp
      <> " ["
      <> op_to_string(f.operation)
      <> "] "
      <> f.value
      <> " (confidence: "
      <> float.to_string(f.confidence)
      <> ", source: "
      <> f.source
      <> ")"
    })
    |> string.join("\n")
  }
}

fn scope_to_string(scope: facts_types.FactScope) -> String {
  case scope {
    facts_types.Persistent -> "persistent"
    facts_types.Session -> "session"
    facts_types.Ephemeral -> "ephemeral"
  }
}

fn op_to_string(op: facts_types.FactOp) -> String {
  case op {
    facts_types.Write -> "write"
    facts_types.Clear -> "clear"
    facts_types.Superseded -> "superseded"
  }
}
