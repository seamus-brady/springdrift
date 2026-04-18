//// Remembrancer tools — deep memory operations reading the full JSONL archive.
////
//// All tools bypass the Librarian's ETS window and read directly from disk,
//// since the Remembrancer works with months of history, not days.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import dprime/decay
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
import paths
import remembrancer/consolidation
import remembrancer/query as rquery
import remembrancer/reader as rreader
import skills/pattern as skills_pattern
import skills/proposal_log
import slog

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

@external(erlang, "springdrift_ffi", "days_ago_date")
fn days_ago(n: Int) -> String

@external(erlang, "springdrift_ffi", "generate_uuid")
fn uuid_v4() -> String

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

pub type RemembrancerContext {
  RemembrancerContext(
    narrative_dir: String,
    cbr_dir: String,
    facts_dir: String,
    knowledge_consolidation_dir: String,
    consolidation_log_dir: String,
    cycle_id: String,
    agent_id: String,
    librarian: Option(Subject(LibrarianMessage)),
    review_confidence_threshold: Float,
    dormant_thread_days: Int,
    min_pattern_cases: Int,
    /// Half-life (days) for fact confidence decay. Used when computing
    /// decayed_facts_count at consolidation write time.
    fact_decay_half_life_days: Int,
  )
}

// ---------------------------------------------------------------------------
// Tool set
// ---------------------------------------------------------------------------

pub fn all() -> List(Tool) {
  [
    deep_search_tool(),
    fact_archaeology_tool(),
    mine_patterns_tool(),
    propose_skills_from_patterns_tool(),
    resurrect_thread_tool(),
    consolidate_memory_tool(),
    restore_confidence_tool(),
    find_connections_tool(),
    write_consolidation_report_tool(),
  ]
}

pub fn is_remembrancer_tool(name: String) -> Bool {
  name == "deep_search"
  || name == "fact_archaeology"
  || name == "mine_patterns"
  || name == "propose_skills_from_patterns"
  || name == "resurrect_thread"
  || name == "consolidate_memory"
  || name == "restore_confidence"
  || name == "find_connections"
  || name == "write_consolidation_report"
}

fn deep_search_tool() -> Tool {
  tool.new("deep_search")
  |> tool.with_description(
    "Search narrative memory across months or years. Unlike recall_search "
    <> "(recent entries only), deep_search traverses the full archive by "
    <> "reading JSONL files directly from disk. Use for historical precedent, "
    <> "long-term patterns, and knowledge older than the Librarian's window.",
  )
  |> tool.add_string_param("query", "Search terms (space-separated)", True)
  |> tool.add_string_param(
    "from_date",
    "Start date YYYY-MM-DD (default: 90 days ago)",
    False,
  )
  |> tool.add_string_param(
    "to_date",
    "End date YYYY-MM-DD (default: today)",
    False,
  )
  |> tool.add_integer_param(
    "max_results",
    "Maximum entries to return (default: 20)",
    False,
  )
  |> tool.build()
}

fn fact_archaeology_tool() -> Tool {
  tool.new("fact_archaeology")
  |> tool.with_description(
    "Trace the complete history of a fact key across all time — every write, "
    <> "supersession, deletion, and conflict. Shows how belief changed over "
    <> "time. Also finds related keys by substring match.",
  )
  |> tool.add_string_param("key", "Fact key to trace", True)
  |> tool.add_boolean_param(
    "include_related",
    "Also find keys containing the same tokens (default: true)",
    False,
  )
  |> tool.build()
}

fn mine_patterns_tool() -> Tool {
  tool.new("mine_patterns")
  |> tool.with_description(
    "Scan CBR cases for clusters of similar cases sharing a domain and "
    <> "keywords. Returns proposed patterns with supporting case IDs and "
    <> "average outcome confidence. Useful for identifying recurring "
    <> "approaches or pitfalls worth codifying.",
  )
  |> tool.add_string_param(
    "domain",
    "Domain to mine, or 'all' for every domain (default: all)",
    False,
  )
  |> tool.add_integer_param(
    "min_cases",
    "Minimum cases to form a pattern (default: from config)",
    False,
  )
  |> tool.build()
}

