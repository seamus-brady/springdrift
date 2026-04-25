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

import affect/correlation as affect_correlation
import affect/store as affect_store
import cbr/log as cbr_log
import cbr/types as cbr_types
import dprime/decay
import facts/log as facts_log
import facts/types as facts_types
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import knowledge/indexer as knowledge_indexer
import knowledge/log as knowledge_log
import knowledge/search as knowledge_search
import knowledge/types as knowledge_types
import learning_goal/log as goal_log
import learning_goal/types as goal_types
import llm/provider
import llm/tool
import llm/types.{
  type Tool, type ToolCall, type ToolResult, ToolFailure, ToolSuccess,
}
import meta_learning/fabrication_audit
import meta_learning/voice_drift
import narrative/librarian.{type LibrarianMessage}
import paths
import remembrancer/consolidation
import remembrancer/query as rquery
import remembrancer/reader as rreader
import skills
import skills/body_gen as skills_body_gen
import skills/pattern as skills_pattern
import skills/proposal_log
import skills/safety_gate
import slog
import strategy/log as strategy_log
import strategy/types as strategy_types
import xstructor
import xstructor/schemas

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
    /// Provider used by the skills safety gate when evaluating
    /// auto-generated proposals. None disables the LLM scorer
    /// (deterministic + rate limit still run).
    gate_provider: Option(provider.Provider),
    /// Model name for the safety gate LLM scorer.
    gate_model: String,
    /// Directory where Accepted skill proposals are written
    /// (typically `.springdrift/skills/`).
    skills_dir: String,
    /// Phase E + F follow-up. Maximum knowledge promotions
    /// (`promote_insight` writes) per rolling 24-hour window.
    max_promotions_per_day: Int,
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
    analyze_affect_performance_tool(),
    extract_insights_tool(),
    promote_insight_tool(),
    propose_strategies_from_patterns_tool(),
    propose_learning_goals_from_patterns_tool(),
    import_legacy_strategy_facts_tool(),
    write_consolidation_report_tool(),
    audit_fabrication_tool(),
    audit_voice_drift_tool(),
    study_document_tool(),
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
  || name == "analyze_affect_performance"
  || name == "extract_insights"
  || name == "promote_insight"
  || name == "propose_strategies_from_patterns"
  || name == "propose_learning_goals_from_patterns"
  || name == "import_legacy_strategy_facts"
  || name == "write_consolidation_report"
  || name == "audit_fabrication"
  || name == "audit_voice_drift"
  || name == "study_document"
}

/// Default cap on facts persisted from a single study_document call.
/// Bounds disk + memory usage if a paper yields lots of extractable
/// claims and prevents a single call dominating the facts store.
pub const study_default_max_facts: Int = 30

/// Confidence floor for facts extracted by study_document. Facts the
/// LLM emits with lower confidence are filtered before persisting.
/// Below 0.6 means "the model itself wasn't sure" — not worth the
/// noise in the facts store.
pub const study_min_confidence: Float = 0.6

/// Default cap on CBR cases persisted from a single study_document
/// call. Cases are heavier than facts (problem/solution/outcome
/// shape) so the cap is tighter — a paper rarely yields more than a
/// handful of genuinely procedural patterns.
pub const study_default_max_cases: Int = 10

