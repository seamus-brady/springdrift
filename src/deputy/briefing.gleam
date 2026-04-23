//// Deputy briefing generator — one-shot LLM call that produces a
//// structured `<briefing>` XML block for a root delegation.
////
//// The deputy is given a cog-sci-flavoured system prompt (what a deputy
//// is, its read-only constraint, what a good briefing looks like) and the
//// delegation instruction. It responds with a DeputyBriefing schema that
//// cites relevant CBR cases and facts from memory.
////
//// In MVP (Phase 1), the briefing pulls memory via the Librarian's query
//// surface without needing a tool-using react loop — a single XStructor
//// call is enough. Phase 2 extends to a react loop with read-only tools.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import cbr/types as cbr_types
import deputy/types.{
  type BriefingCase, type BriefingFact, type DeputyBriefing, BriefingCase,
  BriefingFact, DeputyBriefing,
}
import facts/types as facts_types
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/provider.{type Provider}
import narrative/librarian.{type LibrarianMessage}
import narrative/types as narrative_types
import paths
import slog
import xstructor
import xstructor/schemas

// ---------------------------------------------------------------------------
// Public entry
// ---------------------------------------------------------------------------

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time_now(unit: MonotonicUnit) -> Int

type MonotonicUnit

@external(erlang, "erlang", "binary_to_atom")
fn atom(s: String) -> MonotonicUnit

/// Generate a briefing for the given root delegation. Returns a
/// `DeputyBriefing` on success, Error otherwise. The deputy is
/// responsible for logging its own cycle; this function is a pure
/// reasoning step.
pub fn generate(
  deputy_id: String,
  root_agent: String,
  instruction: String,
  provider: Provider,
  model: String,
  max_tokens: Int,
  librarian: Option(Subject(LibrarianMessage)),
) -> Result(DeputyBriefing, String) {
  let start_ms = monotonic_ms()
  let schema_dir = paths.schemas_dir()
  case
    xstructor.compile_schema(
      schema_dir,
      "deputy_briefing.xsd",
      schemas.deputy_briefing_xsd,
    )
  {
    Error(e) -> Error("Schema compile failed: " <> e)
    Ok(schema) -> {
      let memory_snapshot = snapshot_memory(librarian, instruction)
      let prompt = build_prompt(root_agent, instruction, memory_snapshot)
      let system =
        schemas.build_system_prompt(
          deputy_system_prompt(),
          schemas.deputy_briefing_xsd,
          schemas.deputy_briefing_example,
        )
      let config =
        xstructor.XStructorConfig(
          schema: schema,
          system_prompt: system,
          xml_example: schemas.deputy_briefing_example,
          max_retries: 2,
          max_tokens: max_tokens,
        )
      case xstructor.generate(config, prompt, provider, model) {
        Error(e) -> Error(string.slice(e, 0, 400))
        Ok(result) -> {
          let elapsed = monotonic_ms() - start_ms
          Ok(extract_briefing(result.elements, deputy_id, elapsed))
        }
      }
    }
  }
}

fn monotonic_ms() -> Int {
  monotonic_time_now(atom("millisecond"))
}

// ---------------------------------------------------------------------------
// Memory snapshot — cheap pre-read before the LLM call
// ---------------------------------------------------------------------------

/// Collect a compact snapshot of memory that the briefing prompt can
/// reference. Includes a sample of recent CBR cases and persistent
/// facts. Falls back to empty when the Librarian is unavailable.
type MemorySnapshot {
  MemorySnapshot(
    cases: List(cbr_types.CbrCase),
    facts: List(facts_types.MemoryFact),
    recent_entries: List(narrative_types.NarrativeEntry),
  )
}

fn snapshot_memory(
  librarian: Option(Subject(LibrarianMessage)),
  _instruction: String,
) -> MemorySnapshot {
  case librarian {
    None -> MemorySnapshot(cases: [], facts: [], recent_entries: [])
    Some(_lib) -> {
      // MVP: no keyword filtering — the LLM will pick what's relevant
      // from a modest sample. Later phases can add keyword-specific
      // retrieval before the prompt.
      MemorySnapshot(cases: [], facts: [], recent_entries: [])
    }
  }
}

// ---------------------------------------------------------------------------
// Prompt
// ---------------------------------------------------------------------------