fn resurrect_thread_tool() -> Tool {
  tool.new("resurrect_thread")
  |> tool.with_description(
    "Find dormant research threads (no activity for N days) that may connect "
    <> "to a current topic. Returns thread names, domains, and keywords so you "
    <> "can judge relevance.",
  )
  |> tool.add_string_param(
    "topic",
    "Current topic to match against (optional — empty lists all dormant)",
    False,
  )
  |> tool.add_integer_param(
    "dormant_days",
    "Minimum days of inactivity (default: from config)",
    False,
  )
  |> tool.build()
}

fn consolidate_memory_tool() -> Tool {
  tool.new("consolidate_memory")
  |> tool.with_description(
    "Gather statistics and excerpts from narrative entries, CBR cases, and "
    <> "facts in a date range. Returns the material you need to synthesise a "
    <> "consolidation summary. After reviewing, write the summary yourself and "
    <> "persist it with write_consolidation_report.",
  )
  |> tool.add_string_param("from_date", "Start date YYYY-MM-DD", True)
  |> tool.add_string_param("to_date", "End date YYYY-MM-DD", True)
  |> tool.add_string_param(
    "focus",
    "Optional focus domain or topic to bias the excerpts",
    False,
  )
  |> tool.build()
}

fn restore_confidence_tool() -> Tool {
  tool.new("restore_confidence")
  |> tool.with_description(
    "Restore confidence on a fact you have re-verified. Writes a new "
    <> "persistent fact supersedes-entry with the new confidence. Use only "
    <> "after checking that the fact's content is still accurate.",
  )
  |> tool.add_string_param("key", "Fact key", True)
  |> tool.add_string_param("value", "Current (re-verified) value", True)
  |> tool.add_number_param(
    "new_confidence",
    "Restored confidence 0.0-1.0",
    True,
  )
  |> tool.add_string_param("reason", "Why confidence was restored", True)
  |> tool.build()
}

fn find_connections_tool() -> Tool {
  tool.new("find_connections")
  |> tool.with_description(
    "Cross-reference a topic across narrative entries, CBR cases, and facts. "
    <> "Returns hit counts per store, domains touched, and the date range of "
    <> "matches.",
  )
  |> tool.add_string_param("topic", "Central topic", True)
  |> tool.add_string_param(
    "from_date",
    "Start date YYYY-MM-DD (default: 180 days ago)",
    False,
  )
  |> tool.add_string_param(
    "to_date",
    "End date YYYY-MM-DD (default: today)",
    False,
  )
  |> tool.build()
}

fn write_consolidation_report_tool() -> Tool {
  tool.new("write_consolidation_report")
  |> tool.with_description(
    "Persist a consolidation report as markdown to "
    <> ".springdrift/knowledge/consolidation/ and append a run record to "
    <> "the consolidation log. Call this after synthesising the findings from "
    <> "consolidate_memory.",
  )
  |> tool.add_string_param(
    "name",
    "Short report name (slugified into filename)",
    True,
  )
  |> tool.add_string_param("from_date", "Period start date YYYY-MM-DD", True)
  |> tool.add_string_param("to_date", "Period end date YYYY-MM-DD", True)
  |> tool.add_string_param("summary", "One-paragraph summary", True)
  |> tool.add_string_param("body_markdown", "Full markdown report body", True)
  |> tool.add_integer_param(
    "patterns_found",
    "Number of patterns identified",
    False,
  )
  |> tool.add_integer_param("facts_restored", "Number of facts restored", False)
  |> tool.add_integer_param(
    "threads_resurrected",
    "Number of threads resurrected",
    False,
  )
  |> tool.build()
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

pub fn execute(call: ToolCall, ctx: RemembrancerContext) -> ToolResult {
  case call.name {
    "deep_search" -> run_deep_search(call, ctx)
    "fact_archaeology" -> run_fact_archaeology(call, ctx)
    "mine_patterns" -> run_mine_patterns(call, ctx)
    "propose_skills_from_patterns" ->
      run_propose_skills_from_patterns(call, ctx)
    "resurrect_thread" -> run_resurrect_thread(call, ctx)
    "consolidate_memory" -> run_consolidate_memory(call, ctx)
    "restore_confidence" -> run_restore_confidence(call, ctx)
    "find_connections" -> run_find_connections(call, ctx)
    "write_consolidation_report" -> run_write_report(call, ctx)
    _ ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Unknown remembrancer tool: " <> call.name,
      )
  }
}

// ---------------------------------------------------------------------------
// deep_search
// ---------------------------------------------------------------------------

