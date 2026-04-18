//// LLM-driven proposal body generation.
////
//// Takes the structured cluster fields the pattern detector emits
//// (common tools, common agents, recurring keywords, source case ids)
//// and produces a markdown skill body that reads as agent guidance,
//// not as a debug dump.
////
//// Falls back to the structural template when the LLM call fails — the
//// proposal still ships, just with the less-polished body. Body
//// generation is a quality concern, not a safety one (the safety gate
//// runs against whichever body wins).

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import llm/provider.{type Provider}
import paths
import skills/proposal.{type SkillProposal, SkillProposal}
import slog
import xstructor
import xstructor/schemas

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Generate a polished markdown body for `proposal`. On any failure
/// (schema compile, LLM call, missing fields) returns the proposal
/// unchanged so the caller's structural-template body wins.
pub fn enrich(
  proposal: SkillProposal,
  provider: Provider,
  model: String,
) -> SkillProposal {
  case generate(proposal, provider, model) {
    Ok(body) -> SkillProposal(..proposal, body: body)
    Error(_) -> proposal
  }
}

fn generate(
  proposal: SkillProposal,
  provider: Provider,
  model: String,
) -> Result(String, String) {
  let prompt = build_prompt(proposal)
  let schema_dir = paths.schemas_dir()
  use schema <- result.try(xstructor.compile_schema(
    schema_dir,
    "skill_body.xsd",
    schemas.skill_body_xsd,
  ))
  let system =
    schemas.build_system_prompt(
      "You write skill bodies for an autonomous agent's instruction "
        <> "library. Take the cluster of supporting evidence and produce "
        <> "concise, actionable guidance. Use plain prose. Don't repeat the "
        <> "case-IDs back at the agent — they're metadata.",
      schemas.skill_body_xsd,
      schemas.skill_body_example,
    )
  let config =
    xstructor.XStructorConfig(
      schema:,
      system_prompt: system,
      xml_example: schemas.skill_body_example,
      max_retries: 2,
      max_tokens: 1024,
    )
  case xstructor.generate(config, prompt, provider, model) {
    Error(e) -> {
      slog.warn(
        "skills/body_gen",
        "generate",
        "LLM body gen failed: " <> e <> " (template body retained)",
        None,
      )
      Error(e)
    }
    Ok(result) ->
      case extract_body(result.elements) {
        Ok(body) -> Ok(body)
        Error(reason) -> {
          slog.warn(
            "skills/body_gen",
            "generate",
            "missing fields: " <> reason,
            None,
          )
          Error(reason)
        }
      }
  }
}

fn build_prompt(p: SkillProposal) -> String {
  let case_count = list.length(p.source_cases)
  "## Proposed skill\n\n"
  <> "Name: "
  <> p.name
  <> "\n"
  <> "Description: "
  <> p.description
  <> "\n"
  <> "Agents: "
  <> string.join(p.agents, ", ")
  <> "\n"
  <> "Domains: "
  <> string.join(p.contexts, ", ")
  <> "\n"
  <> "Supporting cases: "
  <> int.to_string(case_count)
  <> "\n\n"
  <> "## Structural template (replace with polished prose)\n\n"
  <> p.body
}

fn extract_body(elements: dict.Dict(String, String)) -> Result(String, String) {
  let heading = dict.get(elements, "skill_body.heading") |> result.unwrap("")
  let description =
    dict.get(elements, "skill_body.description") |> result.unwrap("")
  let guidance = dict.get(elements, "skill_body.guidance") |> result.unwrap("")
  case heading, description, guidance {
    "", _, _ -> Error("missing heading")
    _, _, "" -> Error("missing guidance")
    _, _, _ ->
      Ok(
        "## "
        <> heading
        <> "\n\n"
        <> description
        <> case description {
          "" -> ""
          _ -> "\n\n"
        }
        <> guidance,
      )
  }
}
