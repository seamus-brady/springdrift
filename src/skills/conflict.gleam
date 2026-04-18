//// LLM-driven skill conflict classifier.
////
//// For each existing Active skill scoped to the same agents as a new
//// proposal, asks the LLM to classify the relationship as
//// Complementary / Redundant / Supersedes / Contradictory.
////
//// Returns the strongest classification across all comparisons:
//// Contradictory > Supersedes > Redundant > Complementary. The safety
//// gate uses this to reject Contradictory proposals; Supersedes / Redundant
//// are reported but treated as Complementary for now (auto-archival of the
//// older skill is a follow-up).

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dict
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import llm/provider.{type Provider}
import paths
import simplifile
import skills.{type SkillMeta}
import skills/proposal.{
  type ConflictClassification, type SkillProposal, Complementary, Contradictory,
  Redundant, Supersedes, Unknown,
}
import slog
import xstructor
import xstructor/schemas

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Classify a proposal against every existing Active skill scoped to the
/// same agents. Returns the strongest classification across all
/// comparisons. Skills with no agent overlap are skipped (different
/// scopes can't conflict).
///
/// When the LLM call fails for an individual comparison, that comparison
/// is treated as Complementary (fail-open at the per-comparison level —
/// the gate's other layers still apply). When ALL comparisons fail, the
/// classifier returns `Unknown` so the gate can decide what to do.
pub fn classify(
  proposal: SkillProposal,
  existing: List(SkillMeta),
  provider: Provider,
  model: String,
) -> ConflictClassification {
  let candidates = same_scope_candidates(proposal, existing)
  case candidates {
    [] -> Complementary
    _ -> {
      let classifications =
        list.map(candidates, fn(s) {
          classify_pair(proposal, s, provider, model)
        })
      // strongest: Contradictory > Supersedes > Redundant > Complementary
      // Unknown only if every comparison failed
      let any_contradictory =
        list.any(classifications, fn(c) {
          case c {
            Contradictory(_) -> True
            _ -> False
          }
        })
      let any_supersedes =
        list.any(classifications, fn(c) {
          case c {
            Supersedes(_) -> True
            _ -> False
          }
        })
      let any_redundant =
        list.any(classifications, fn(c) {
          case c {
            Redundant(_) -> True
            _ -> False
          }
        })
      let all_unknown =
        list.all(classifications, fn(c) {
          case c {
            Unknown -> True
            _ -> False
          }
        })
      case any_contradictory, any_supersedes, any_redundant, all_unknown {
        True, _, _, _ ->
          // Pick the first Contradictory — its target_id is what the gate
          // reports.
          first_matching(classifications, fn(c) {
            case c {
              Contradictory(_) -> True
              _ -> False
            }
          })
        _, True, _, _ ->
          first_matching(classifications, fn(c) {
            case c {
              Supersedes(_) -> True
              _ -> False
            }
          })
        _, _, True, _ ->
          first_matching(classifications, fn(c) {
            case c {
              Redundant(_) -> True
              _ -> False
            }
          })
        _, _, _, True -> Unknown
        _, _, _, _ -> Complementary
      }
    }
  }
}

fn first_matching(
  list: List(ConflictClassification),
  pred: fn(ConflictClassification) -> Bool,
) -> ConflictClassification {
  case list.find(list, pred) {
    Ok(c) -> c
    Error(_) -> Complementary
  }
}

fn same_scope_candidates(
  proposal: SkillProposal,
  existing: List(SkillMeta),
) -> List(SkillMeta) {
  list.filter(existing, fn(s) {
    case s.status {
      skills.Archived -> False
      skills.Active ->
        list.any(s.agents, fn(a) { list.contains(proposal.agents, a) })
    }
  })
}

// ---------------------------------------------------------------------------
// LLM call (XStructor-validated)
// ---------------------------------------------------------------------------

fn classify_pair(
  proposal: SkillProposal,
  existing: SkillMeta,
  provider: Provider,
  model: String,
) -> ConflictClassification {
  let prompt = build_prompt(proposal, existing)
  let schema_dir = paths.schemas_dir()
  case
    xstructor.compile_schema(
      schema_dir,
      "skill_conflict.xsd",
      schemas.skill_conflict_xsd,
    )
  {
    Error(e) -> {
      slog.warn(
        "skills/conflict",
        "classify_pair",
        "schema compile failed: " <> e <> " (treating as Unknown)",
        None,
      )
      Unknown
    }
    Ok(schema) -> {
      let system_prompt =
        schemas.build_system_prompt(
          "You are a skill-conflict classifier for an autonomous agent. "
            <> "Compare two skill bodies and decide their relationship. Be "
            <> "strict about contradictions — two skills giving opposite "
            <> "guidance for the same situation is Contradictory, not "
            <> "Complementary.",
          schemas.skill_conflict_xsd,
          schemas.skill_conflict_example,
        )
      let config =
        xstructor.XStructorConfig(
          schema:,
          system_prompt:,
          xml_example: schemas.skill_conflict_example,
          max_retries: 2,
          max_tokens: 512,
        )
      case xstructor.generate(config, prompt, provider, model) {
        Error(e) -> {
          slog.warn(
            "skills/conflict",
            "classify_pair",
            "generate failed: " <> e,
            None,
          )
          Unknown
        }
        Ok(result) -> extract_classification(result.elements, existing.id)
      }
    }
  }
}

fn build_prompt(proposal: SkillProposal, existing: SkillMeta) -> String {
  let body_existing =
    simplifile.read(existing.path) |> result.unwrap("(unavailable)")
  "## New proposal\n\n"
  <> "Name: "
  <> proposal.name
  <> "\nAgents: "
  <> string.join(proposal.agents, ", ")
  <> "\n\n### Body\n\n"
  <> proposal.body
  <> "\n\n## Existing Active skill (id: "
  <> existing.id
  <> ")\n\n"
  <> "Name: "
  <> existing.name
  <> "\nAgents: "
  <> string.join(existing.agents, ", ")
  <> "\n\n### Body\n\n"
  <> body_existing
}

fn extract_classification(
  elements: dict.Dict(String, String),
  target_id: String,
) -> ConflictClassification {
  case dict.get(elements, "conflict.kind") {
    Ok(kind) ->
      case string.lowercase(kind) {
        "complementary" -> Complementary
        "redundant" -> Redundant(target_id:)
        "supersedes" -> Supersedes(target_id:)
        "contradictory" -> Contradictory(target_id:)
        _ -> Unknown
      }
    Error(_) -> Unknown
  }
}
