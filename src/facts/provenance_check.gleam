//// Synthesis-fact provenance strictness — Phase 3a structural guard.
////
//// When a fact is written with `derivation=Synthesis`, the cycle that
//// produced it must have called at least one evidence-grade tool.
//// Synthesis without evidence is prose laundered as durable memory —
//// exactly the April 20 failure mode, persisted into the fact store
//// where future cycles will cite it as sourced knowledge.
////
//// This module classifies every tool the cognitive loop can call as
//// either evidence-grade (anchors synthesis claims) or commentary-
//// grade (produces prose or state changes without external grounding).
//// See `docs/roadmap/planned/fluency-grounding-separation.md`
//// Appendix B for the full classification and rationale.
////
//// Pure module — the write-path wiring lives in the caller.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import facts/types as facts_types
import gleam/list
import gleam/option.{None, Some}

// ---------------------------------------------------------------------------
// Classification
// ---------------------------------------------------------------------------

/// A tool's evidence classification. Evidence-grade tools produce
/// structured, attributable output that can anchor a synthesis claim;
/// commentary-grade tools produce prose or state changes that cannot.
pub type EvidenceGrade {
  Evidence
  Commentary
}

/// Operator-configurable tool classification. The names list is
/// consulted whole-list — new tools not present default to `Commentary`
/// (safe default: can't anchor synthesis until explicitly allowed).
pub type EvidenceConfig {
  EvidenceConfig(
    /// Tools whose output can anchor synthesis claims in memory_write.
    evidence_tools: List(String),
    /// Confidence cap applied to synthesis writes that fail the check.
    /// Spec default is 0.5.
    downgrade_confidence_cap: Float,
  )
}

// ---------------------------------------------------------------------------
// Default classification (from spec Appendix B)
// ---------------------------------------------------------------------------

/// Evidence-grade tools — produce structured, attributable output.
/// A synthesis fact whose source cycle called one of these has a
/// plausible evidence chain. Matches the spec's Appendix B list.
pub fn default_evidence_tools() -> List(String) {
  [
    // Web research — returns content tied to query + URL
    "kagi_search",
    "kagi_summarize",
    "brave_web_search",
    "brave_news_search",
    "brave_llm_context",
    "brave_summarizer",
    "brave_answer",
    "jina_reader",
    "web_search",
    "fetch_url",
    // Memory retrieval — returns content already in the store
    "memory_read",
    "memory_query_facts",
    "recall_recent",
    "recall_search",
    "recall_cases",
    "recall_threads",
    "deep_search",
    "fact_archaeology",
    "find_connections",
    "resurrect_thread",
    // Analysis — produces structured output the agent can cite verbatim
    "analyze_affect_performance",
    "mine_patterns",
    "detect_patterns",
    "get_forecast_breakdown",
    "query_tool_activity",
    "review_recent",
    "inspect_cycle",
    "list_recent_cycles",
    "consolidate_memory",
    "extract_insights",
    // Sandbox execution — produces stdout/stderr the agent can attribute
    "run_code",
    "sandbox_exec",
    "workspace_ls",
    // Artifacts — returns stored content
    "retrieve_result",
    "read_file",
    // Comms inputs — external content, verbatim
    "check_inbox",
    "read_message",
    // Phase 2 integrity audits — the audits themselves produce
    // deterministic structured output, so their own writes are evidence.
    "audit_fabrication",
    "audit_voice_drift",
  ]
}

/// Default configuration. Confidence cap of 0.5 matches the spec.
pub fn default_config() -> EvidenceConfig {
  EvidenceConfig(
    evidence_tools: default_evidence_tools(),
    downgrade_confidence_cap: 0.5,
  )
}

// ---------------------------------------------------------------------------
// Classification logic
// ---------------------------------------------------------------------------

/// Grade a tool by name against the configured evidence list.
/// Unknown tools default to Commentary (safe — won't anchor synthesis).
pub fn grade(config: EvidenceConfig, tool_name: String) -> EvidenceGrade {
  case list.contains(config.evidence_tools, tool_name) {
    True -> Evidence
    False -> Commentary
  }
}

/// True when the given cycle's tool calls include at least one
/// evidence-grade tool. This is the condition a Synthesis-derivation
/// write must satisfy to remain Synthesis.
pub fn has_evidence_grade(
  config: EvidenceConfig,
  tool_names: List(String),
) -> Bool {
  list.any(tool_names, fn(name) { grade(config, name) == Evidence })
}

// ---------------------------------------------------------------------------
// Fact downgrade
// ---------------------------------------------------------------------------

/// Apply the Phase 3a provenance check to a fact about to be written.
///
/// If the fact is a Synthesis-derivation write AND its source cycle did
/// not call an evidence-grade tool, return a downgraded fact with
/// `derivation=Unknown` and confidence capped at
/// `config.downgrade_confidence_cap`. All other cases return the fact
/// unchanged.
///
/// `tool_names` is the list of tools fired during the fact's source
/// cycle, typically gathered from the cognitive loop's cycle_tool_calls
/// at write time.
pub fn apply_check(
  fact: facts_types.MemoryFact,
  tool_names: List(String),
  config: EvidenceConfig,
) -> facts_types.MemoryFact {
  case fact.provenance {
    None -> fact
    Some(p) ->
      case p.derivation {
        facts_types.Synthesis ->
          case has_evidence_grade(config, tool_names) {
            True -> fact
            False -> downgrade(fact, p, config)
          }
        _ -> fact
      }
  }
}

fn downgrade(
  fact: facts_types.MemoryFact,
  provenance: facts_types.FactProvenance,
  config: EvidenceConfig,
) -> facts_types.MemoryFact {
  let capped_confidence = case
    fact.confidence >. config.downgrade_confidence_cap
  {
    True -> config.downgrade_confidence_cap
    False -> fact.confidence
  }
  facts_types.MemoryFact(
    ..fact,
    confidence: capped_confidence,
    provenance: Some(
      facts_types.FactProvenance(..provenance, derivation: facts_types.Unknown),
    ),
  )
}