fn run_deep_search(call: ToolCall, ctx: RemembrancerContext) -> ToolResult {
  let decoder = {
    use query <- decode.field("query", decode.string)
    use from_date <- decode.field(
      "from_date",
      decode.optional(decode.string)
        |> decode.map(fn(o) { option.unwrap(o, "") }),
    )
    use to_date <- decode.field(
      "to_date",
      decode.optional(decode.string)
        |> decode.map(fn(o) { option.unwrap(o, "") }),
    )
    use max_results <- decode.field(
      "max_results",
      decode.optional(decode.int) |> decode.map(fn(o) { option.unwrap(o, 20) }),
    )
    decode.success(#(query, from_date, to_date, max_results))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Invalid deep_search input")
    Ok(#(query, from_in, to_in, max_results)) -> {
      let from_date = case from_in {
        "" -> days_ago(90)
        s -> s
      }
      let to_date = case to_in {
        "" -> get_date()
        s -> s
      }
      let entries =
        rreader.read_narrative_entries(ctx.narrative_dir, from_date, to_date)
      let matches =
        rquery.search_entries(entries, query)
        |> list.take(max_results)
      let header =
        "deep_search: \""
        <> query
        <> "\" ["
        <> from_date
        <> " → "
        <> to_date
        <> "] — "
        <> int.to_string(list.length(matches))
        <> " match(es)\n"
      let body =
        list.map(matches, fn(e) {
          "  " <> e.timestamp <> " — " <> summarise_line(e.summary, 120)
        })
        |> string.join("\n")
      ToolSuccess(tool_use_id: call.id, content: header <> body)
    }
  }
}

// ---------------------------------------------------------------------------
// fact_archaeology
// ---------------------------------------------------------------------------

fn run_fact_archaeology(call: ToolCall, ctx: RemembrancerContext) -> ToolResult {
  let decoder = {
    use key <- decode.field("key", decode.string)
    use include_related <- decode.field(
      "include_related",
      decode.optional(decode.bool)
        |> decode.map(fn(o) { option.unwrap(o, True) }),
    )
    decode.success(#(key, include_related))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Invalid fact_archaeology input")
    Ok(#(key, include_related)) -> {
      let all_facts = facts_log.load_all(ctx.facts_dir)
      let traces = rquery.trace_fact_key(all_facts, key)
      let related = case include_related {
        True -> rquery.find_related_facts(all_facts, key)
        False -> []
      }
      let header =
        "fact_archaeology: \""
        <> key
        <> "\"\n  Timeline: "
        <> int.to_string(list.length(traces))
        <> " version(s)\n  Related keys: "
        <> int.to_string(list.length(related))
        <> "\n"
      let timeline =
        list.map(traces, fn(f) {
          "  "
          <> f.timestamp
          <> " ["
          <> fact_op(f.operation)
          <> "] "
          <> f.value
          <> " (confidence: "
          <> float.to_string(f.confidence)
          <> ")"
        })
        |> string.join("\n")
      let related_block = case related {
        [] -> ""
        rs -> {
          let keys =
            list.map(rs, fn(f) { f.key })
            |> list.unique
            |> list.take(20)
          "\n  Related keys: " <> string.join(keys, ", ")
        }
      }
      ToolSuccess(
        tool_use_id: call.id,
        content: header <> timeline <> related_block,
      )
    }
  }
}

fn fact_op(op: facts_types.FactOp) -> String {
  case op {
    facts_types.Write -> "write"
    facts_types.Clear -> "clear"
    facts_types.Superseded -> "superseded"
  }
}

// ---------------------------------------------------------------------------
// mine_patterns
// ---------------------------------------------------------------------------

fn run_mine_patterns(call: ToolCall, ctx: RemembrancerContext) -> ToolResult {
  let decoder = {
    use domain <- decode.field(
      "domain",
      decode.optional(decode.string)
        |> decode.map(fn(o) { option.unwrap(o, "all") }),
    )
    use min_cases <- decode.field(
      "min_cases",
      decode.optional(decode.int)
        |> decode.map(fn(o) { option.unwrap(o, ctx.min_pattern_cases) }),
    )
    decode.success(#(domain, min_cases))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Invalid mine_patterns input")
    Ok(#(domain_filter, min_cases)) -> {
      let all_cases = rreader.read_all_cases(ctx.cbr_dir)
      let scoped = case domain_filter {
        "all" -> all_cases
        d -> list.filter(all_cases, fn(c) { c.problem.domain == d })
      }
      let clusters = rquery.cluster_cases(scoped, min_cases)
      let header =
        "mine_patterns: "
        <> int.to_string(list.length(clusters))
        <> " cluster(s) found (min_cases="
        <> int.to_string(min_cases)
        <> ", domain="
        <> domain_filter
        <> ")\n"
      let body =
        list.map(clusters, rquery.format_cluster)
        |> string.join("\n")
      ToolSuccess(tool_use_id: call.id, content: header <> body)
    }
  }
}

// ---------------------------------------------------------------------------
// propose_skills_from_patterns — Phase 7 of skills-management
// ---------------------------------------------------------------------------

fn propose_skills_from_patterns_tool() -> Tool {
  tool.new("propose_skills_from_patterns")
  |> tool.with_description(
    "Mine CBR cases for clusters that qualify as new skill proposals (per "
    <> "the skills-management spec — Jaccard on tools_used and agents_used, "
    <> "domain coherence, mean confidence × utility floor). Each qualifying "
    <> "cluster produces a SkillProposal with an auto-derived name, "
    <> "description, body skeleton, and supporting case IDs. Proposals are "
    <> "appended to the per-day skills log. The Promotion Safety Gate (D' "
    <> "scorer + rate limit, separate phase) decides which proposals "
    <> "promote to Active skills.",
  )
  |> tool.add_string_param(
    "domain",
    "Domain to mine, or 'all' for every domain (default: all)",
    False,
  )
  |> tool.add_integer_param(
    "min_cases",
    "Minimum cases to qualify a cluster (default: from config)",
    False,
  )
  |> tool.add_number_param(
    "min_utility",
    "Minimum mean confidence × utility (default: 0.70)",
    False,
  )
  |> tool.build()
}

fn run_propose_skills_from_patterns(
  call: ToolCall,
  ctx: RemembrancerContext,
) -> ToolResult {
  let decoder = {
    use domain <- decode.field(
      "domain",
      decode.optional(decode.string)
        |> decode.map(fn(o) { option.unwrap(o, "all") }),
    )
    use min_cases <- decode.field(
      "min_cases",
      decode.optional(decode.int)
        |> decode.map(fn(o) { option.unwrap(o, ctx.min_pattern_cases) }),
    )
    use min_utility <- decode.field(
      "min_utility",
      decode.optional(number_decoder())
        |> decode.map(fn(o) { option.unwrap(o, 0.7) }),
    )
    decode.success(#(domain, min_cases, min_utility))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid propose_skills_from_patterns input",
      )
    Ok(#(domain_filter, min_cases, min_utility)) -> {
      let all_cases = rreader.read_all_cases(ctx.cbr_dir)
      let scoped = case domain_filter {
        "all" -> all_cases
        d -> list.filter(all_cases, fn(c) { c.problem.domain == d })
      }
      let cfg =
        skills_pattern.PatternConfig(
          ..skills_pattern.default_config(),
          min_cases: min_cases,
          min_utility: min_utility,
        )
      let clusters = skills_pattern.find_clusters(scoped, cfg)
      // Novelty check is structural only in PR-C — no skills loaded here.
      // PR-D's gate runs the LLM-driven conflict classifier with full
      // access to existing Active skills.
      let proposals =
        skills_pattern.clusters_to_proposals(
          clusters,
          [],
          get_datetime(),
          ctx.agent_id,
        )
      let dir = paths.skills_log_dir()
      list.each(proposals, fn(p) { proposal_log.append_proposed(dir, p) })
      let summary =
        "propose_skills_from_patterns: "
        <> int.to_string(list.length(clusters))
        <> " cluster(s), "
        <> int.to_string(list.length(proposals))
        <> " proposal(s) logged to "
        <> dir
        <> "\n\nDomain filter: "
        <> domain_filter
        <> "\nMin cases: "
        <> int.to_string(min_cases)
        <> "\nMin utility: "
        <> float.to_string(min_utility)
        <> case proposals {
          [] -> "\n\nNo qualifying proposals."
          _ ->
            "\n\nProposals:\n"
            <> string.join(
              list.map(proposals, fn(p) { "  - " <> p.name }),
              "\n",
            )
        }
      ToolSuccess(tool_use_id: call.id, content: summary)
    }
  }
}

fn number_decoder() -> decode.Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

// ---------------------------------------------------------------------------
// resurrect_thread
// ---------------------------------------------------------------------------

fn run_resurrect_thread(call: ToolCall, ctx: RemembrancerContext) -> ToolResult {
  let decoder = {
    use topic <- decode.field(
      "topic",
      decode.optional(decode.string)
        |> decode.map(fn(o) { option.unwrap(o, "") }),
    )
    use dormant_days <- decode.field(
      "dormant_days",
      decode.optional(decode.int)
        |> decode.map(fn(o) { option.unwrap(o, ctx.dormant_thread_days) }),
    )
    decode.success(#(topic, dormant_days))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Invalid resurrect_thread input")
    Ok(#(topic, dormant_days)) -> {
      let from_date = days_ago(365)
      let to_date = get_date()
      let entries =
        rreader.read_narrative_entries(ctx.narrative_dir, from_date, to_date)
      let cutoff = days_ago(dormant_days)
      let dormant = rquery.find_dormant_threads(entries, cutoff)
      let filtered = case topic {
        "" -> dormant
        t -> {
          let t_lower = string.lowercase(t)
          list.filter(dormant, fn(d) {
            let hay =
              string.lowercase(string.join(d.keywords, " "))
              <> " "
              <> string.lowercase(string.join(d.domains, " "))
              <> " "
              <> string.lowercase(d.thread_name)
            string.contains(hay, t_lower)
          })
        }
      }
      let header =
        "resurrect_thread: "
        <> int.to_string(list.length(filtered))
        <> " dormant thread(s) (>"
        <> int.to_string(dormant_days)
        <> " days) matching \""
        <> topic
        <> "\"\n"
      let body =
        list.map(filtered, rquery.format_dormant_thread)
        |> string.join("\n\n")
      ToolSuccess(tool_use_id: call.id, content: header <> body)
    }
  }
}

// ---------------------------------------------------------------------------
// consolidate_memory
// ---------------------------------------------------------------------------

fn run_consolidate_memory(
  call: ToolCall,
  ctx: RemembrancerContext,
) -> ToolResult {
  let decoder = {
    use from_date <- decode.field("from_date", decode.string)
    use to_date <- decode.field("to_date", decode.string)
    use focus <- decode.field(
      "focus",
      decode.optional(decode.string)
        |> decode.map(fn(o) { option.unwrap(o, "") }),
    )
    decode.success(#(from_date, to_date, focus))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid consolidate_memory input",
      )
    Ok(#(from_date, to_date, focus)) -> {
      let entries =
        rreader.read_narrative_entries(ctx.narrative_dir, from_date, to_date)
      let cases = rreader.read_all_cases(ctx.cbr_dir)
      let facts = rreader.read_facts(ctx.facts_dir, from_date, to_date)
      let relevant_entries = case focus {
        "" -> list.take(entries, 30)
        f -> list.take(rquery.search_entries(entries, f), 30)
      }
      let relevant_cases = case focus {
        "" -> list.take(cases, 20)
        f -> {
          let f_lower = string.lowercase(f)
          list.filter(cases, fn(c) {
            string.contains(string.lowercase(c.problem.domain), f_lower)
            || list.any(c.problem.keywords, fn(k) {
              string.contains(string.lowercase(k), f_lower)
            })
          })
          |> list.take(20)
        }
      }
      let decayed =
        list.filter(facts, fn(f) {
          f.confidence <. ctx.review_confidence_threshold
        })
      let header =
        "consolidate_memory ["
        <> from_date
        <> " → "
        <> to_date
        <> "]"
        <> case focus {
          "" -> ""
          f -> " focus=\"" <> f <> "\""
        }
        <> "\n  Narrative entries in period: "
        <> int.to_string(list.length(entries))
        <> " (showing "
        <> int.to_string(list.length(relevant_entries))
        <> ")\n  CBR cases considered: "
        <> int.to_string(list.length(relevant_cases))
        <> "\n  Facts in period: "
        <> int.to_string(list.length(facts))
        <> " (decayed <"
        <> float.to_string(ctx.review_confidence_threshold)
        <> ": "
        <> int.to_string(list.length(decayed))
        <> ")\n\n"
      let entries_section =
        "== Narrative excerpts ==\n"
        <> {
          list.map(relevant_entries, fn(e) {
            "  " <> e.timestamp <> " — " <> summarise_line(e.summary, 160)
          })
          |> string.join("\n")
        }
      let cases_section =
        "\n\n== CBR case excerpts ==\n"
        <> {
          list.map(relevant_cases, fn(c) {
            "  "
            <> c.timestamp
            <> " ["
            <> c.problem.domain
            <> "] "
            <> summarise_line(c.problem.intent, 120)
          })
          |> string.join("\n")
        }
      let decayed_section = case decayed {
        [] -> ""
        ds ->
          "\n\n== Decayed facts worth reviewing ==\n"
          <> {
            list.take(ds, 15)
            |> list.map(fn(f) {
              "  "
              <> f.key
              <> " = "
              <> summarise_line(f.value, 80)
              <> " (confidence: "
              <> float.to_string(f.confidence)
              <> ")"
            })
            |> string.join("\n")
          }
      }
      ToolSuccess(
        tool_use_id: call.id,
        content: header <> entries_section <> cases_section <> decayed_section,
      )
    }
  }
}

// ---------------------------------------------------------------------------
// restore_confidence
// ---------------------------------------------------------------------------

fn run_restore_confidence(
  call: ToolCall,
  ctx: RemembrancerContext,
) -> ToolResult {
  let number_decoder =
    decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
  let decoder = {
    use key <- decode.field("key", decode.string)
    use value <- decode.field("value", decode.string)
    use new_confidence <- decode.field("new_confidence", number_decoder)
    use reason <- decode.field("reason", decode.string)
    decode.success(#(key, value, new_confidence, reason))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid restore_confidence input",
      )
    Ok(#(key, value, new_confidence, reason)) -> {
      let trimmed_key = string.trim(key)
      case trimmed_key {
        "" -> ToolFailure(tool_use_id: call.id, error: "key must not be empty")
        _ -> {
          let clamped = float.min(1.0, float.max(0.0, new_confidence))
          // Look up the prior fact so the new fact can reference it in
          // supersedes. This preserves the audit chain — fact_archaeology
          // can trace the supersession link cleanly instead of inferring
          // from timestamps alone.
          let prior =
            facts_log.resolve_current(ctx.facts_dir, option.None)
            |> list.find(fn(f) { f.key == trimmed_key })
          let supersedes_id = case prior {
            Ok(old) -> Some(old.fact_id)
            Error(_) -> None
          }
          let fact =
            facts_types.MemoryFact(
              schema_version: 1,
              fact_id: "fact-" <> uuid_v4(),
              timestamp: get_datetime(),
              cycle_id: ctx.cycle_id,
              agent_id: Some(ctx.agent_id),
              key: trimmed_key,
              value:,
              scope: facts_types.Persistent,
              operation: facts_types.Write,
              supersedes: supersedes_id,
              confidence: clamped,
              source: "remembrancer:restore_confidence",
              provenance: Some(facts_types.FactProvenance(
                source_cycle_id: ctx.cycle_id,
                source_tool: "restore_confidence",
                source_agent: "remembrancer",
                derivation: facts_types.Synthesis,
              )),
            )
          facts_log.append(ctx.facts_dir, fact)
          case ctx.librarian {
            Some(l) -> librarian.notify_new_fact(l, fact)
            None -> Nil
          }
          slog.info(
            "tools/remembrancer",
            "restore_confidence",
            "Restored "
              <> trimmed_key
              <> " → "
              <> float.to_string(clamped)
              <> " (reason: "
              <> reason
              <> case supersedes_id {
              Some(old_id) -> ", supersedes " <> old_id
              None -> ", no prior version"
            }
              <> ")",
            Some(ctx.cycle_id),
          )
          let chain_note = case supersedes_id {
            Some(old_id) -> " (supersedes " <> old_id <> ")"
            None -> " (no prior version found)"
          }
          ToolSuccess(
            tool_use_id: call.id,
            content: "Restored confidence on \""
              <> trimmed_key
              <> "\" to "
              <> float.to_string(clamped)
              <> chain_note,
          )
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// find_connections
// ---------------------------------------------------------------------------

fn run_find_connections(call: ToolCall, ctx: RemembrancerContext) -> ToolResult {
  let decoder = {
    use topic <- decode.field("topic", decode.string)
    use from_date <- decode.field(
      "from_date",
      decode.optional(decode.string)
        |> decode.map(fn(o) { option.unwrap(o, "") }),
    )
    use to_date <- decode.field(
      "to_date",
      decode.optional(decode.string)
        |> decode.map(fn(o) { option.unwrap(o, "") }),
    )
    decode.success(#(topic, from_date, to_date))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Invalid find_connections input")
    Ok(#(topic, from_in, to_in)) -> {
      let from_date = case from_in {
        "" -> days_ago(180)
        s -> s
      }
      let to_date = case to_in {
        "" -> get_date()
        s -> s
      }
      let entries =
        rreader.read_narrative_entries(ctx.narrative_dir, from_date, to_date)
      let cases = rreader.read_all_cases(ctx.cbr_dir)
      let facts = rreader.read_facts(ctx.facts_dir, from_date, to_date)
      let xref = rquery.cross_reference(topic, entries, cases, facts)
      ToolSuccess(
        tool_use_id: call.id,
        content: rquery.format_cross_reference(xref),
      )
    }
  }
}

// ---------------------------------------------------------------------------
// write_consolidation_report
// ---------------------------------------------------------------------------

fn run_write_report(call: ToolCall, ctx: RemembrancerContext) -> ToolResult {
  let decoder = {
    use name <- decode.field("name", decode.string)
    use from_date <- decode.field("from_date", decode.string)
    use to_date <- decode.field("to_date", decode.string)
    use summary <- decode.field("summary", decode.string)
    use body_markdown <- decode.field("body_markdown", decode.string)
    use patterns_found <- decode.field(
      "patterns_found",
      decode.optional(decode.int) |> decode.map(fn(o) { option.unwrap(o, 0) }),
    )
    use facts_restored <- decode.field(
      "facts_restored",
      decode.optional(decode.int) |> decode.map(fn(o) { option.unwrap(o, 0) }),
    )
    use threads_resurrected <- decode.field(
      "threads_resurrected",
      decode.optional(decode.int) |> decode.map(fn(o) { option.unwrap(o, 0) }),
    )
    decode.success(#(
      name,
      from_date,
      to_date,
      summary,
      body_markdown,
      patterns_found,
      facts_restored,
      threads_resurrected,
    ))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid write_consolidation_report input",
      )
    Ok(#(
      name,
      from_date,
      to_date,
      summary,
      body_markdown,
      patterns_found,
      facts_restored,
      threads_resurrected,
    )) -> {
      case
        consolidation.write_report(
          ctx.knowledge_consolidation_dir,
          name,
          body_markdown,
        )
      {
        Error(e) ->
          ToolFailure(
            tool_use_id: call.id,
            error: "Failed to write report: " <> e,
          )
        Ok(path) -> {
          let decayed_facts_count = count_decayed_facts(ctx)
          let dormant_threads_count = count_dormant_threads(ctx)
          let base = consolidation.new_run(from_date, to_date, summary)
          let run =
            consolidation.ConsolidationRun(
              ..base,
              patterns_found:,
              facts_restored:,
              threads_resurrected:,
              report_path: path,
              decayed_facts_count:,
              dormant_threads_count:,
            )
          consolidation.append(ctx.consolidation_log_dir, run)
          ToolSuccess(
            tool_use_id: call.id,
            content: "Consolidation report written to "
              <> path
              <> " (decayed_facts="
              <> int.to_string(decayed_facts_count)
              <> ", dormant_threads="
              <> int.to_string(dormant_threads_count)
              <> ")",
          )
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn summarise_line(s: String, max_chars: Int) -> String {
  let single_line =
    s
    |> string.replace("\n", " ")
    |> string.replace("\r", " ")
  case string.length(single_line) <= max_chars {
    True -> single_line
    False -> string.slice(single_line, 0, max_chars) <> "…"
  }
}

/// Count persistent facts whose effective (post-decay) confidence is below
/// the review threshold. Uses `facts_log.resolve_current` to consider only
/// live facts, then applies the half-life decay formula.
fn count_decayed_facts(ctx: RemembrancerContext) -> Int {
  let today = get_date()
  facts_log.resolve_current(ctx.facts_dir, option.None)
  |> list.filter(fn(f) {
    let effective =
      decay.decay_fact_confidence(
        f.confidence,
        f.timestamp,
        today,
        ctx.fact_decay_half_life_days,
      )
    effective <. ctx.review_confidence_threshold
  })
  |> list.length
}

/// Count threads in the past year with no activity for >= dormant_thread_days.
fn count_dormant_threads(ctx: RemembrancerContext) -> Int {
  let from_date = days_ago(365)
  let to_date = get_date()
  let entries =
    rreader.read_narrative_entries(ctx.narrative_dir, from_date, to_date)
  let cutoff = days_ago(ctx.dormant_thread_days)
  rquery.find_dormant_threads(entries, cutoff)
  |> list.length
}
