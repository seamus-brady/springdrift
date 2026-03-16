//// Memory tools — query the narrative log for past research cycles,
//// and manage semantic facts in the facts store.
////
//// These tools let the cognitive loop interrogate its own memory:
//// what it worked on yesterday, last week, or for a specific topic.
//// The facts tools (memory_write, memory_read, memory_clear_key,
//// memory_query_facts, memory_trace_fact) let the loop explicitly
//// manage its working memory.

import cbr/types as cbr_types
import dag/types as dag_types
import embedding/client as embedding_client
import embedding/types as embedding_types
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
    reflect_tool(),
    inspect_cycle_tool(),
    recall_cases_tool(),
    query_tool_activity_tool(),
    introspect_tool(),
    list_recent_cycles_tool(),
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

fn reflect_tool() -> Tool {
  tool.new("reflect")
  |> tool.with_description(
    "Reflect on past activity. Returns aggregated stats for a date: total cycles, "
    <> "success/failure counts, token usage, models used, and D' gate decisions. "
    <> "Use this to understand how a day of work went, spot patterns, or review efficiency.",
  )
  |> tool.add_string_param(
    "date",
    "Date to reflect on in YYYY-MM-DD format (default: today)",
    False,
  )
  |> tool.build()
}

fn recall_cases_tool() -> Tool {
  tool.new("recall_cases")
  |> tool.with_description(
    "Search for similar past cases from Case-Based Reasoning memory. Returns matching cases showing the problem summary, approach taken, outcome status, and pitfalls encountered. Use this to learn from past experience before tackling a similar task.",
  )
  |> tool.add_string_param(
    "intent",
    "Intent to match against past cases (e.g. 'research', 'summarise')",
    False,
  )
  |> tool.add_string_param(
    "domain",
    "Domain to match (e.g. 'technology', 'finance')",
    False,
  )
  |> tool.add_string_param(
    "keywords",
    "Comma-separated keywords to match against case keywords",
    False,
  )
  |> tool.add_integer_param(
    "max_results",
    "Maximum number of results to return (default 5)",
    False,
  )
  |> tool.build()
}

fn inspect_cycle_tool() -> Tool {
  tool.new("inspect_cycle")
  |> tool.with_description(
    "Inspect a specific cycle by its ID. Returns the full cycle tree: the root cognitive "
    <> "cycle and all agent sub-cycles, including tool calls, D' gate decisions, token "
    <> "counts, and agent outputs. Use this to drill into a specific interaction.",
  )
  |> tool.add_string_param("cycle_id", "The cycle ID to inspect", True)
  |> tool.build()
}

fn query_tool_activity_tool() -> Tool {
  tool.new("query_tool_activity")
  |> tool.with_description(
    "Query tool usage activity for a given date. Returns per-tool stats showing how many "
    <> "times each tool was called, how many succeeded or failed, and which cycles used it. "
    <> "Use this to understand what tools agents have been using and spot failure patterns.",
  )
  |> tool.add_string_param("date", "Date to query in YYYY-MM-DD format", True)
  |> tool.build()
}

fn introspect_tool() -> Tool {
  tool.new("introspect")
  |> tool.with_description(
    "Perceive your current constitution: identity, agent roster and status, "
    <> "available tool categories, memory state, today's performance, and "
    <> "D' safety config. Call before complex multi-agent tasks to confirm "
    <> "readiness, or after failures to understand system state.",
  )
  |> tool.build()
}

fn list_recent_cycles_tool() -> Tool {
  tool.new("list_recent_cycles")
  |> tool.with_description(
    "List recent cycle IDs for a given date. Returns cycle IDs that can be passed "
    <> "to inspect_cycle for detailed analysis. Use this to discover which cycles "
    <> "happened without needing to know IDs in advance.",
  )
  |> tool.add_string_param(
    "date",
    "Date to query in YYYY-MM-DD format (default: today)",
    False,
  )
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
  || name == "reflect"
  || name == "inspect_cycle"
  || name == "recall_cases"
  || name == "query_tool_activity"
  || name == "introspect"
  || name == "list_recent_cycles"
}

/// Context for facts-based memory tools.
pub type FactsContext {
  FactsContext(facts_dir: String, cycle_id: String, agent_id: String)
}

/// Registry entry for agent roster (avoids depending on registry module's opaque type).
pub type AgentStatusEntry {
  AgentStatusEntry(name: String, status: String)
}

