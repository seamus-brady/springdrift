//// Study-cycle (study_document) tests.
////
//// What's tested:
//// - parse_extracted_facts walks the flat XStructor result dict and
////   builds ExtractedFact records by indexed path
//// - persist_study_facts filters by confidence floor, caps to
////   max_facts, writes MemoryFact records to the log with the right
////   provenance (source = doc:<slug> §<section>, derivation =
////   Synthesis, source_tool = study_document)
//// - Tool is registered correctly on the Remembrancer
////
//// What's NOT tested: the full LLM round-trip. That requires a real
//// provider; the stage we cover (extracted facts → persisted facts)
//// is the deterministic part and the place bugs would actually hide.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import cbr/log as cbr_log
import cbr/types as cbr_types
import facts/log as facts_log
import facts/types as facts_types
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import knowledge/types as knowledge_types
import simplifile
import tools/remembrancer

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/springdrift_test_study_" <> suffix
  let _ = simplifile.delete(dir)
  let _ = simplifile.create_directory_all(dir)
  dir
}

fn make_meta() -> knowledge_types.DocumentMeta {
  knowledge_types.DocumentMeta(
    op: knowledge_types.Create,
    doc_id: "doc-test",
    doc_type: knowledge_types.Source,
    domain: "papers",
    title: "Test Paper",
    path: "sources/papers/test-paper.md",
    status: knowledge_types.Normalised,
    content_hash: "",
    node_count: 1,
    created_at: "2026-04-25",
    updated_at: "2026-04-25",
    source_url: None,
    version: 1,
  )
}

fn make_ctx(facts_dir: String) -> remembrancer.RemembrancerContext {
  make_ctx_with_dirs(facts_dir, "/tmp/nopath_cbr")
}

fn make_ctx_with_dirs(
  facts_dir: String,
  cbr_dir: String,
) -> remembrancer.RemembrancerContext {
  remembrancer.RemembrancerContext(
    narrative_dir: "/tmp/nopath_narrative",
    cbr_dir: cbr_dir,
    facts_dir: facts_dir,
    knowledge_consolidation_dir: "/tmp/nopath_consolidation",
    consolidation_log_dir: "/tmp/nopath_consolidation_log",
    cycle_id: "cyc-test",
    agent_id: "remembrancer",
    librarian: None,
    review_confidence_threshold: 0.3,
    dormant_thread_days: 7,
    min_pattern_cases: 3,
    fact_decay_half_life_days: 30,
    gate_provider: None,
    gate_model: "test-model",
    skills_dir: "/tmp/nopath_skills",
    max_promotions_per_day: 3,
  )
}

// ---------------------------------------------------------------------------
// parse_extracted_facts — XStructor element-dict walker
// ---------------------------------------------------------------------------

pub fn parse_empty_dict_returns_empty_test() {
  remembrancer.parse_extracted_facts(dict.new())
  |> should.equal([])
}

pub fn parse_single_fact_test() {
  let elements =
    dict.new()
    |> dict.insert("study_output.facts.fact.0.key", "eu_ai_act_high_risk")
    |> dict.insert(
      "study_output.facts.fact.0.value",
      "Article 6 defines high-risk AI systems",
    )
    |> dict.insert(
      "study_output.facts.fact.0.section_path",
      "Title III / Article 6",
    )
    |> dict.insert("study_output.facts.fact.0.confidence", "0.9")

  case remembrancer.parse_extracted_facts(elements) {
    [f] -> {
      f.key |> should.equal("eu_ai_act_high_risk")
      f.value |> should.equal("Article 6 defines high-risk AI systems")
      f.section_path |> should.equal("Title III / Article 6")
      f.confidence |> should.equal(0.9)
    }
    _ -> should.fail()
  }
}

pub fn parse_multiple_facts_in_order_test() {
  let elements =
    dict.new()
    |> dict.insert("study_output.facts.fact.0.key", "first")
    |> dict.insert("study_output.facts.fact.0.value", "v1")
    |> dict.insert("study_output.facts.fact.0.section_path", "A")
    |> dict.insert("study_output.facts.fact.0.confidence", "0.8")
    |> dict.insert("study_output.facts.fact.1.key", "second")
    |> dict.insert("study_output.facts.fact.1.value", "v2")
    |> dict.insert("study_output.facts.fact.1.section_path", "B")
    |> dict.insert("study_output.facts.fact.1.confidence", "0.7")
    |> dict.insert("study_output.facts.fact.2.key", "third")
    |> dict.insert("study_output.facts.fact.2.value", "v3")
    |> dict.insert("study_output.facts.fact.2.section_path", "C")
    |> dict.insert("study_output.facts.fact.2.confidence", "0.6")

  let extracted = remembrancer.parse_extracted_facts(elements)
  list.length(extracted) |> should.equal(3)
  case extracted {
    [a, b, c] -> {
      a.key |> should.equal("first")
      b.key |> should.equal("second")
      c.key |> should.equal("third")
    }
    _ -> should.fail()
  }
}