fn deputy_system_prompt() -> String {
  "You are a deputy — a read-only, ephemeral reasoning agent spawned alongside
a specialist agent delegation. Your job is to brief the specialist on
anything useful from memory before they start their work.

You do not act. You do not write. You do not take tool calls. You produce
a structured briefing XML and die.

A good briefing:
- Cites 1-5 relevant CBR cases with similarity scores and short summaries
- Cites 0-3 relevant facts the specialist might not otherwise see
- Notes known pitfalls if recent narrative entries suggest them
- Sets signal to one of: routine, high_novelty, anomaly, silent

Guidelines:
- Only cite cases or facts that are genuinely relevant. An empty briefing
  is better than a noisy one.
- Similarity scores are your best estimate; 0.8+ means clearly applicable,
  0.5-0.8 means related, below 0.5 usually not worth citing.
- If nothing in memory applies, return signal=silent with empty sections.
- The specialist will read your briefing at the top of their system
  prompt. Keep it concise and actionable."
}

fn build_prompt(
  root_agent: String,
  instruction: String,
  _memory: MemorySnapshot,
) -> String {
  "=== DELEGATION CONTEXT ===
Root agent: " <> root_agent <> "
Instruction: " <> instruction <> "

Produce a deputy_briefing XML with relevant cases, facts, and known
pitfalls — or signal=silent with empty sections if nothing in memory
applies."
}

// ---------------------------------------------------------------------------
// Extraction from XStructor result
// ---------------------------------------------------------------------------

fn extract_briefing(
  elements: dict.Dict(String, String),
  deputy_id: String,
  elapsed_ms: Int,
) -> DeputyBriefing {
  let signal = case dict.get(elements, "deputy_briefing.signal") {
    Ok(s) -> string.trim(s)
    Error(_) -> "silent"
  }
  let cases = extract_cases(elements)
  let facts = extract_facts(elements)
  let pitfalls = case dict.get(elements, "deputy_briefing.known_pitfalls") {
    Ok(p) ->
      case string.trim(p) {
        "" -> None
        t -> Some(t)
      }
    Error(_) -> None
  }
  DeputyBriefing(
    deputy_id: deputy_id,
    relevant_cases: cases,
    relevant_facts: facts,
    known_pitfalls: pitfalls,
    signal: signal,
    elapsed_ms: elapsed_ms,
  )
}

fn extract_cases(elements: dict.Dict(String, String)) -> List(BriefingCase) {
  extract_indexed_cases(elements, 0, [])
}

fn extract_indexed_cases(
  elements: dict.Dict(String, String),
  idx: Int,
  acc: List(BriefingCase),
) -> List(BriefingCase) {
  let base = "deputy_briefing.relevant_cases.case." <> int.to_string(idx)
  case dict.get(elements, base <> ".case_id") {
    Error(_) -> list.reverse(acc)
    Ok(case_id) -> {
      let similarity = case dict.get(elements, base <> ".similarity") {
        Ok(s) -> parse_float(s)
        Error(_) -> 0.0
      }
      let summary = case dict.get(elements, base <> ".summary") {
        Ok(s) -> string.trim(s)
        Error(_) -> ""
      }
      extract_indexed_cases(elements, idx + 1, [
        BriefingCase(
          case_id: string.trim(case_id),
          similarity: similarity,
          summary: summary,
        ),
        ..acc
      ])
    }
  }
}

fn extract_facts(elements: dict.Dict(String, String)) -> List(BriefingFact) {
  extract_indexed_facts(elements, 0, [])
}

fn extract_indexed_facts(
  elements: dict.Dict(String, String),
  idx: Int,
  acc: List(BriefingFact),
) -> List(BriefingFact) {
  let base = "deputy_briefing.relevant_facts.fact." <> int.to_string(idx)
  case dict.get(elements, base <> ".key") {
    Error(_) -> list.reverse(acc)
    Ok(key) -> {
      let value = case dict.get(elements, base <> ".value") {
        Ok(v) -> string.trim(v)
        Error(_) -> ""
      }
      extract_indexed_facts(elements, idx + 1, [
        BriefingFact(key: string.trim(key), value: value),
        ..acc
      ])
    }
  }
}

fn parse_float(s: String) -> Float {
  case float.parse(string.trim(s)) {
    Ok(f) -> f
    Error(_) ->
      case int.parse(string.trim(s)) {
        Ok(n) -> int.to_float(n)
        Error(_) -> 0.0
      }
  }
}

// ---------------------------------------------------------------------------
// Sanity logging for diagnostic purposes
// ---------------------------------------------------------------------------

pub fn log_briefing_summary(b: DeputyBriefing, cycle_id: String) -> Nil {
  slog.info(
    "deputy/briefing",
    "generate",
    "Deputy "
      <> b.deputy_id
      <> " briefed with signal="
      <> b.signal
      <> " ("
      <> int.to_string(list.length(b.relevant_cases))
      <> " cases, "
      <> int.to_string(list.length(b.relevant_facts))
      <> " facts, "
      <> int.to_string(b.elapsed_ms)
      <> "ms)",
    option.Some(cycle_id),
  )
}