/// Context for the `introspect` tool — carries system state from CognitiveState.
pub type IntrospectContext {
  IntrospectContext(
    agent_uuid: String,
    session_since: String,
    active_profile: Option(String),
    agents: List(AgentStatusEntry),
    dprime_enabled: Bool,
    dprime_modify_threshold: Float,
    dprime_reject_threshold: Float,
    current_cycle_id: Option(String),
    thread_total: Int,
    thread_single_cycle: Int,
    thread_uuid_named: Int,
    thread_multi_cycle: Int,
  )
}

/// Limits for memory tool result sizes.
pub type MemoryLimits {
  MemoryLimits(recall_max_entries: Int, cbr_max_results: Int)
}

/// Default memory limits.
pub fn default_limits() -> MemoryLimits {
  MemoryLimits(recall_max_entries: 50, cbr_max_results: 20)
}

/// Execute a memory tool call. Uses the Librarian if available,
/// otherwise falls back to direct JSONL reads.
pub fn execute(
  call: ToolCall,
  narrative_dir: String,
  lib: Option(Subject(LibrarianMessage)),
  facts_ctx: Option(FactsContext),
  embed_config: embedding_types.EmbeddingConfig,
  introspect_ctx: Option(IntrospectContext),
  limits: MemoryLimits,
) -> ToolResult {
  slog.debug("memory", "execute", "tool=" <> call.name, None)
  case call.name {
    "recall_recent" ->
      run_recall_recent(call, narrative_dir, lib, limits.recall_max_entries)
    "recall_search" ->
      run_recall_search(call, narrative_dir, lib, limits.recall_max_entries)
    "recall_threads" -> run_recall_threads(call, narrative_dir, lib)
    "memory_write" -> run_memory_write(call, lib, facts_ctx)
    "memory_read" -> run_memory_read(call, lib, facts_ctx)
    "memory_clear_key" -> run_memory_clear(call, lib, facts_ctx)
    "memory_query_facts" -> run_memory_query(call, lib, facts_ctx)
    "memory_trace_fact" -> run_memory_trace(call, facts_ctx)
    "reflect" -> run_reflect(call, lib)
    "inspect_cycle" -> run_inspect_cycle(call, lib)
    "recall_cases" ->
      run_recall_cases(call, lib, embed_config, limits.cbr_max_results)
    "query_tool_activity" -> run_query_tool_activity(call, lib)
    "introspect" -> run_introspect(call, introspect_ctx)
    "list_recent_cycles" -> run_list_recent_cycles(call, lib)
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
  recall_max: Int,
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
      let clamped = int.min(recall_max, int.max(1, max_entries))
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
  recall_max: Int,
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
      let clamped = int.min(recall_max, int.max(1, max_entries))
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
      let total = list.length(threads)

      // Health metrics
      let single_cycle = list.count(threads, fn(ts) { ts.cycle_count <= 1 })
      let uuid_named =
        list.count(threads, fn(ts) {
          string.starts_with(ts.thread_name, "Thread ")
        })
      let named = total - uuid_named
      let multi_cycle = total - single_cycle

      // Size buckets
      let size_2_to_5 =
        list.count(threads, fn(ts) {
          ts.cycle_count >= 2 && ts.cycle_count <= 5
        })
      let size_6_plus = list.count(threads, fn(ts) { ts.cycle_count >= 6 })

      // Top threads by cycle count (up to 15)
      let sorted =
        list.sort(threads, fn(a, b) {
          int.compare(b.cycle_count, a.cycle_count)
        })
      let top = list.take(sorted, 15)
      let top_formatted =
        string.join(list.map(top, format_thread_state), "\n\n")

      let summary =
        "## Thread summary\n\n"
        <> "Total threads: "
        <> int.to_string(total)
        <> "\n"
        <> "  Named: "
        <> int.to_string(named)
        <> " | UUID-pattern: "
        <> int.to_string(uuid_named)
        <> "\n"
        <> "  Single-cycle: "
        <> int.to_string(single_cycle)
        <> " | Multi-cycle: "
        <> int.to_string(multi_cycle)
        <> "\n"
        <> "  2-5 cycles: "
        <> int.to_string(size_2_to_5)
        <> " | 6+ cycles: "
        <> int.to_string(size_6_plus)
        <> "\n\n"
        <> "## Top threads by activity\n\n"
        <> top_formatted
      ToolSuccess(tool_use_id: call.id, content: summary)
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
  let topics = case ts.topics {
    [] -> ""
    t -> "  Topics: " <> string.join(list.take(t, 10), ", ") <> "\n"
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
  <> topics
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
  let topics = case entry.topics {
    [] -> ""
    t -> "  Topics: " <> string.join(t, ", ") <> "\n"
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
  <> topics
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
// reflect — day-level stats from DAG
// ---------------------------------------------------------------------------

fn run_reflect(
  call: ToolCall,
  lib: Option(Subject(LibrarianMessage)),
) -> ToolResult {
  case lib {
    None ->
      ToolFailure(
        tool_use_id: call.id,
        error: "reflect not available: DAG index not initialised",
      )
    Some(l) -> {
      let decoder = {
        use date <- decode.optional_field("date", get_date(), decode.string)
        decode.success(date)
      }
      let date = case json.parse(call.input_json, decoder) {
        Ok(d) -> d
        Error(_) -> get_date()
      }
      let subj = process.new_subject()
      process.send(l, librarian.QueryDayStats(date:, reply_to: subj))
      case process.receive(subj, 5000) {
        Error(_) ->
          ToolFailure(tool_use_id: call.id, error: "Timeout querying DAG stats")
        Ok(stats) ->
          ToolSuccess(tool_use_id: call.id, content: format_day_stats(stats))
      }
    }
  }
}

fn format_day_stats(stats: dag_types.DayStats) -> String {
  let total = stats.total_cycles
  case total {
    0 -> "No cycles recorded for " <> stats.date <> "."
    _ ->
      "## Day summary for "
      <> stats.date
      <> "\n\n"
      <> "Total cycles: "
      <> int.to_string(total)
      <> "\n"
      <> "  Success: "
      <> int.to_string(stats.success_count)
      <> " | Partial: "
      <> int.to_string(stats.partial_count)
      <> " | Failure: "
      <> int.to_string(stats.failure_count)
      <> "\n"
      <> "Tokens in: "
      <> int.to_string(stats.total_tokens_in)
      <> " | out: "
      <> int.to_string(stats.total_tokens_out)
      <> "\n"
      <> "Total duration: "
      <> int.to_string(stats.total_duration_ms)
      <> "ms\n"
      <> "Tool failure rate: "
      <> float.to_string(stats.tool_failure_rate)
      <> "\n"
      <> "Models used: "
      <> string.join(stats.models_used, ", ")
      <> "\n"
      <> case stats.gate_decisions {
        [] -> ""
        gates ->
          "D' gates:\n"
          <> string.join(
            list.map(gates, fn(g) {
              "  - "
              <> g.gate
              <> ": "
              <> g.decision
              <> " (score: "
              <> float.to_string(g.score)
              <> ")"
            }),
            "\n",
          )
          <> "\n"
      }
      <> case stats.agent_failures {
        [] -> ""
        failures ->
          "Agent failures ("
          <> int.to_string(list.length(failures))
          <> "):\n"
          <> string.join(
            list.map(failures, fn(f: dag_types.AgentFailureRecord) {
              "  - "
              <> f.agent_model
              <> " ["
              <> string.slice(f.cycle_id, 0, 8)
              <> "]: "
              <> f.reason
            }),
            "\n",
          )
          <> "\n"
      }
  }
}

// ---------------------------------------------------------------------------
// inspect_cycle — drill into a specific cycle tree
// ---------------------------------------------------------------------------

fn run_inspect_cycle(
  call: ToolCall,
  lib: Option(Subject(LibrarianMessage)),
) -> ToolResult {
  case lib {
    None ->
      ToolFailure(
        tool_use_id: call.id,
        error: "inspect_cycle not available: DAG index not initialised",
      )
    Some(l) -> {
      let decoder = {
        use cycle_id <- decode.field("cycle_id", decode.string)
        decode.success(cycle_id)
      }
      case json.parse(call.input_json, decoder) {
        Error(_) ->
          ToolFailure(
            tool_use_id: call.id,
            error: "Invalid inspect_cycle input: missing cycle_id",
          )
        Ok(cycle_id) -> {
          let subj = process.new_subject()
          process.send(
            l,
            librarian.QueryNodeWithDescendants(cycle_id:, reply_to: subj),
          )
          case process.receive(subj, 5000) {
            Error(_) ->
              ToolFailure(
                tool_use_id: call.id,
                error: "Timeout querying cycle tree",
              )
            Ok(Error(_)) ->
              ToolSuccess(
                tool_use_id: call.id,
                content: "No cycle found with ID '" <> cycle_id <> "'",
              )
            Ok(Ok(subtree)) ->
              ToolSuccess(
                tool_use_id: call.id,
                content: format_subtree(subtree, 0),
              )
          }
        }
      }
    }
  }
}

fn format_subtree(tree: dag_types.DagSubtree, depth: Int) -> String {
  let indent = string.repeat("  ", depth)
  let node = tree.root
  let type_str = case node.node_type {
    dag_types.CognitiveCycle -> "cognitive"
    dag_types.AgentCycle -> "agent"
    dag_types.SchedulerCycle -> "scheduler"
  }
  let outcome_str = case node.outcome {
    dag_types.NodeSuccess -> "success"
    dag_types.NodePartial -> "partial"
    dag_types.NodeFailure(reason:) -> "failure: " <> reason
    dag_types.NodePending -> "pending"
  }
  let tools_str = case node.tool_calls {
    [] -> ""
    calls ->
      "\n"
      <> indent
      <> "  Tools: "
      <> string.join(
        list.map(calls, fn(t) {
          t.name
          <> case t.success {
            True -> ""
            False -> " (FAILED)"
          }
        }),
        ", ",
      )
  }
  let gates_str = case node.dprime_gates {
    [] -> ""
    gates ->
      "\n"
      <> indent
      <> "  D' gates: "
      <> string.join(
        list.map(gates, fn(g) { g.gate <> "=" <> g.decision }),
        ", ",
      )
  }
  let agent_str = case node.agent_output {
    None -> ""
    Some(dag_types.GenericOutput(notes:)) ->
      "\n" <> indent <> "  " <> string.join(notes, " | ")
    Some(dag_types.PlanOutput(steps:, ..)) ->
      "\n"
      <> indent
      <> "  Plan: "
      <> int.to_string(list.length(steps))
      <> " steps"
    Some(dag_types.ResearchOutput(facts:, sources:, ..)) ->
      "\n"
      <> indent
      <> "  Research: "
      <> int.to_string(list.length(facts))
      <> " facts, "
      <> int.to_string(sources)
      <> " sources"
    Some(dag_types.CoderOutput(files_touched:, ..)) ->
      "\n" <> indent <> "  Coder: " <> string.join(files_touched, ", ")
    Some(dag_types.WriterOutput(word_count:, format:, ..)) ->
      "\n"
      <> indent
      <> "  Writer: "
      <> int.to_string(word_count)
      <> " words ("
      <> format
      <> ")"
  }
  let tokens_str =
    " [tokens: "
    <> int.to_string(node.tokens_in)
    <> "/"
    <> int.to_string(node.tokens_out)
    <> "]"
  let header =
    indent
    <> "["
    <> type_str
    <> "] "
    <> node.cycle_id
    <> " — "
    <> outcome_str
    <> tokens_str
    <> case node.model {
      "" -> ""
      m -> " model=" <> m
    }
    <> tools_str
    <> gates_str
    <> agent_str
  let children_str = case tree.children {
    [] -> ""
    children ->
      "\n"
      <> string.join(
        list.map(children, fn(child) { format_subtree(child, depth + 1) }),
        "\n",
      )
  }
  header <> children_str
}

// ---------------------------------------------------------------------------
// recall_cases — CBR case retrieval
// ---------------------------------------------------------------------------

fn run_recall_cases(
  call: ToolCall,
  lib: Option(Subject(LibrarianMessage)),
  embed_config: embedding_types.EmbeddingConfig,
  cbr_max: Int,
) -> ToolResult {
  case lib {
    None ->
      ToolFailure(
        tool_use_id: call.id,
        error: "recall_cases not available: Librarian not initialised",
      )
    Some(l) -> {
      let decoder = {
        use intent <- decode.optional_field("intent", "", decode.string)
        use domain <- decode.optional_field("domain", "", decode.string)
        use keywords_str <- decode.optional_field("keywords", "", decode.string)
        use max_results <- decode.optional_field("max_results", 5, decode.int)
        decode.success(#(intent, domain, keywords_str, max_results))
      }
      case json.parse(call.input_json, decoder) {
        Error(_) ->
          ToolFailure(tool_use_id: call.id, error: "Invalid recall_cases input")
        Ok(#(intent, domain, keywords_str, max_results)) -> {
          let keywords = case keywords_str {
            "" -> []
            s ->
              s
              |> string.split(",")
              |> list.map(string.trim)
              |> list.filter(fn(k) { k != "" })
          }
          let clamped = int.min(cbr_max, int.max(1, max_results))
          // Embed the query text for semantic retrieval
          let query_text =
            intent <> " " <> domain <> " " <> string.join(keywords, " ")
          let query_embedding = case
            embedding_client.embed(embed_config, query_text)
          {
            Ok(result) -> Some(result.embedding)
            Error(_) -> None
          }
          let query =
            cbr_types.CbrQuery(
              intent:,
              domain:,
              keywords:,
              entities: [],
              embedding: query_embedding,
              max_results: clamped,
            )
          let results = librarian.retrieve_cases(l, query)
          case results {
            [] ->
              ToolSuccess(
                tool_use_id: call.id,
                content: "No matching cases found in CBR memory.",
              )
            _ ->
              ToolSuccess(
                tool_use_id: call.id,
                content: "Found "
                  <> int.to_string(list.length(results))
                  <> " matching cases:\n\n"
                  <> string.join(
                  list.map(results, format_scored_case),
                  "\n---\n",
                ),
              )
          }
        }
      }
    }
  }
}

fn format_scored_case(sc: cbr_types.ScoredCase) -> String {
  let c = sc.cbr_case
  let pitfalls = case c.outcome.pitfalls {
    [] -> ""
    ps -> "  Pitfalls: " <> string.join(ps, "; ") <> "\n"
  }
  let agents = case c.solution.agents_used {
    [] -> ""
    a -> "  Agents: " <> string.join(a, ", ") <> "\n"
  }
  let tools = case c.solution.tools_used {
    [] -> ""
    t -> "  Tools: " <> string.join(t, ", ") <> "\n"
  }
  let keywords = case c.problem.keywords {
    [] -> ""
    k -> "  Keywords: " <> string.join(k, ", ") <> "\n"
  }
  "[score: "
  <> float.to_string(sc.score)
  <> "] "
  <> c.problem.intent
  <> " | "
  <> c.problem.domain
  <> "\n"
  <> "  Query: "
  <> c.problem.user_input
  <> "\n"
  <> "  Approach: "
  <> c.solution.approach
  <> "\n"
  <> "  Outcome: "
  <> c.outcome.status
  <> " (confidence: "
  <> float.to_string(c.outcome.confidence)
  <> ")\n"
  <> case c.outcome.assessment {
    "" -> ""
    a -> "  Assessment: " <> a <> "\n"
  }
  <> pitfalls
  <> agents
  <> tools
  <> keywords
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

// ---------------------------------------------------------------------------
// introspect — perceive system state
// ---------------------------------------------------------------------------

fn run_introspect(call: ToolCall, ctx: Option(IntrospectContext)) -> ToolResult {
  case ctx {
    None ->
      ToolFailure(
        tool_use_id: call.id,
        error: "introspect not available: no context provided",
      )
    Some(c) -> {
      let sections = []

      // Identity
      let identity =
        "## Identity\n- agent_uuid: "
        <> c.agent_uuid
        <> "\n- session_since: "
        <> c.session_since

      // Profile
      let profile = case c.active_profile {
        Some(p) -> "\n- profile: " <> p
        None -> "\n- profile: (none)"
      }

      // Cycle
      let cycle = case c.current_cycle_id {
        Some(cid) -> "\n- current_cycle: " <> cid
        None -> ""
      }

      let sections = [identity <> profile <> cycle, ..sections]

      // Agent roster
      let agent_section = case c.agents {
        [] -> "## Agents\nNo agents registered."
        agents -> {
          let lines =
            list.map(agents, fn(e: AgentStatusEntry) {
              "- " <> e.name <> ": " <> e.status
            })
          "## Agents ("
          <> int.to_string(list.length(agents))
          <> ")\n"
          <> string.join(lines, "\n")
        }
      }
      let sections = [agent_section, ..sections]

      // D' safety
      let dprime_section = case c.dprime_enabled {
        True ->
          "## D' Safety\n- enabled: true\n- modify_threshold: "
          <> float.to_string(c.dprime_modify_threshold)
          <> "\n- reject_threshold: "
          <> float.to_string(c.dprime_reject_threshold)
        False -> "## D' Safety\n- enabled: false"
      }
      let sections = [dprime_section, ..sections]

      // Thread health
      let thread_section =
        "## Thread Health\n- total: "
        <> int.to_string(c.thread_total)
        <> "\n- named: "
        <> int.to_string(c.thread_total - c.thread_uuid_named)
        <> " | uuid-pattern: "
        <> int.to_string(c.thread_uuid_named)
        <> "\n- single-cycle: "
        <> int.to_string(c.thread_single_cycle)
        <> " | multi-cycle: "
        <> int.to_string(c.thread_multi_cycle)
      let sections = [thread_section, ..sections]

      ToolSuccess(
        tool_use_id: call.id,
        content: string.join(list.reverse(sections), "\n\n"),
      )
    }
  }
}

// ---------------------------------------------------------------------------
// list_recent_cycles — discover cycle IDs for a date
// ---------------------------------------------------------------------------

fn run_list_recent_cycles(
  call: ToolCall,
  lib: Option(Subject(LibrarianMessage)),
) -> ToolResult {
  case lib {
    None ->
      ToolFailure(
        tool_use_id: call.id,
        error: "list_recent_cycles not available: DAG index not initialised",
      )
    Some(l) -> {
      let decoder = {
        use date <- decode.optional_field("date", get_date(), decode.string)
        decode.success(date)
      }
      let date = case json.parse(call.input_json, decoder) {
        Ok(d) -> d
        Error(_) -> get_date()
      }
      let subj = process.new_subject()
      process.send(l, librarian.QueryDayRoots(date:, reply_to: subj))
      case process.receive(subj, 5000) {
        Error(_) ->
          ToolFailure(tool_use_id: call.id, error: "Timeout querying day roots")
        Ok(roots) ->
          case roots {
            [] ->
              ToolSuccess(
                tool_use_id: call.id,
                content: "No cycles found for " <> date <> ".",
              )
            _ -> {
              let lines =
                list.map(roots, fn(node: dag_types.CycleNode) {
                  let outcome_str = case node.outcome {
                    dag_types.NodeSuccess -> "success"
                    dag_types.NodePartial -> "partial"
                    dag_types.NodeFailure(reason:) -> "failure: " <> reason
                    dag_types.NodePending -> "pending"
                  }
                  node.cycle_id
                  <> " ["
                  <> node.timestamp
                  <> "] "
                  <> outcome_str
                  <> " [tokens: "
                  <> int.to_string(node.tokens_in)
                  <> "/"
                  <> int.to_string(node.tokens_out)
                  <> "]"
                })
              ToolSuccess(
                tool_use_id: call.id,
                content: "Cycles for "
                  <> date
                  <> " ("
                  <> int.to_string(list.length(roots))
                  <> "):\n"
                  <> string.join(lines, "\n"),
              )
            }
          }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// query_tool_activity — per-tool usage stats from DAG
// ---------------------------------------------------------------------------

fn run_query_tool_activity(
  call: ToolCall,
  lib: Option(Subject(LibrarianMessage)),
) -> ToolResult {
  case lib {
    None ->
      ToolFailure(
        tool_use_id: call.id,
        error: "query_tool_activity not available: Librarian not initialised",
      )
    Some(l) -> {
      let decoder = {
        use date <- decode.field("date", decode.string)
        decode.success(date)
      }
      case json.parse(call.input_json, decoder) {
        Error(_) ->
          ToolFailure(
            tool_use_id: call.id,
            error: "Invalid query_tool_activity input: requires 'date' field",
          )
        Ok(date) -> {
          let records = librarian.query_tool_activity(l, date)
          case records {
            [] ->
              ToolSuccess(
                tool_use_id: call.id,
                content: "No tool activity found for " <> date,
              )
            _ -> {
              let lines =
                list.map(records, fn(r: dag_types.ToolActivityRecord) {
                  r.name
                  <> ": "
                  <> int.to_string(r.total_calls)
                  <> " calls ("
                  <> int.to_string(r.success_count)
                  <> " ok, "
                  <> int.to_string(r.failure_count)
                  <> " failed) in "
                  <> int.to_string(list.length(r.cycle_ids))
                  <> " cycles"
                })
              ToolSuccess(
                tool_use_id: call.id,
                content: "Tool activity for "
                  <> date
                  <> ":\n"
                  <> string.join(lines, "\n"),
              )
            }
          }
        }
      }
    }
  }
}
