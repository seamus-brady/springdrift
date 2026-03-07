//// Memory tools — query the narrative log for past research cycles.
////
//// These tools let the cognitive loop interrogate its own memory:
//// what it worked on yesterday, last week, or for a specific topic.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import llm/tool
import llm/types.{
  type Tool, type ToolCall, type ToolResult, ToolFailure, ToolSuccess,
}
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
  [recall_recent_tool(), recall_search_tool(), recall_threads_tool()]
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

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

/// Check if a tool call is a memory tool.
pub fn is_memory_tool(name: String) -> Bool {
  name == "recall_recent" || name == "recall_search" || name == "recall_threads"
}

/// Execute a memory tool call. Requires the narrative directory path.
pub fn execute(call: ToolCall, narrative_dir: String) -> ToolResult {
  slog.debug("memory", "execute", "tool=" <> call.name, None)
  case call.name {
    "recall_recent" -> run_recall_recent(call, narrative_dir)
    "recall_search" -> run_recall_search(call, narrative_dir)
    "recall_threads" -> run_recall_threads(call, narrative_dir)
    _ -> ToolFailure(tool_use_id: call.id, error: "Unknown tool: " <> call.name)
  }
}

// ---------------------------------------------------------------------------
// recall_recent
// ---------------------------------------------------------------------------

fn run_recall_recent(call: ToolCall, dir: String) -> ToolResult {
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
      let entries = narrative_log.load_entries(dir, from, to)
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

fn run_recall_search(call: ToolCall, dir: String) -> ToolResult {
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
      let entries = narrative_log.search(dir, query)
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

fn run_recall_threads(call: ToolCall, dir: String) -> ToolResult {
  let index = narrative_log.load_thread_index(dir)
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