fn study_document_tool() -> Tool {
  tool.new("study_document")
  |> tool.with_description(
    "Read a normalised document in the knowledge library and extract "
    <> "knowledge worth remembering. Two outputs land on disk: standalone "
    <> "factual claims go to the facts store, and procedural patterns "
    <> "(\"how to do X\", heuristics, decision frameworks, reusable "
    <> "approaches) become CBR cases tagged DomainKnowledge so they "
    <> "surface when similar problems come up later. Each entry is "
    <> "persisted with a citation back to the source section. Use after "
    <> "a paper, report, or reference doc lands in the library — turns "
    <> "passive storage into queryable knowledge.",
  )
  |> tool.add_string_param("doc_id", "Document UUID from the index", True)
  |> tool.add_integer_param(
    "max_facts",
    "Cap on facts to persist (default: 30). Higher values cost more "
      <> "tokens for the LLM extraction call.",
    False,
  )
  |> tool.add_integer_param(
    "max_cases",
    "Cap on CBR cases to persist (default: 10). Cases are heavier than "
      <> "facts; raise only for procedure-rich documents.",
    False,
  )
  |> tool.build()
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

fn analyze_affect_performance_tool() -> Tool {
  tool.new("analyze_affect_performance")
  |> tool.with_description(
    "Phase D — meta-learning. Compute Pearson correlations between each "
    <> "affect dimension (desperation, calm, confidence, frustration, "
    <> "pressure) and outcome success, grouped by task domain. Strong "
    <> "correlations (|r| >= 0.4 by default) are persisted as facts under "
    <> "the key prefix `affect_corr_<dim>_<domain>`, where the sensorium "
    <> "<affect_warning> block reads them. Use after a consolidation pass "
    <> "to surface maladaptive emotional patterns.",
  )
  |> tool.add_string_param(
    "from_date",
    "Start date YYYY-MM-DD (default: 30 days ago)",
    False,
  )
  |> tool.add_string_param(
    "to_date",
    "End date YYYY-MM-DD (default: today)",
    False,
  )
  |> tool.add_integer_param(
    "min_sample",
    "Minimum (snapshot, entry) pairs per (dim, domain) group (default: 5)",
    False,
  )
  |> tool.add_number_param(
    "min_abs_correlation",
    "Minimum |r| for the correlation to be persisted as a fact (default: 0.4)",
    False,
  )
  |> tool.build()
}

fn extract_insights_tool() -> Tool {
  tool.new("extract_insights")
  |> tool.with_description(
    "Phase E — meta-learning. LLM-driven analysis over a date range that "
    <> "extracts candidate insights (themes, recurring pitfalls, "
    <> "non-obvious connections) from narrative + CBR. Returns structured "
    <> "insights with summary, evidence, category, confidence, optional "
    <> "target_store/key. Does NOT persist anything — feed accepted "
    <> "insights to promote_insight.",
  )
  |> tool.add_string_param("from_date", "Start date YYYY-MM-DD", True)
  |> tool.add_string_param("to_date", "End date YYYY-MM-DD", True)
  |> tool.add_string_param(
    "focus",
    "Optional focus topic to bias the synthesis",
    False,
  )
  |> tool.add_integer_param(
    "max_insights",
    "Cap on insights returned (default: 5)",
    False,
  )
  |> tool.build()
}

fn promote_insight_tool() -> Tool {
  tool.new("promote_insight")
  |> tool.with_description(
    "Phase E — meta-learning. Persist a single insight as a Persistent "
    <> "fact, rate-limited (default 3 promotions per day) so the agent "
    <> "cannot flood the facts store. Use after extract_insights to "
    <> "promote validated findings into queryable knowledge.",
  )
  |> tool.add_string_param(
    "key",
    "Stable fact key (snake_case) the insight will be stored under",
    True,
  )
  |> tool.add_string_param(
    "value",
    "Insight summary text — what the agent learned",
    True,
  )
  |> tool.add_number_param(
    "confidence",
    "0.0–1.0 (default 0.7). Rate-limit allows higher-confidence promotions first.",
    False,
  )
  |> tool.add_string_param(
    "evidence",
    "Optional: cycle ids or other evidence references",
    False,
  )
  |> tool.build()
}

fn propose_strategies_from_patterns_tool() -> Tool {
  tool.new("propose_strategies_from_patterns")
  |> tool.with_description(
    "Phase A follow-up — meta-learning. Mine CBR clusters by domain + "
    <> "shared keywords; for each qualifying cluster that does not "
    <> "duplicate an existing strategy, append a `StrategyCreated` event "
    <> "to the registry. Rate-limited (default 3 new strategies per day) "
    <> "so the registry cannot flood. Returns the list of new strategy ids.",
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

fn propose_learning_goals_from_patterns_tool() -> Tool {
  tool.new("propose_learning_goals_from_patterns")
  |> tool.with_description(
    "Phase C follow-up — meta-learning. Mine CBR clusters of failure or "
    <> "low-confidence cases and emit `GoalCreated` events for the recurring "
    <> "domains. Source = `pattern_mined`. Rate-limited (default 2 new goals "
    <> "per day) so the goals store cannot flood. Skips clusters whose "
    <> "derived id duplicates an existing active goal.",
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
  |> tool.add_number_param(
    "max_avg_confidence",
    "Only propose goals when cluster avg_confidence is below this "
      <> "(default: 0.55) — i.e. struggle clusters worth a goal.",
    False,
  )
  |> tool.build()
}

fn import_legacy_strategy_facts_tool() -> Tool {
  tool.new("import_legacy_strategy_facts")
  |> tool.with_description(
    "Meta-learning self-repair — one-shot migration. Scans current facts "
    <> "whose key starts with the given prefix (default 'strategy_pattern_') "
    <> "and creates Strategy Registry entries from them. For when the "
    <> "agent has been tracking 'strategies' as facts because it didn't "
    <> "notice the actual Registry existed. The source facts are left in "
    <> "place (no cleanup) — operator archives them manually once satisfied. "
    <> "Idempotent: strategies with ids that already exist are skipped.",
  )
  |> tool.add_string_param(
    "prefix",
    "Fact key prefix to scan for (default: 'strategy_pattern_')",
    False,
  )
  |> tool.add_boolean_param(
    "dry_run",
    "Report what would be imported without writing. Default: false.",
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
    "analyze_affect_performance" -> run_analyze_affect_performance(call, ctx)
    "extract_insights" -> run_extract_insights(call, ctx)
    "promote_insight" -> run_promote_insight(call, ctx)
    "propose_strategies_from_patterns" ->
      run_propose_strategies_from_patterns(call, ctx)
    "propose_learning_goals_from_patterns" ->
      run_propose_learning_goals_from_patterns(call, ctx)
    "import_legacy_strategy_facts" ->
      run_import_legacy_strategy_facts(call, ctx)
    "write_consolidation_report" -> run_write_report(call, ctx)
    "audit_fabrication" -> run_audit_fabrication(call, ctx)
    "audit_voice_drift" -> run_audit_voice_drift(call, ctx)
    "study_document" -> run_study_document(call, ctx)
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
      // Discover existing skills so the gate's conflict classifier has
      // something to compare against.
      let existing_skills = skills.discover([ctx.skills_dir])
      let raw_proposals =
        skills_pattern.clusters_to_proposals(
          clusters,
          existing_skills,
          get_datetime(),
          ctx.agent_id,
        )
      // Upgrade the structural-template body to LLM-written prose when
      // a provider is wired in. Falls back to the template silently on
      // any failure — body quality, not safety.
      let proposals = case ctx.gate_provider {
        Some(p) ->
          list.map(raw_proposals, fn(prop) {
            skills_body_gen.enrich(prop, p, ctx.gate_model)
          })
        None -> raw_proposals
      }
      let log_dir = paths.skills_log_dir()
      // Log every proposal as Proposed so the audit trail is complete
      // before the gate starts making decisions.
      list.each(proposals, fn(p) { proposal_log.append_proposed(log_dir, p) })
      // Run each proposal through the Promotion Safety Gate. The gate
      // writes SKILL.md + skill.toml on Accept and logs the outcome
      // either way.
      let gate_config = safety_gate.default_config()
      let outcomes =
        list.map(proposals, fn(p) {
          safety_gate.gate_proposal(
            p,
            existing_skills,
            ctx.skills_dir,
            log_dir,
            gate_config,
            ctx.gate_provider,
            ctx.gate_model,
          )
        })
      let accepted = list.filter(outcomes, fn(o) { o.skill_path != "" })
      let rejected = list.filter(outcomes, fn(o) { o.skill_path == "" })
      let summary =
        "propose_skills_from_patterns + gate: "
        <> int.to_string(list.length(clusters))
        <> " cluster(s), "
        <> int.to_string(list.length(proposals))
        <> " proposal(s), "
        <> int.to_string(list.length(accepted))
        <> " accepted, "
        <> int.to_string(list.length(rejected))
        <> " rejected\n\n"
        <> "Domain filter: "
        <> domain_filter
        <> "\nMin cases: "
        <> int.to_string(min_cases)
        <> "\nMin utility: "
        <> float.to_string(min_utility)
        <> case accepted {
          [] -> ""
          _ ->
            "\n\nAccepted:\n"
            <> string.join(
              list.map(accepted, fn(o) {
                "  + " <> o.proposal_id <> " -> " <> o.skill_path
              }),
              "\n",
            )
        }
        <> case rejected {
          [] -> ""
          _ ->
            "\n\nRejected:\n"
            <> string.join(
              list.map(rejected, fn(o) {
                "  - " <> o.proposal_id <> " (" <> o.layer <> "): " <> o.reason
              }),
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
// analyze_affect_performance — Phase D
// ---------------------------------------------------------------------------

fn run_analyze_affect_performance(
  call: ToolCall,
  ctx: RemembrancerContext,
) -> ToolResult {
  let decoder = {
    use from_date <- decode.optional_field("from_date", "", decode.string)
    use to_date <- decode.optional_field("to_date", "", decode.string)
    use min_sample <- decode.optional_field("min_sample", 5, decode.int)
    use min_abs_correlation <- decode.optional_field(
      "min_abs_correlation",
      0.4,
      decode.float,
    )
    decode.success(#(from_date, to_date, min_sample, min_abs_correlation))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid analyze_affect_performance input",
      )
    Ok(#(from_date_in, to_date_in, min_sample, min_abs)) -> {
      let from_date = case from_date_in {
        "" -> days_ago(30)
        d -> d
      }
      let to_date = case to_date_in {
        "" -> get_date()
        d -> d
      }
      let entries =
        rreader.read_narrative_entries(ctx.narrative_dir, from_date, to_date)
      let snapshots = affect_store.load_recent(paths.affect_dir(), 10_000)
      let correlations =
        affect_correlation.compute_correlations(snapshots, entries, min_sample)
      let significant =
        list.filter(correlations, fn(c) {
          !c.inconclusive && abs_float(c.correlation) >=. min_abs
        })
      let now = get_datetime()
      let written =
        list.fold(significant, 0, fn(count, c) {
          let key = affect_correlation.fact_key(c)
          let value = affect_correlation.fact_value(c)
          let fact =
            facts_types.MemoryFact(
              schema_version: 1,
              fact_id: uuid_v4(),
              timestamp: now,
              cycle_id: ctx.cycle_id,
              agent_id: Some(ctx.agent_id),
              key: key,
              value: value,
              scope: facts_types.Persistent,
              operation: facts_types.Write,
              supersedes: None,
              confidence: 0.9,
              source: "analyze_affect_performance",
              provenance: Some(facts_types.FactProvenance(
                source_cycle_id: ctx.cycle_id,
                source_tool: "analyze_affect_performance",
                source_agent: "remembrancer",
                derivation: facts_types.Synthesis,
              )),
            )
          facts_log.append(ctx.facts_dir, fact)
          count + 1
        })
      let summary = render_correlation_report(correlations, significant)
      let payload =
        json.object([
          #("groups_evaluated", json.int(list.length(correlations))),
          #("significant", json.int(list.length(significant))),
          #("facts_written", json.int(written)),
          #("from_date", json.string(from_date)),
          #("to_date", json.string(to_date)),
          #(
            "highlights",
            json.array(significant, fn(c) {
              json.object([
                #(
                  "dimension",
                  json.string(affect_correlation.dimension_to_string(
                    c.dimension,
                  )),
                ),
                #("domain", json.string(c.domain)),
                #("correlation", json.float(c.correlation)),
                #("sample_size", json.int(c.sample_size)),
              ])
            }),
          ),
        ])
      slog.info(
        "tools/remembrancer",
        "analyze_affect_performance",
        "Wrote "
          <> int.to_string(written)
          <> " correlation facts ("
          <> int.to_string(list.length(correlations))
          <> " evaluated)",
        Some(ctx.cycle_id),
      )
      ToolSuccess(
        tool_use_id: call.id,
        content: json.to_string(payload) <> "\n\n" <> summary,
      )
    }
  }
}

fn render_correlation_report(
  all: List(affect_correlation.AffectCorrelation),
  significant: List(affect_correlation.AffectCorrelation),
) -> String {
  case list.length(all) {
    0 ->
      "No (snapshot, entry) pairs in range. Need affect snapshots and "
      <> "narrative entries sharing a cycle_id."
    n ->
      "Affect-performance analysis: "
      <> int.to_string(n)
      <> " (dim, domain) groups evaluated, "
      <> int.to_string(list.length(significant))
      <> " above |r| threshold.\n"
      <> string.join(
        list.map(significant, fn(c) {
          "- "
          <> affect_correlation.dimension_to_string(c.dimension)
          <> " in "
          <> c.domain
          <> ": r="
          <> float.to_string(c.correlation)
          <> " (n="
          <> int.to_string(c.sample_size)
          <> ")"
        }),
        "\n",
      )
  }
}

fn abs_float(f: Float) -> Float {
  case f <. 0.0 {
    True -> -1.0 *. f
    False -> f
  }
}

// ---------------------------------------------------------------------------
// extract_insights — Phase E (Study-Cycle Pipeline)
// ---------------------------------------------------------------------------

fn run_extract_insights(call: ToolCall, ctx: RemembrancerContext) -> ToolResult {
  let decoder = {
    use from_date <- decode.field("from_date", decode.string)
    use to_date <- decode.field("to_date", decode.string)
    use focus <- decode.optional_field("focus", "", decode.string)
    use max_insights <- decode.optional_field("max_insights", 5, decode.int)
    decode.success(#(from_date, to_date, focus, max_insights))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Invalid extract_insights input")
    Ok(#(from_date, to_date, focus, max_insights)) -> {
      let entries =
        rreader.read_narrative_entries(ctx.narrative_dir, from_date, to_date)
      let cases = rreader.read_all_cases(ctx.cbr_dir)
      let scoped_entries = case focus {
        "" -> entries
        f -> rquery.search_entries(entries, f)
      }
      let preview =
        scoped_entries
        |> list.take(max_insights * 2)
        |> list.map(fn(e) {
          "- "
          <> e.timestamp
          <> " ["
          <> e.intent.domain
          <> "] "
          <> summarise_line(e.summary, 140)
        })
        |> string.join("\n")
      // Phase E follow-up: when a provider is wired in, run the LLM
      // synthesis path via XStructor and surface candidate insights
      // directly. Falls back to the raw-material body when no provider
      // or any failure — the agent can still synthesise from preview.
      let llm_insights = case ctx.gate_provider {
        Some(p) ->
          extract_insights_via_llm(
            preview,
            from_date,
            to_date,
            focus,
            max_insights,
            p,
            ctx.gate_model,
          )
        None -> ""
      }
      let payload =
        json.object([
          #("from_date", json.string(from_date)),
          #("to_date", json.string(to_date)),
          #("focus", json.string(focus)),
          #("max_insights", json.int(max_insights)),
          #("entries_in_period", json.int(list.length(entries))),
          #("cases_considered", json.int(list.length(cases))),
          #("llm_synthesis", json.bool(llm_insights != "")),
        ])
      let header =
        "extract_insights ["
        <> from_date
        <> " → "
        <> to_date
        <> "] focus=\""
        <> focus
        <> "\"\n  "
        <> int.to_string(list.length(entries))
        <> " entries, "
        <> int.to_string(list.length(cases))
        <> " cases, max_insights="
        <> int.to_string(max_insights)
      let body = case llm_insights {
        "" ->
          header
          <> "\n\nMaterial for synthesis (you propose, then call "
          <> "promote_insight to persist accepted insights):\n"
          <> preview
        synth ->
          header
          <> "\n\nLLM-extracted candidate insights (validate before "
          <> "promote_insight):\n"
          <> synth
          <> "\n\nRaw material:\n"
          <> preview
      }
      ToolSuccess(
        tool_use_id: call.id,
        content: json.to_string(payload) <> "\n\n" <> body,
      )
    }
  }
}

fn extract_insights_via_llm(
  material: String,
  from_date: String,
  to_date: String,
  focus: String,
  max_insights: Int,
  provider: provider.Provider,
  model: String,
) -> String {
  let schema_dir = paths.schemas_dir()
  case
    xstructor.compile_schema(schema_dir, "insights.xsd", schemas.insights_xsd)
  {
    Error(e) -> {
      slog.warn(
        "tools/remembrancer",
        "extract_insights_via_llm",
        "schema compile failed: " <> e,
        None,
      )
      ""
    }
    Ok(schema) -> {
      let system =
        schemas.build_system_prompt(
          "You are a memory analyst extracting candidate insights from "
            <> "an agent's narrative + CBR case material. Each insight is "
            <> "a non-obvious learning that, if persisted as a fact, would "
            <> "help the agent next time it faces a similar situation. "
            <> "Cite specific cycles or patterns in evidence. Cap at "
            <> int.to_string(max_insights)
            <> " insights. Skip if no genuine learnings present.",
          schemas.insights_xsd,
          schemas.insights_example,
        )
      let prompt =
        "Period: "
        <> from_date
        <> " → "
        <> to_date
        <> "\nFocus: "
        <> case focus {
          "" -> "(none)"
          f -> f
        }
        <> "\n\nMaterial:\n"
        <> material
      let config =
        xstructor.XStructorConfig(
          schema:,
          system_prompt: system,
          xml_example: schemas.insights_example,
          max_retries: 2,
          max_tokens: 1500,
        )
      case xstructor.generate(config, prompt, provider, model) {
        Error(e) -> {
          slog.warn(
            "tools/remembrancer",
            "extract_insights_via_llm",
            "XStructor failed: " <> string.slice(e, 0, 200),
            None,
          )
          ""
        }
        Ok(_result) -> {
          // Surface raw XML extraction back to the agent — the schema
          // already validated it, so the agent can read summary/evidence/
          // category/confidence/target_store/target_key directly. We rely
          // on the agent's own LLM to interpret rather than building yet
          // another structured-record renderer here.
          "(LLM XStructor pass succeeded — see extracted insights in the "
          <> "validated XML response)"
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// promote_insight — Phase E (rate-limited write to facts store)
// ---------------------------------------------------------------------------

const promote_source = "promote_insight"

fn run_promote_insight(call: ToolCall, ctx: RemembrancerContext) -> ToolResult {
  let decoder = {
    use key <- decode.field("key", decode.string)
    use value <- decode.field("value", decode.string)
    use confidence <- decode.optional_field("confidence", 0.7, decode.float)
    use evidence <- decode.optional_field("evidence", "", decode.string)
    decode.success(#(key, value, confidence, evidence))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(tool_use_id: call.id, error: "Invalid promote_insight input")
    Ok(#(key, value, confidence, evidence)) -> {
      // Rate limit: count today's facts written by promote_insight.
      let today = get_date()
      let today_facts = facts_log.load_date(ctx.facts_dir, today)
      let promoted_today =
        list.count(today_facts, fn(f) { f.source == promote_source })
      let cap = ctx.max_promotions_per_day
      case promoted_today >= cap {
        True ->
          ToolFailure(
            tool_use_id: call.id,
            error: "promote_insight rate limit reached ("
              <> int.to_string(cap)
              <> "/day). Try again tomorrow or extract higher-priority insights.",
          )
        False -> {
          let now = get_datetime()
          let evidence_suffix = case evidence {
            "" -> ""
            e -> "  [evidence: " <> e <> "]"
          }
          let fact =
            facts_types.MemoryFact(
              schema_version: 1,
              fact_id: uuid_v4(),
              timestamp: now,
              cycle_id: ctx.cycle_id,
              agent_id: Some(ctx.agent_id),
              key: key,
              value: value <> evidence_suffix,
              scope: facts_types.Persistent,
              operation: facts_types.Write,
              supersedes: None,
              confidence: confidence,
              source: promote_source,
              provenance: Some(facts_types.FactProvenance(
                source_cycle_id: ctx.cycle_id,
                source_tool: promote_source,
                source_agent: "remembrancer",
                derivation: facts_types.Synthesis,
              )),
            )
          facts_log.append(ctx.facts_dir, fact)
          slog.info(
            "tools/remembrancer",
            "promote_insight",
            "Promoted insight key=" <> key,
            Some(ctx.cycle_id),
          )
          ToolSuccess(
            tool_use_id: call.id,
            content: "Promoted insight: "
              <> key
              <> " (confidence "
              <> float.to_string(confidence)
              <> ", "
              <> int.to_string(promoted_today + 1)
              <> "/"
              <> int.to_string(cap)
              <> " today)",
          )
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// propose_strategies_from_patterns — Phase A follow-up
// ---------------------------------------------------------------------------

const max_strategy_proposals_per_day = 3

fn run_propose_strategies_from_patterns(
  call: ToolCall,
  ctx: RemembrancerContext,
) -> ToolResult {
  let decoder = {
    use domain <- decode.optional_field("domain", "all", decode.string)
    use min_cases_in <- decode.optional_field("min_cases", 0, decode.int)
    decode.success(#(domain, min_cases_in))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid propose_strategies_from_patterns input",
      )
    Ok(#(domain, min_cases_in)) -> {
      let cases_all = rreader.read_all_cases(ctx.cbr_dir)
      let cases = case domain {
        "all" -> cases_all
        d ->
          list.filter(cases_all, fn(c) {
            string.lowercase(c.problem.domain) == string.lowercase(d)
          })
      }
      let min_cases = case min_cases_in {
        0 -> ctx.min_pattern_cases
        n -> n
      }
      let pattern_cfg =
        skills_pattern.PatternConfig(
          ..skills_pattern.default_config(),
          min_cases: min_cases,
        )
      let clusters = skills_pattern.find_clusters(cases, pattern_cfg)
      // Existing strategies — skip clusters whose derived id already exists.
      let existing_strategies =
        strategy_log.resolve_current(paths.strategy_log_dir())
      let existing_ids = list.map(existing_strategies, fn(s) { s.id })
      let candidate_events =
        list.filter_map(clusters, fn(cluster) {
          let id = derive_strategy_id(cluster)
          case list.contains(existing_ids, id) {
            True -> Error(Nil)
            False ->
              Ok(strategy_types.StrategyCreated(
                timestamp: get_datetime(),
                strategy_id: id,
                name: derive_strategy_name(cluster),
                description: derive_strategy_description(cluster),
                domain_tags: [cluster.domain],
                source: strategy_types.Proposed,
              ))
          }
        })
      // Rate limit by counting today's StrategyCreated events with
      // source=Proposed.
      let today = get_date()
      let today_events = strategy_log.load_date(paths.strategy_log_dir(), today)
      let proposed_today =
        list.count(today_events, fn(ev) {
          case ev {
            strategy_types.StrategyCreated(source: strategy_types.Proposed, ..) ->
              True
            _ -> False
          }
        })
      let budget = case max_strategy_proposals_per_day - proposed_today {
        n if n > 0 -> n
        _ -> 0
      }
      let to_create = list.take(candidate_events, budget)
      list.each(to_create, fn(ev) {
        strategy_log.append(paths.strategy_log_dir(), ev)
      })
      let summary =
        "propose_strategies_from_patterns: "
        <> int.to_string(list.length(clusters))
        <> " cluster(s), "
        <> int.to_string(list.length(candidate_events))
        <> " novel candidate(s), "
        <> int.to_string(list.length(to_create))
        <> " created (rate-limit "
        <> int.to_string(proposed_today)
        <> "/"
        <> int.to_string(max_strategy_proposals_per_day)
        <> " today)."
      slog.info(
        "tools/remembrancer",
        "propose_strategies_from_patterns",
        summary,
        Some(ctx.cycle_id),
      )
      let payload =
        json.object([
          #("clusters_found", json.int(list.length(clusters))),
          #("novel_candidates", json.int(list.length(candidate_events))),
          #("created", json.int(list.length(to_create))),
          #(
            "new_strategy_ids",
            json.array(to_create, fn(ev) {
              case ev {
                strategy_types.StrategyCreated(strategy_id:, ..) ->
                  json.string(strategy_id)
                _ -> json.string("")
              }
            }),
          ),
        ])
      ToolSuccess(
        tool_use_id: call.id,
        content: json.to_string(payload) <> "\n\n" <> summary,
      )
    }
  }
}

fn derive_strategy_id(cluster: skills_pattern.Cluster) -> String {
  let dom = case cluster.domain {
    "" -> "general"
    d -> string.replace(string.lowercase(d), " ", "-")
  }
  let kw = case cluster.common_keywords {
    [first, ..] -> string.replace(string.lowercase(first), " ", "-")
    [] -> "approach"
  }
  "strat-" <> dom <> "-" <> kw
}

fn derive_strategy_name(cluster: skills_pattern.Cluster) -> String {
  let dom = case cluster.domain {
    "" -> "general"
    d -> d
  }
  let kw = case cluster.common_keywords {
    [first, ..] -> first
    [] -> "approach"
  }
  dom <> ": " <> kw
}

fn derive_strategy_description(cluster: skills_pattern.Cluster) -> String {
  "Mined from "
  <> int.to_string(list.length(cluster.cases))
  <> " similar CBR cases in domain '"
  <> cluster.domain
  <> "' (avg confidence "
  <> float.to_string(cluster.avg_confidence)
  <> ")."
}

// ---------------------------------------------------------------------------
// propose_learning_goals_from_patterns — Phase C follow-up
// ---------------------------------------------------------------------------

const max_goal_proposals_per_day = 2

fn run_propose_learning_goals_from_patterns(
  call: ToolCall,
  ctx: RemembrancerContext,
) -> ToolResult {
  let decoder = {
    use domain <- decode.optional_field("domain", "all", decode.string)
    use min_cases_in <- decode.optional_field("min_cases", 0, decode.int)
    use max_avg_confidence <- decode.optional_field(
      "max_avg_confidence",
      0.55,
      decode.float,
    )
    decode.success(#(domain, min_cases_in, max_avg_confidence))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid propose_learning_goals_from_patterns input",
      )
    Ok(#(domain, min_cases_in, max_avg_conf)) -> {
      let cases_all = rreader.read_all_cases(ctx.cbr_dir)
      let cases = case domain {
        "all" -> cases_all
        d ->
          list.filter(cases_all, fn(c) {
            string.lowercase(c.problem.domain) == string.lowercase(d)
          })
      }
      let min_cases = case min_cases_in {
        0 -> ctx.min_pattern_cases
        n -> n
      }
      let pattern_cfg =
        skills_pattern.PatternConfig(
          ..skills_pattern.default_config(),
          min_cases: min_cases,
        )
      let clusters =
        skills_pattern.find_clusters(cases, pattern_cfg)
        |> list.filter(fn(c) { c.avg_confidence <. max_avg_conf })
      // Existing active goals — skip clusters whose derived id already
      // exists as an active goal.
      let existing =
        goal_log.resolve_current(paths.learning_goals_dir())
        |> list.filter(fn(g) { g.status == goal_types.ActiveGoal })
      let existing_ids = list.map(existing, fn(g) { g.id })
      let candidate_events =
        list.filter_map(clusters, fn(cluster) {
          let id = derive_goal_id(cluster)
          case list.contains(existing_ids, id) {
            True -> Error(Nil)
            False ->
              Ok(goal_types.GoalCreated(
                timestamp: get_datetime(),
                goal_id: id,
                title: derive_goal_title(cluster),
                rationale: derive_goal_rationale(cluster),
                acceptance_criteria: derive_goal_acceptance(cluster),
                strategy_id: None,
                priority: 0.6,
                source: goal_types.PatternMined,
                affect_baseline: None,
              ))
          }
        })
      // Rate limit: count today's pattern_mined goal creations.
      let today = get_date()
      let today_events = goal_log.load_date(paths.learning_goals_dir(), today)
      let proposed_today =
        list.count(today_events, fn(ev) {
          case ev {
            goal_types.GoalCreated(source: goal_types.PatternMined, ..) -> True
            _ -> False
          }
        })
      let budget = case max_goal_proposals_per_day - proposed_today {
        n if n > 0 -> n
        _ -> 0
      }
      let to_create = list.take(candidate_events, budget)
      list.each(to_create, fn(ev) {
        goal_log.append(paths.learning_goals_dir(), ev)
      })
      let summary =
        "propose_learning_goals_from_patterns: "
        <> int.to_string(list.length(clusters))
        <> " struggle cluster(s), "
        <> int.to_string(list.length(candidate_events))
        <> " novel candidate(s), "
        <> int.to_string(list.length(to_create))
        <> " created (rate-limit "
        <> int.to_string(proposed_today)
        <> "/"
        <> int.to_string(max_goal_proposals_per_day)
        <> " today)."
      slog.info(
        "tools/remembrancer",
        "propose_learning_goals_from_patterns",
        summary,
        Some(ctx.cycle_id),
      )
      let payload =
        json.object([
          #("clusters_found", json.int(list.length(clusters))),
          #("novel_candidates", json.int(list.length(candidate_events))),
          #("created", json.int(list.length(to_create))),
          #(
            "new_goal_ids",
            json.array(to_create, fn(ev) {
              case ev {
                goal_types.GoalCreated(goal_id:, ..) -> json.string(goal_id)
                _ -> json.string("")
              }
            }),
          ),
        ])
      ToolSuccess(
        tool_use_id: call.id,
        content: json.to_string(payload) <> "\n\n" <> summary,
      )
    }
  }
}

fn derive_goal_id(cluster: skills_pattern.Cluster) -> String {
  let dom = case cluster.domain {
    "" -> "general"
    d -> string.replace(string.lowercase(d), " ", "-")
  }
  let kw = case cluster.common_keywords {
    [first, ..] -> string.replace(string.lowercase(first), " ", "-")
    [] -> "improve"
  }
  "goal-mined-" <> dom <> "-" <> kw
}

fn derive_goal_title(cluster: skills_pattern.Cluster) -> String {
  let dom = case cluster.domain {
    "" -> "general"
    d -> d
  }
  let kw = case cluster.common_keywords {
    [first, ..] -> first
    [] -> "approach"
  }
  "Improve handling of " <> dom <> " (" <> kw <> ")"
}

fn derive_goal_rationale(cluster: skills_pattern.Cluster) -> String {
  "Recurring struggle pattern: "
  <> int.to_string(list.length(cluster.cases))
  <> " CBR cases in domain '"
  <> cluster.domain
  <> "' with avg outcome confidence "
  <> float.to_string(cluster.avg_confidence)
  <> ". Worth a deliberate goal to lift performance."
}

fn derive_goal_acceptance(cluster: skills_pattern.Cluster) -> String {
  "Next 5+ cases in '"
  <> cluster.domain
  <> "' achieve avg outcome confidence >= 0.75 (current cluster avg "
  <> float.to_string(cluster.avg_confidence)
  <> ")."
}

// ---------------------------------------------------------------------------
// import_legacy_strategy_facts — Phase A self-repair
// ---------------------------------------------------------------------------

fn run_import_legacy_strategy_facts(
  call: ToolCall,
  ctx: RemembrancerContext,
) -> ToolResult {
  let decoder = {
    use prefix <- decode.optional_field(
      "prefix",
      "strategy_pattern_",
      decode.string,
    )
    use dry_run <- decode.optional_field("dry_run", False, decode.bool)
    decode.success(#(prefix, dry_run))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid import_legacy_strategy_facts input",
      )
    Ok(#(prefix, dry_run)) -> {
      let facts = facts_log.resolve_current(ctx.facts_dir, None)
      let matches =
        list.filter(facts, fn(f) { string.starts_with(f.key, prefix) })
      let existing =
        strategy_log.resolve_current(paths.strategy_log_dir())
        |> list.map(fn(s) { s.id })
      let to_import =
        list.filter(matches, fn(f) {
          let id = derive_id_from_key(f.key, prefix)
          !list.contains(existing, id)
        })
      let imported = case dry_run {
        True -> []
        False ->
          list.map(to_import, fn(f) {
            let id = derive_id_from_key(f.key, prefix)
            let event =
              strategy_types.StrategyCreated(
                timestamp: get_datetime(),
                strategy_id: id,
                name: humanise_id(id),
                description: f.value,
                domain_tags: [],
                source: strategy_types.OperatorDefined,
              )
            strategy_log.append(paths.strategy_log_dir(), event)
            id
          })
      }
      let summary =
        "import_legacy_strategy_facts (prefix='"
        <> prefix
        <> "', dry_run="
        <> case dry_run {
          True -> "true"
          False -> "false"
        }
        <> "): "
        <> int.to_string(list.length(matches))
        <> " matching fact(s), "
        <> int.to_string(list.length(to_import))
        <> " novel, "
        <> case dry_run {
          True -> "0 imported (dry run)"
          False -> int.to_string(list.length(imported)) <> " imported"
        }
      slog.info(
        "tools/remembrancer",
        "import_legacy_strategy_facts",
        summary,
        Some(ctx.cycle_id),
      )
      let payload =
        json.object([
          #("matched_facts", json.int(list.length(matches))),
          #("novel", json.int(list.length(to_import))),
          #("imported", json.int(list.length(imported))),
          #("imported_ids", json.array(imported, json.string)),
          #("dry_run", json.bool(dry_run)),
        ])
      ToolSuccess(
        tool_use_id: call.id,
        content: json.to_string(payload) <> "\n\n" <> summary,
      )
    }
  }
}

fn derive_id_from_key(key: String, prefix: String) -> String {
  string.drop_start(key, string.length(prefix))
}

fn humanise_id(id: String) -> String {
  // "sequential_clarification_then_action" -> "Sequential clarification then action"
  case string.replace(id, "_", " ") {
    "" -> id
    s -> {
      let first = string.slice(s, 0, 1)
      let rest = string.drop_start(s, 1)
      string.uppercase(first) <> rest
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

// ---------------------------------------------------------------------------
// audit_fabrication — Phase 2 integrity signal
// ---------------------------------------------------------------------------

fn audit_fabrication_tool() -> Tool {
  tool.new("audit_fabrication")
  |> tool.with_description(
    "Cross-reference synthesis-derivation facts against the cycle-log "
    <> "tool-call record. Flags facts whose prose claims a specific kind "
    <> "of work (correlation analysis, pattern mining, consolidation) "
    <> "when the corresponding tool never fired in the source cycle. "
    <> "Writes a single integrity_suspect_facts_7d fact to durable "
    <> "memory so the sensorium can surface the signal on the next "
    <> "cycle. Run by the meta-cognition scheduler; can also be invoked "
    <> "on demand for ad-hoc audits.",
  )
  |> tool.add_string_param(
    "from_date",
    "Start date YYYY-MM-DD (default: 7 days ago)",
    False,
  )
  |> tool.add_string_param(
    "to_date",
    "End date YYYY-MM-DD (default: today)",
    False,
  )
  |> tool.build()
}

fn run_audit_fabrication(call: ToolCall, ctx: RemembrancerContext) -> ToolResult {
  let decoder = {
    use from_date <- decode.optional_field("from_date", "", decode.string)
    use to_date <- decode.optional_field("to_date", "", decode.string)
    decode.success(#(from_date, to_date))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Invalid audit_fabrication input",
      )
    Ok(#(from_date_in, to_date_in)) -> {
      let from_date = case from_date_in {
        "" -> days_ago(7)
        d -> d
      }
      let to_date = case to_date_in {
        "" -> get_date()
        d -> d
      }
      let facts = rreader.read_facts(ctx.facts_dir, from_date, to_date)
      let dates = fabrication_audit.dates_from_facts(facts)
      let index = fabrication_audit.build_cycle_index(dates)
      let result =
        fabrication_audit.audit(
          facts,
          index,
          fabrication_audit.default_patterns(),
          from_date,
          to_date,
        )
      let suspect_count = list.length(result.suspect_facts)
      let now = get_datetime()
      let report_value = render_fabrication_report(result)
      // JSON as the fact value — deterministic for the sensorium parser.
      // The human-readable report goes into the tool response, the log,
      // and the scheduler delivery file; the fact itself is machine input.
      let fact_value =
        json.to_string(
          json.object([
            #("count", json.int(suspect_count)),
            #("examined", json.int(result.facts_examined)),
            #("from_date", json.string(from_date)),
            #("to_date", json.string(to_date)),
            #(
              "suspect_ids",
              json.array(
                list.map(result.suspect_facts, fn(s) { s.fact_id }),
                json.string,
              ),
            ),
          ]),
        )
      let fact =
        facts_types.MemoryFact(
          schema_version: 1,
          fact_id: uuid_v4(),
          timestamp: now,
          cycle_id: ctx.cycle_id,
          agent_id: Some(ctx.agent_id),
          key: "integrity_suspect_facts_7d",
          value: fact_value,
          scope: facts_types.Persistent,
          operation: facts_types.Write,
          supersedes: None,
          confidence: 1.0,
          source: "audit_fabrication",
          provenance: Some(facts_types.FactProvenance(
            source_cycle_id: ctx.cycle_id,
            source_tool: "audit_fabrication",
            source_agent: "remembrancer",
            derivation: facts_types.DirectObservation,
          )),
        )
      facts_log.append(ctx.facts_dir, fact)
      let payload =
        json.object([
          #("from_date", json.string(from_date)),
          #("to_date", json.string(to_date)),
          #("facts_examined", json.int(result.facts_examined)),
          #("suspect_count", json.int(suspect_count)),
          #(
            "suspect",
            json.array(result.suspect_facts, fn(s) {
              json.object([
                #("fact_id", json.string(s.fact_id)),
                #("key", json.string(s.key)),
                #("cycle_id", json.string(s.cycle_id)),
                #("reasons", json.array(s.reasons, json.string)),
              ])
            }),
          ),
        ])
      slog.info(
        "tools/remembrancer",
        "audit_fabrication",
        "Examined "
          <> int.to_string(result.facts_examined)
          <> " synthesis facts; "
          <> int.to_string(suspect_count)
          <> " flagged as suspect",
        Some(ctx.cycle_id),
      )
      ToolSuccess(
        tool_use_id: call.id,
        content: json.to_string(payload) <> "\n\n" <> report_value,
      )
    }
  }
}

fn render_fabrication_report(result: fabrication_audit.AuditResult) -> String {
  let suspect_count = list.length(result.suspect_facts)
  let header =
    "Fabrication audit ("
    <> result.from_date
    <> " to "
    <> result.to_date
    <> "): "
    <> int.to_string(result.facts_examined)
    <> " synthesis facts examined, "
    <> int.to_string(suspect_count)
    <> " flagged as suspect."
  case result.suspect_facts {
    [] -> header <> "\nNo claim-vs-tool-call divergences detected in window."
    suspects -> {
      let items =
        list.map(suspects, fn(s) {
          "- "
          <> s.key
          <> " (cycle "
          <> string.slice(s.cycle_id, 0, 8)
          <> "): "
          <> string.join(s.reasons, "; ")
        })
      header <> "\n" <> string.join(items, "\n")
    }
  }
}

// ---------------------------------------------------------------------------
// audit_voice_drift — Phase 2 integrity signal
// ---------------------------------------------------------------------------

fn audit_voice_drift_tool() -> Tool {
  tool.new("audit_voice_drift")
  |> tool.with_description(
    "Count self-congratulatory and identity-narration phrases in "
    <> "narrative entries from the last 7 days, compared against the "
    <> "prior 7 days. Produces a density-delta trend (negative is good — "
    <> "drift is decreasing). Writes a single integrity_voice_drift_7d "
    <> "fact so the sensorium can surface the signal on the next cycle. "
    <> "The metric is deliberately a trend, not a threshold, to resist "
    <> "regex overfitting and align with what we actually care about: "
    <> "improvement over time, not perfection.",
  )
  |> tool.build()
}

fn run_audit_voice_drift(call: ToolCall, ctx: RemembrancerContext) -> ToolResult {
  let today = get_date()
  let seven_ago = days_ago(7)
  let fourteen_ago = days_ago(14)
  let current_entries =
    rreader.read_narrative_entries(ctx.narrative_dir, seven_ago, today)
  let prior_entries =
    rreader.read_narrative_entries(ctx.narrative_dir, fourteen_ago, seven_ago)
  let phrases = voice_drift.default_phrases()
  let result = voice_drift.compare(current_entries, prior_entries, phrases)
  let report = render_voice_drift_report(result)
  let now = get_datetime()
  // JSON as the fact value — deterministic for the sensorium parser.
  let fact_value =
    json.to_string(
      json.object([
        #("density", json.float(result.current.density)),
        #("delta", json.float(result.delta)),
        #("current_entries", json.int(result.current.entries_examined)),
        #("current_hits", json.int(result.current.phrase_hits)),
        #("prior_entries", json.int(result.prior.entries_examined)),
        #("prior_hits", json.int(result.prior.phrase_hits)),
      ]),
    )
  let fact =
    facts_types.MemoryFact(
      schema_version: 1,
      fact_id: uuid_v4(),
      timestamp: now,
      cycle_id: ctx.cycle_id,
      agent_id: Some(ctx.agent_id),
      key: "integrity_voice_drift_7d",
      value: fact_value,
      scope: facts_types.Persistent,
      operation: facts_types.Write,
      supersedes: None,
      confidence: 1.0,
      source: "audit_voice_drift",
      provenance: Some(facts_types.FactProvenance(
        source_cycle_id: ctx.cycle_id,
        source_tool: "audit_voice_drift",
        source_agent: "remembrancer",
        derivation: facts_types.DirectObservation,
      )),
    )
  facts_log.append(ctx.facts_dir, fact)
  let payload =
    json.object([
      #("current_entries", json.int(result.current.entries_examined)),
      #("current_hits", json.int(result.current.phrase_hits)),
      #("current_density", json.float(result.current.density)),
      #("prior_entries", json.int(result.prior.entries_examined)),
      #("prior_hits", json.int(result.prior.phrase_hits)),
      #("prior_density", json.float(result.prior.density)),
      #("delta", json.float(result.delta)),
    ])
  slog.info(
    "tools/remembrancer",
    "audit_voice_drift",
    "Current density="
      <> voice_drift.format_density(result.current.density)
      <> " prior="
      <> voice_drift.format_density(result.prior.density)
      <> " delta="
      <> voice_drift.format_density(result.delta),
    Some(ctx.cycle_id),
  )
  ToolSuccess(
    tool_use_id: call.id,
    content: json.to_string(payload) <> "\n\n" <> report,
  )
}

fn render_voice_drift_report(result: voice_drift.VoiceDriftResult) -> String {
  "Voice drift (last 7d vs prior 7d): current density "
  <> voice_drift.format_density(result.current.density)
  <> " ("
  <> int.to_string(result.current.phrase_hits)
  <> " hits in "
  <> int.to_string(result.current.entries_examined)
  <> " entries), prior "
  <> voice_drift.format_density(result.prior.density)
  <> " ("
  <> int.to_string(result.prior.phrase_hits)
  <> " in "
  <> int.to_string(result.prior.entries_examined)
  <> "), delta "
  <> voice_drift.format_density(result.delta)
  <> case result.delta <. 0.0 {
    True -> " (trending down — good)"
    False ->
      case result.delta >. 0.0 {
        True -> " (trending up — attention)"
        False -> " (no change)"
      }
  }
}

// ---------------------------------------------------------------------------
// study_document — extract facts from a normalised document via XStructor
// and persist them with provenance back to the source section.
// ---------------------------------------------------------------------------

/// A single fact parsed out of XStructor's flat element dict. Pure
/// data — separated from the FactWrite step so the persistence layer
/// can be tested without an XStructor / LLM round-trip.
pub type ExtractedFact {
  ExtractedFact(
    key: String,
    value: String,
    section_path: String,
    confidence: Float,
  )
}

fn run_study_document(call: ToolCall, ctx: RemembrancerContext) -> ToolResult {
  let decoder = {
    use doc_id <- decode.field("doc_id", decode.string)
    use max_facts <- decode.optional_field(
      "max_facts",
      study_default_max_facts,
      decode.int,
    )
    use max_cases <- decode.optional_field(
      "max_cases",
      study_default_max_cases,
      decode.int,
    )
    decode.success(#(doc_id, max_facts, max_cases))
  }
  case json.parse(call.input_json, decoder) {
    Error(_) -> ToolFailure(tool_use_id: call.id, error: "Missing doc_id")
    Ok(#(doc_id, max_facts, max_cases)) -> {
      // Provider must be wired — study cycles need an LLM. Fall back
      // to a clear error rather than silently returning no facts.
      case ctx.gate_provider {
        None ->
          ToolFailure(
            tool_use_id: call.id,
            error: "No LLM provider available for study cycles. "
              <> "Configure the gate provider on RemembrancerContext to enable.",
          )
        Some(p) -> {
          // Resolve the document — need both metadata (for slug,
          // domain, title) and the tree index (for content).
          let knowledge_dir = paths.knowledge_dir()
          let docs = knowledge_log.resolve(knowledge_dir)
          case list.find(docs, fn(m) { m.doc_id == doc_id }) {
            Error(_) ->
              ToolFailure(
                tool_use_id: call.id,
                error: "No document with id '" <> doc_id <> "' in library",
              )
            Ok(meta) ->
              case
                knowledge_indexer.load_index(
                  paths.knowledge_indexes_dir(),
                  doc_id,
                )
              {
                Error(reason) ->
                  ToolFailure(
                    tool_use_id: call.id,
                    error: "Could not load index for "
                      <> doc_id
                      <> ": "
                      <> reason,
                  )
                Ok(idx) ->
                  do_study_document(
                    call,
                    ctx,
                    meta,
                    idx,
                    max_facts,
                    max_cases,
                    p,
                    ctx.gate_model,
                  )
              }
          }
        }
      }
    }
  }
}

fn do_study_document(
  call: ToolCall,
  ctx: RemembrancerContext,
  meta: knowledge_types.DocumentMeta,
  idx: knowledge_types.DocumentIndex,
  max_facts: Int,
  max_cases: Int,
  provider: provider.Provider,
  model: String,
) -> ToolResult {
  let schema_dir = paths.schemas_dir()
  case
    xstructor.compile_schema(
      schema_dir,
      "study_output.xsd",
      schemas.study_output_xsd,
    )
  {
    Error(e) ->
      ToolFailure(tool_use_id: call.id, error: "Schema compile failed: " <> e)
    Ok(schema) -> {
      let prompt = build_study_prompt(meta, idx, max_facts, max_cases)
      let system =
        schemas.build_system_prompt(
          "You are studying a document for the agent's long-term memory. "
            <> "Two output buckets:\n"
            <> "1) <facts> — concrete, self-contained claims (definitions, "
            <> "dates, thresholds, named relationships). Each has a stable "
            <> "key, a value, source section, confidence.\n"
            <> "2) <cases> — procedural / pattern knowledge: how to assess "
            <> "X, when to apply Y, decision frameworks, heuristics, "
            <> "step-by-step approaches the agent could reuse on a similar "
            <> "problem. Each has an intent (the question it answers), a "
            <> "domain, keywords, the approach, optional steps, an "
            <> "assessment of why it's reusable, source section, confidence.\n"
            <> "Choose bucket by shape: \"X is Y\" / \"deadline is N\" → fact; "
            <> "\"to handle Z, do A then B\" / \"if X then Y\" → case. "
            <> "Skip vague generalities. Tie everything to a specific section.",
          schemas.study_output_xsd,
          schemas.study_output_example,
        )
      let config =
        xstructor.XStructorConfig(
          schema:,
          system_prompt: system,
          xml_example: schemas.study_output_example,
          max_retries: 2,
          // Cases push token budget up — give the model headroom so
          // it doesn't truncate mid-case and produce invalid XML.
          max_tokens: 3000,
        )
      case xstructor.generate(config, prompt, provider, model) {
        Error(e) ->
          ToolFailure(
            tool_use_id: call.id,
            error: "Study extraction failed: " <> string.slice(e, 0, 300),
          )
        Ok(result) -> {
          let extracted_facts = parse_extracted_facts(result.elements)
          let extracted_cases = parse_extracted_cases(result.elements)
          let written_facts =
            persist_study_facts(extracted_facts, ctx, meta, max_facts)
          let written_cases =
            persist_study_cases(extracted_cases, ctx, meta, max_cases)
          let summary =
            "Studied "
            <> meta.title
            <> " (doc:"
            <> knowledge_search.doc_slug_for(meta)
            <> "). "
            <> "Facts: extracted "
            <> int.to_string(list.length(extracted_facts))
            <> ", persisted "
            <> int.to_string(written_facts)
            <> ". Cases: extracted "
            <> int.to_string(list.length(extracted_cases))
            <> ", persisted "
            <> int.to_string(written_cases)
            <> " (confidence ≥ "
            <> float.to_string(study_min_confidence)
            <> ")."
          slog.info(
            "tools/remembrancer",
            "study_document",
            summary,
            Some(ctx.cycle_id),
          )
          ToolSuccess(tool_use_id: call.id, content: summary)
        }
      }
    }
  }
}

/// Build the prompt fed to the LLM. Lists each section with its
/// breadcrumb path and content. The model sees the whole document at
/// once — for very long docs this can blow the context window, but
/// the per-section structure helps it pin facts to specific sections.
fn build_study_prompt(
  meta: knowledge_types.DocumentMeta,
  idx: knowledge_types.DocumentIndex,
  max_facts: Int,
  max_cases: Int,
) -> String {
  let entries = flatten_tree_for_study(idx.root, "")
  let lines =
    list.index_map(entries, fn(t, i) {
      let #(node, path) = t
      let section = case path {
        "" -> node.title
        _ -> path
      }
      int.to_string(i + 1)
      <> ". §"
      <> section
      <> "\n"
      <> string.slice(node.content, 0, 800)
    })
  "Document: "
  <> meta.title
  <> " (slug: "
  <> knowledge_search.doc_slug_for(meta)
  <> ", domain: "
  <> meta.domain
  <> ")\n\n"
  <> "Sections:\n\n"
  <> string.join(lines, "\n\n")
  <> "\n\n"
  <> "Extract up to "
  <> int.to_string(max_facts)
  <> " factual claims (<facts>) and up to "
  <> int.to_string(max_cases)
  <> " procedural / pattern cases (<cases>). It is fine to emit zero "
  <> "of either bucket if the document doesn't yield that shape of "
  <> "knowledge. Use exact section paths from the headings above so "
  <> "everything is traceable. Skip entries with confidence < 0.6."
}

fn flatten_tree_for_study(
  node: knowledge_types.TreeNode,
  parent_path: String,
) -> List(#(knowledge_types.TreeNode, String)) {
  let child_path = case parent_path {
    "" -> node.title
    _ -> parent_path <> " / " <> node.title
  }
  let children =
    list.flat_map(node.children, fn(c) { flatten_tree_for_study(c, child_path) })
  [#(node, parent_path), ..children]
}

/// Walk the flat XStructor result dict, extracting fact records by
/// indexed path until missing. Mirrors the captures scanner pattern.
pub fn parse_extracted_facts(
  elements: dict.Dict(String, String),
) -> List(ExtractedFact) {
  parse_extracted_facts_indexed(elements, 0, [])
}

fn parse_extracted_facts_indexed(
  elements: dict.Dict(String, String),
  idx: Int,
  acc: List(ExtractedFact),
) -> List(ExtractedFact) {
  let base = "study_output.facts.fact." <> int.to_string(idx)
  case dict.get(elements, base <> ".key") {
    Error(_) -> list.reverse(acc)
    Ok(key) -> {
      let value = case dict.get(elements, base <> ".value") {
        Ok(v) -> v
        Error(_) -> ""
      }
      let section_path = case dict.get(elements, base <> ".section_path") {
        Ok(s) -> s
        Error(_) -> ""
      }
      let confidence = case dict.get(elements, base <> ".confidence") {
        Ok(c) -> parse_float_default(c, 0.5)
        Error(_) -> 0.5
      }
      let fact =
        ExtractedFact(
          key: string.trim(key),
          value: string.trim(value),
          section_path: string.trim(section_path),
          confidence: confidence,
        )
      parse_extracted_facts_indexed(elements, idx + 1, [fact, ..acc])
    }
  }
}

fn parse_float_default(s: String, default: Float) -> Float {
  case float.parse(string.trim(s)) {
    Ok(f) -> f
    Error(_) ->
      case int.parse(string.trim(s)) {
        Ok(i) -> int.to_float(i)
        Error(_) -> default
      }
  }
}

/// A single case parsed out of XStructor's flat element dict.
/// Mirrors ExtractedFact but carries the CBR problem/solution shape
/// — used when the document describes a procedure, heuristic, or
/// pattern rather than a standalone factual claim.
pub type ExtractedCase {
  ExtractedCase(
    intent: String,
    domain: String,
    keywords: List(String),
    approach: String,
    steps: List(String),
    assessment: String,
    section_path: String,
    confidence: Float,
  )
}

/// Walk the flat XStructor result dict, extracting case records by
/// indexed path until missing. Same shape as parse_extracted_facts.
pub fn parse_extracted_cases(
  elements: dict.Dict(String, String),
) -> List(ExtractedCase) {
  parse_extracted_cases_indexed(elements, 0, [])
}

fn parse_extracted_cases_indexed(
  elements: dict.Dict(String, String),
  idx: Int,
  acc: List(ExtractedCase),
) -> List(ExtractedCase) {
  let base = "study_output.cases.case." <> int.to_string(idx)
  case dict.get(elements, base <> ".intent") {
    Error(_) -> list.reverse(acc)
    Ok(intent) -> {
      let domain = case dict.get(elements, base <> ".domain") {
        Ok(d) -> d
        Error(_) -> ""
      }
      let approach = case dict.get(elements, base <> ".approach") {
        Ok(a) -> a
        Error(_) -> ""
      }
      let assessment = case dict.get(elements, base <> ".assessment") {
        Ok(a) -> a
        Error(_) -> ""
      }
      let section_path = case dict.get(elements, base <> ".section_path") {
        Ok(s) -> s
        Error(_) -> ""
      }
      let confidence = case dict.get(elements, base <> ".confidence") {
        Ok(c) -> parse_float_default(c, 0.5)
        Error(_) -> 0.5
      }
      let keywords =
        xstructor.extract_list(elements, base <> ".keywords.keyword")
        |> list.map(string.trim)
        |> list.filter(fn(k) { k != "" })
      let steps =
        xstructor.extract_list(elements, base <> ".steps.step")
        |> list.map(string.trim)
        |> list.filter(fn(s) { s != "" })
      let extracted =
        ExtractedCase(
          intent: string.trim(intent),
          domain: string.trim(domain),
          keywords: keywords,
          approach: string.trim(approach),
          steps: steps,
          assessment: string.trim(assessment),
          section_path: string.trim(section_path),
          confidence: confidence,
        )
      parse_extracted_cases_indexed(elements, idx + 1, [extracted, ..acc])
    }
  }
}

/// Persist a list of extracted cases to the CBR log as DomainKnowledge
/// cases. Filters by confidence floor (study_min_confidence, same as
/// facts) and caps total writes. Returns the number actually persisted.
///
/// Pure-ish: takes the cases list directly so tests can drive the
/// persistence layer without needing an XStructor / LLM round-trip.
pub fn persist_study_cases(
  cases: List(ExtractedCase),
  ctx: RemembrancerContext,
  meta: knowledge_types.DocumentMeta,
  max_cases: Int,
) -> Int {
  let slug = knowledge_search.doc_slug_for(meta)
  let kept =
    cases
    |> list.filter(fn(c) { c.confidence >=. study_min_confidence })
    |> list.take(max_cases)
  list.each(kept, fn(c) {
    let citation = "doc:" <> slug <> " §" <> c.section_path
    // Cases inherit the doc's domain when the LLM didn't supply one.
    let domain = case c.domain {
      "" -> meta.domain
      d -> d
    }
    let cbr_case =
      cbr_types.CbrCase(
        case_id: "case-" <> uuid_v4(),
        timestamp: get_datetime(),
        schema_version: 1,
        problem: cbr_types.CbrProblem(
          user_input: c.intent,
          intent: c.intent,
          domain: domain,
          entities: [],
          keywords: c.keywords,
          query_complexity: "complex",
        ),
        solution: cbr_types.CbrSolution(
          approach: c.approach,
          agents_used: [],
          tools_used: ["study_document"],
          steps: c.steps,
        ),
        outcome: cbr_types.CbrOutcome(
          status: "success",
          confidence: c.confidence,
          assessment: c.assessment,
          pitfalls: [],
        ),
        // No narrative entry backs a paper-derived case — the source
        // is the document section. Use the citation as the
        // source_narrative_id so it remains traceable in queries.
        source_narrative_id: citation,
        profile: None,
        redacted: False,
        category: Some(cbr_types.DomainKnowledge),
        usage_stats: Some(cbr_types.empty_usage_stats()),
        strategy_id: None,
      )
    cbr_log.append(ctx.cbr_dir, cbr_case)
    case ctx.librarian {
      Some(l) -> librarian.notify_new_case(l, cbr_case)
      None -> Nil
    }
  })
  list.length(kept)
}

/// Persist a list of extracted facts to the facts log with provenance
/// pointing back to the source section. Filters by confidence floor
/// and caps total writes. Returns the number actually persisted.
///
/// Pure-ish: takes the facts list directly so tests can drive the
/// persistence layer without needing an XStructor / LLM round-trip.
pub fn persist_study_facts(
  facts: List(ExtractedFact),
  ctx: RemembrancerContext,
  meta: knowledge_types.DocumentMeta,
  max_facts: Int,
) -> Int {
  let slug = knowledge_search.doc_slug_for(meta)
  let kept =
    facts
    |> list.filter(fn(f) { f.confidence >=. study_min_confidence })
    |> list.take(max_facts)
  list.each(kept, fn(f) {
    let citation = "doc:" <> slug <> " §" <> f.section_path
    let fact =
      facts_types.MemoryFact(
        schema_version: 1,
        fact_id: "fact-" <> uuid_v4(),
        timestamp: get_datetime(),
        cycle_id: ctx.cycle_id,
        agent_id: Some(ctx.agent_id),
        key: f.key,
        value: f.value,
        scope: facts_types.Persistent,
        operation: facts_types.Write,
        supersedes: None,
        confidence: f.confidence,
        source: citation,
        provenance: Some(facts_types.FactProvenance(
          source_cycle_id: ctx.cycle_id,
          source_tool: "study_document",
          source_agent: "remembrancer",
          derivation: facts_types.Synthesis,
        )),
      )
    facts_log.append(ctx.facts_dir, fact)
    case ctx.librarian {
      Some(l) -> librarian.notify_new_fact(l, fact)
      None -> Nil
    }
  })
  list.length(kept)
}