pub fn parse_handles_missing_optional_fields_test() {
  // Missing confidence → defaults to 0.5; missing section_path → "".
  let elements =
    dict.new()
    |> dict.insert("study_output.facts.fact.0.key", "k")
    |> dict.insert("study_output.facts.fact.0.value", "v")

  case remembrancer.parse_extracted_facts(elements) {
    [f] -> {
      f.confidence |> should.equal(0.5)
      f.section_path |> should.equal("")
    }
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// persist_study_facts — filtering, capping, provenance
// ---------------------------------------------------------------------------

pub fn persist_filters_low_confidence_test() {
  // Confidence < 0.6 (study_min_confidence) is dropped silently.
  let dir = test_dir("filter_conf")
  let ctx = make_ctx(dir)
  let meta = make_meta()
  let facts = [
    remembrancer.ExtractedFact(
      key: "low",
      value: "v",
      section_path: "A",
      confidence: 0.4,
    ),
    remembrancer.ExtractedFact(
      key: "high",
      value: "v",
      section_path: "A",
      confidence: 0.9,
    ),
  ]

  let written = remembrancer.persist_study_facts(facts, ctx, meta, 100)
  written |> should.equal(1)

  // Verify only the high-confidence fact made it to disk.
  let loaded = facts_log.load_all(dir)
  list.length(loaded) |> should.equal(1)
  case loaded {
    [m] -> {
      let m: facts_types.MemoryFact = m
      m.key |> should.equal("high")
    }
    _ -> should.fail()
  }

  let _ = simplifile.delete(dir)
  Nil
}

pub fn persist_caps_at_max_facts_test() {
  let dir = test_dir("cap")
  let ctx = make_ctx(dir)
  let meta = make_meta()

  // Five facts, all above confidence floor. Cap to 2.
  let facts = [
    remembrancer.ExtractedFact(
      key: "a",
      value: "v",
      section_path: "S",
      confidence: 0.9,
    ),
    remembrancer.ExtractedFact(
      key: "b",
      value: "v",
      section_path: "S",
      confidence: 0.9,
    ),
    remembrancer.ExtractedFact(
      key: "c",
      value: "v",
      section_path: "S",
      confidence: 0.9,
    ),
    remembrancer.ExtractedFact(
      key: "d",
      value: "v",
      section_path: "S",
      confidence: 0.9,
    ),
    remembrancer.ExtractedFact(
      key: "e",
      value: "v",
      section_path: "S",
      confidence: 0.9,
    ),
  ]

  let written = remembrancer.persist_study_facts(facts, ctx, meta, 2)
  written |> should.equal(2)

  let _ = simplifile.delete(dir)
  Nil
}

pub fn persist_writes_correct_provenance_test() {
  let dir = test_dir("provenance")
  let ctx = make_ctx(dir)
  let meta = make_meta()
  // Slug derived from the meta is "papers/test-paper".
  let facts = [
    remembrancer.ExtractedFact(
      key: "claim_x",
      value: "the thing",
      section_path: "Introduction / Findings",
      confidence: 0.85,
    ),
  ]

  let _ = remembrancer.persist_study_facts(facts, ctx, meta, 100)

  let loaded = facts_log.load_all(dir)
  case loaded {
    [m] -> {
      let m: facts_types.MemoryFact = m
      // Source string is the structured citation.
      m.source
      |> should.equal("doc:papers/test-paper §Introduction / Findings")
      // Provenance carries study_document as the tool, remembrancer as
      // the agent, derivation = Synthesis (extracted from text, not
      // directly observed by a tool call).
      case m.provenance {
        Some(p) -> {
          p.source_tool |> should.equal("study_document")
          p.source_agent |> should.equal("remembrancer")
          p.derivation |> should.equal(facts_types.Synthesis)
        }
        None -> should.fail()
      }
      m.scope |> should.equal(facts_types.Persistent)
      m.confidence |> should.equal(0.85)
    }
    _ -> should.fail()
  }

  let _ = simplifile.delete(dir)
  Nil
}

// ---------------------------------------------------------------------------
// parse_extracted_cases — XStructor element-dict walker for the cases bucket
// ---------------------------------------------------------------------------

pub fn parse_empty_dict_returns_no_cases_test() {
  remembrancer.parse_extracted_cases(dict.new())
  |> should.equal([])
}

pub fn parse_single_case_test() {
  let elements =
    dict.new()
    |> dict.insert(
      "study_output.cases.case.0.intent",
      "How do I assess high-risk AI?",
    )
    |> dict.insert("study_output.cases.case.0.domain", "law")
    |> dict.insert(
      "study_output.cases.case.0.approach",
      "Check Annex III categories",
    )
    |> dict.insert(
      "study_output.cases.case.0.assessment",
      "Reusable classification framework",
    )
    |> dict.insert(
      "study_output.cases.case.0.section_path",
      "Title III / Article 6",
    )
    |> dict.insert("study_output.cases.case.0.confidence", "0.85")
    |> dict.insert("study_output.cases.case.0.keywords.keyword.0", "eu-ai-act")
    |> dict.insert("study_output.cases.case.0.keywords.keyword.1", "high-risk")
    |> dict.insert(
      "study_output.cases.case.0.steps.step.0",
      "Identify use case",
    )
    |> dict.insert(
      "study_output.cases.case.0.steps.step.1",
      "Cross-reference Annex III",
    )

  case remembrancer.parse_extracted_cases(elements) {
    [c] -> {
      c.intent |> should.equal("How do I assess high-risk AI?")
      c.domain |> should.equal("law")
      c.approach |> should.equal("Check Annex III categories")
      c.assessment |> should.equal("Reusable classification framework")
      c.section_path |> should.equal("Title III / Article 6")
      c.confidence |> should.equal(0.85)
      c.keywords |> should.equal(["eu-ai-act", "high-risk"])
      c.steps
      |> should.equal(["Identify use case", "Cross-reference Annex III"])
    }
    _ -> should.fail()
  }
}

pub fn parse_multiple_cases_in_order_test() {
  let elements =
    dict.new()
    |> dict.insert("study_output.cases.case.0.intent", "first intent")
    |> dict.insert("study_output.cases.case.0.approach", "approach 1")
    |> dict.insert("study_output.cases.case.0.section_path", "A")
    |> dict.insert("study_output.cases.case.0.confidence", "0.8")
    |> dict.insert("study_output.cases.case.1.intent", "second intent")
    |> dict.insert("study_output.cases.case.1.approach", "approach 2")
    |> dict.insert("study_output.cases.case.1.section_path", "B")
    |> dict.insert("study_output.cases.case.1.confidence", "0.7")

  case remembrancer.parse_extracted_cases(elements) {
    [a, b] -> {
      a.intent |> should.equal("first intent")
      a.approach |> should.equal("approach 1")
      b.intent |> should.equal("second intent")
      b.approach |> should.equal("approach 2")
    }
    _ -> should.fail()
  }
}

pub fn parse_handles_missing_optional_case_fields_test() {
  // Only required: intent, approach, section_path, confidence. The
  // rest default cleanly when absent.
  let elements =
    dict.new()
    |> dict.insert("study_output.cases.case.0.intent", "i")
    |> dict.insert("study_output.cases.case.0.approach", "a")
    |> dict.insert("study_output.cases.case.0.section_path", "S")
    |> dict.insert("study_output.cases.case.0.confidence", "0.9")

  case remembrancer.parse_extracted_cases(elements) {
    [c] -> {
      c.domain |> should.equal("")
      c.assessment |> should.equal("")
      c.keywords |> should.equal([])
      c.steps |> should.equal([])
    }
    _ -> should.fail()
  }
}

pub fn parse_handles_single_keyword_fallback_test() {
  // When XStructor's xmerl walker sees a single keyword inside a
  // single case, it emits the bare prefix path (no .0 suffix). The
  // extract_list helper falls back to that path so we still get
  // [keyword] back, not [].
  let elements =
    dict.new()
    |> dict.insert("study_output.cases.case.0.intent", "i")
    |> dict.insert("study_output.cases.case.0.approach", "a")
    |> dict.insert("study_output.cases.case.0.section_path", "S")
    |> dict.insert("study_output.cases.case.0.confidence", "0.9")
    |> dict.insert("study_output.cases.case.0.keywords.keyword", "lone")
    |> dict.insert("study_output.cases.case.0.steps.step", "only-step")

  case remembrancer.parse_extracted_cases(elements) {
    [c] -> {
      c.keywords |> should.equal(["lone"])
      c.steps |> should.equal(["only-step"])
    }
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// persist_study_cases — filtering, capping, CBR write
// ---------------------------------------------------------------------------

pub fn persist_cases_filters_low_confidence_test() {
  let cbr_dir = test_dir("cases_filter_conf")
  let ctx = make_ctx_with_dirs("/tmp/nopath_facts_unused", cbr_dir)
  let meta = make_meta()
  let cases = [
    remembrancer.ExtractedCase(
      intent: "low",
      domain: "law",
      keywords: ["k"],
      approach: "x",
      steps: [],
      assessment: "",
      section_path: "A",
      confidence: 0.4,
    ),
    remembrancer.ExtractedCase(
      intent: "high",
      domain: "law",
      keywords: ["k"],
      approach: "x",
      steps: [],
      assessment: "",
      section_path: "A",
      confidence: 0.9,
    ),
  ]

  let written = remembrancer.persist_study_cases(cases, ctx, meta, 100)
  written |> should.equal(1)

  let loaded = cbr_log.load_all(cbr_dir)
  list.length(loaded) |> should.equal(1)
  case loaded {
    [c] -> c.problem.intent |> should.equal("high")
    _ -> should.fail()
  }

  let _ = simplifile.delete(cbr_dir)
  Nil
}

pub fn persist_cases_caps_at_max_test() {
  let cbr_dir = test_dir("cases_cap")
  let ctx = make_ctx_with_dirs("/tmp/nopath_facts_unused", cbr_dir)
  let meta = make_meta()
  let cases =
    [1, 2, 3, 4, 5]
    |> list.map(fn(i) {
      remembrancer.ExtractedCase(
        intent: "intent " <> int.to_string(i),
        domain: "law",
        keywords: [],
        approach: "x",
        steps: [],
        assessment: "",
        section_path: "S",
        confidence: 0.9,
      )
    })

  let written = remembrancer.persist_study_cases(cases, ctx, meta, 2)
  written |> should.equal(2)

  let _ = simplifile.delete(cbr_dir)
  Nil
}

pub fn persist_cases_writes_correct_shape_test() {
  let cbr_dir = test_dir("cases_shape")
  let ctx = make_ctx_with_dirs("/tmp/nopath_facts_unused", cbr_dir)
  let meta = make_meta()
  // Slug derived from meta is "papers/test-paper".
  let cases = [
    remembrancer.ExtractedCase(
      intent: "How do I classify a high-risk AI system?",
      domain: "law",
      keywords: ["eu-ai-act", "high-risk"],
      approach: "Apply Annex III matching",
      steps: ["Identify use case", "Match to Annex III"],
      assessment: "Reusable framework",
      section_path: "Title III / Article 6",
      confidence: 0.85,
    ),
  ]

  let _ = remembrancer.persist_study_cases(cases, ctx, meta, 100)

  let loaded = cbr_log.load_all(cbr_dir)
  case loaded {
    [c] -> {
      c.problem.intent
      |> should.equal("How do I classify a high-risk AI system?")
      c.problem.domain |> should.equal("law")
      c.problem.keywords |> should.equal(["eu-ai-act", "high-risk"])
      c.solution.approach |> should.equal("Apply Annex III matching")
      c.solution.steps
      |> should.equal(["Identify use case", "Match to Annex III"])
      c.solution.tools_used |> should.equal(["study_document"])
      c.outcome.status |> should.equal("success")
      c.outcome.confidence |> should.equal(0.85)
      c.outcome.assessment |> should.equal("Reusable framework")
      c.category |> should.equal(Some(cbr_types.DomainKnowledge))
      // source_narrative_id carries the canonical paper citation so a
      // future query can trace the case back to the source section.
      c.source_narrative_id
      |> should.equal("doc:papers/test-paper §Title III / Article 6")
    }
    _ -> should.fail()
  }

  let _ = simplifile.delete(cbr_dir)
  Nil
}

pub fn persist_cases_inherits_doc_domain_when_empty_test() {
  // The LLM is allowed to omit the case's domain (it's optional in
  // the schema). When absent we fall back to the document's own
  // domain so retrieval still has a tag to filter by.
  let cbr_dir = test_dir("cases_inherit_domain")
  let ctx = make_ctx_with_dirs("/tmp/nopath_facts_unused", cbr_dir)
  // Document domain is "papers".
  let meta = make_meta()
  let cases = [
    remembrancer.ExtractedCase(
      intent: "i",
      domain: "",
      keywords: [],
      approach: "a",
      steps: [],
      assessment: "",
      section_path: "S",
      confidence: 0.9,
    ),
  ]

  let _ = remembrancer.persist_study_cases(cases, ctx, meta, 100)

  let loaded = cbr_log.load_all(cbr_dir)
  case loaded {
    [c] -> c.problem.domain |> should.equal("papers")
    _ -> should.fail()
  }

  let _ = simplifile.delete(cbr_dir)
  Nil
}

// ---------------------------------------------------------------------------
// Tool registration
// ---------------------------------------------------------------------------

pub fn study_document_tool_is_registered_test() {
  let names =
    remembrancer.all()
    |> list.map(fn(t) { t.name })
  names |> list.contains("study_document") |> should.be_true
  remembrancer.is_remembrancer_tool("study_document") |> should.be_true
}
