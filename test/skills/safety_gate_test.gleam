// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import dprime/types as dprime_types
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import simplifile
import skills/proposal.{type SkillProposal, SkillProposal, Unknown}
import skills/safety_gate

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn fresh_dir(suffix: String) -> String {
  let dir = "/tmp/skills_safety_gate_test_" <> suffix
  let _ = simplifile.delete_all([dir])
  let _ = simplifile.create_directory_all(dir)
  dir
}

fn make_proposal(id: String, body: String) -> SkillProposal {
  SkillProposal(
    proposal_id: id,
    name: "Test Skill",
    description: "A test skill for the safety gate",
    body: body,
    agents: ["researcher"],
    contexts: ["research"],
    source_cases: ["case-1"],
    confidence: 0.85,
    proposed_by: "remembrancer",
    proposed_at: "2026-04-18T10:00:00Z",
    conflict: Unknown,
  )
}

fn no_llm_config() -> safety_gate.GateConfig {
  // Disable the LLM scorer so tests run deterministically.
  safety_gate.GateConfig(
    ..safety_gate.default_config(),
    enable_llm_scorer: False,
  )
}

// ---------------------------------------------------------------------------
// Deterministic pre-filter
// ---------------------------------------------------------------------------

pub fn deterministic_passes_clean_body_test() {
  let result =
    safety_gate.check_deterministic("Use brave_answer for factual queries.")
  case result {
    safety_gate.DeterministicPass -> True |> should.be_true
    _ -> True |> should.be_false
  }
}

pub fn deterministic_blocks_credential_test() {
  let result =
    safety_gate.check_deterministic(
      "Use api_key=sk-abc123def456ghi789jkl012mno345 for the call.",
    )
  case result {
    safety_gate.DeterministicBlock(rule:, sample: _) -> {
      rule |> should.equal("credential")
    }
    _ -> True |> should.be_false
  }
}

pub fn deterministic_blocks_localhost_test() {
  let result =
    safety_gate.check_deterministic("Connect to localhost for the database.")
  case result {
    safety_gate.DeterministicBlock(rule:, sample: _) ->
      rule |> should.equal("internal_url")
    _ -> True |> should.be_false
  }
}

pub fn deterministic_blocks_absolute_path_test() {
  let result =
    safety_gate.check_deterministic(
      "Read /Users/admin/secrets.txt for the config.",
    )
  case result {
    safety_gate.DeterministicBlock(rule:, sample: _) ->
      rule |> should.equal("path")
    _ -> True |> should.be_false
  }
}

pub fn deterministic_blocks_env_var_test() {
  let result =
    safety_gate.check_deterministic("Set $OPENAI_API_KEY before running.")
  case result {
    safety_gate.DeterministicBlock(rule:, sample: _) ->
      rule |> should.equal("env_var")
    _ -> True |> should.be_false
  }
}

// ---------------------------------------------------------------------------
// Promote to disk
// ---------------------------------------------------------------------------

pub fn promote_to_disk_writes_skill_files_test() {
  let dir = fresh_dir("promote")
  let p = make_proposal("test-skill", "Pick the right tool for the job.")
  let result = safety_gate.promote_to_disk(p, dir)
  result |> should.be_ok
  // SKILL.md and skill.toml should exist under dir/<proposal_id>/
  simplifile.is_file(dir <> "/test-skill/SKILL.md") |> should.equal(Ok(True))
  simplifile.is_file(dir <> "/test-skill/skill.toml") |> should.equal(Ok(True))
  // SKILL.md should contain the body
  let assert Ok(md) = simplifile.read(dir <> "/test-skill/SKILL.md")
  string.contains(md, "Pick the right tool for the job.") |> should.be_true
  // skill.toml should be valid TOML with the proposal id
  let assert Ok(toml) = simplifile.read(dir <> "/test-skill/skill.toml")
  string.contains(toml, "id = \"test-skill\"") |> should.be_true
  string.contains(toml, "status = \"active\"") |> should.be_true
}

// ---------------------------------------------------------------------------
// gate_proposal — top-level pipeline
// ---------------------------------------------------------------------------

pub fn gate_accepts_clean_proposal_test() {
  let skills_dir = fresh_dir("gate_accept_skills")
  let log_dir = fresh_dir("gate_accept_log")
  let p =
    make_proposal("clean-skill", "Use brave_answer for single-fact queries.")
  let outcome =
    safety_gate.gate_proposal(
      p,
      [],
      skills_dir,
      log_dir,
      no_llm_config(),
      None,
      "",
    )
  outcome.decision |> should.equal(dprime_types.Accept)
  outcome.skill_path |> should.equal(skills_dir <> "/clean-skill/SKILL.md")
  // Log should contain a created event
  let lines = simplifile.read(log_dir <> "/" <> today_date() <> "-skills.jsonl")
  case lines {
    Ok(content) ->
      string.contains(content, "\"event\":\"created\"") |> should.be_true
    Error(_) -> True |> should.be_false
  }
}

pub fn gate_rejects_credential_proposal_test() {
  let skills_dir = fresh_dir("gate_cred_skills")
  let log_dir = fresh_dir("gate_cred_log")
  let p =
    make_proposal(
      "leaky",
      "Set api_key=sk-abcdef123456789012345678 for OpenAI.",
    )
  let outcome =
    safety_gate.gate_proposal(
      p,
      [],
      skills_dir,
      log_dir,
      no_llm_config(),
      None,
      "",
    )
  outcome.decision |> should.equal(dprime_types.Reject)
  outcome.layer |> should.equal("deterministic")
  // No SKILL.md should have been written
  simplifile.is_file(skills_dir <> "/leaky/SKILL.md") |> should.equal(Ok(False))
}

pub fn gate_rate_limits_after_max_per_day_test() {
  let skills_dir = fresh_dir("gate_rate_skills")
  let log_dir = fresh_dir("gate_rate_log")
  let cfg =
    safety_gate.GateConfig(
      ..safety_gate.default_config(),
      enable_llm_scorer: False,
      max_proposals_per_day: 2,
    )
  // Accept twice, then the third should be rate-limited.
  let p1 = make_proposal("first", "Use brave_answer for facts.")
  let p2 = make_proposal("second", "Use kagi_search for premium results.")
  let p3 = make_proposal("third", "Use jina_reader for clean extracts.")
  let _ = safety_gate.gate_proposal(p1, [], skills_dir, log_dir, cfg, None, "")
  let _ = safety_gate.gate_proposal(p2, [], skills_dir, log_dir, cfg, None, "")
  let outcome3 =
    safety_gate.gate_proposal(p3, [], skills_dir, log_dir, cfg, None, "")
  outcome3.decision |> should.equal(dprime_types.Reject)
  outcome3.layer |> should.equal("rate_limit")
}

// ---------------------------------------------------------------------------
// Skill features
// ---------------------------------------------------------------------------

pub fn skill_features_includes_critical_set_test() {
  let features = safety_gate.skill_features()
  let critical_count = list.count(features, fn(f) { f.critical })
  critical_count |> should.equal(3)
  let names = list.map(features, fn(f) { f.name })
  list.contains(names, "credential_exposure") |> should.be_true
  list.contains(names, "pii_exposure") |> should.be_true
  list.contains(names, "character_violation") |> should.be_true
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "get_date")
fn today_date() -> String
