//// Promotion Safety Gate — three layers between a SkillProposal and an
//// Active skill on disk:
////
//// 1. Deterministic pre-filter — regex rules that auto-reject proposals
////    leaking credentials, internal URLs, absolute paths, or env var refs.
////    Runs first, no LLM cost, fastest path to rejection.
//// 2. Rate limit — hard cap on accepted promotions per rolling 24h window.
////    Excess proposals are dropped silently with a logged audit trail.
//// 3. D' scorer — LLM evaluates the proposal body against skill-specific
////    features (credential_exposure, pii_exposure, internal_url_exposure,
////    system_internals, character_violation). High score → reject.
////
//// Conflict classification (Complementary / Redundant / Supersedes /
//// Contradictory) is stubbed in this module — the LLM-driven classifier
//// is a follow-up. Until then proposals carry `Unknown` and the gate
//// treats them as Complementary.
////
//// On Accept: writes `<skill_dir>/SKILL.md` + `<skill_dir>/skill.toml`
//// and appends a `SkillCreated` event to the proposal log.
//// On Reject: appends a `SkillRejected` event with the reason.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import dprime/engine as dprime_engine
import dprime/scorer as dprime_scorer
import dprime/types as dprime_types
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm/provider.{type Provider}
import simplifile
import skills.{type SkillMeta}
import skills/proposal.{type SkillProposal}
import skills/proposal_log
import slog

@external(erlang, "springdrift_ffi", "re_match_caseless")
fn re_match_caseless(text: String, pattern: String) -> Bool

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

pub type GateConfig {
  GateConfig(
    /// Hard cap on Accepted promotions per rolling 24h window
    /// (spec default: 3).
    max_proposals_per_day: Int,
    /// Min hours between proposals targeting the same agent scope
    /// (spec default: 6). Currently advisory — full enforcement is a
    /// follow-up.
    min_hours_between_same_scope: Int,
    /// D' threshold above which a proposal is rejected. Inherits from
    /// comms gate defaults if unset (spec default: 0.50).
    reject_threshold: Float,
    /// D' threshold above which a proposal would be modified. Currently
    /// the gate has no modify path — anything above modify but below
    /// reject is accepted with the score logged for audit.
    modify_threshold: Float,
    /// When True, run the D' LLM scorer. When False, accept anything that
    /// passes the deterministic + rate-limit checks (used for tests, or
    /// when the operator wants to disable the LLM evaluation).
    enable_llm_scorer: Bool,
  )
}

pub fn default_config() -> GateConfig {
  GateConfig(
    max_proposals_per_day: 3,
    min_hours_between_same_scope: 6,
    reject_threshold: 0.5,
    modify_threshold: 0.3,
    enable_llm_scorer: True,
  )
}

// ---------------------------------------------------------------------------
// Outcome
// ---------------------------------------------------------------------------

pub type GateOutcome {
  GateOutcome(
    proposal_id: String,
    decision: dprime_types.GateDecision,
    score: Float,
    layer: String,
    reason: String,
    /// Path to the SKILL.md when decision is Accept; empty otherwise.
    skill_path: String,
  )
}

// ---------------------------------------------------------------------------
// Skill-specific features for the D' scorer
// ---------------------------------------------------------------------------

pub fn skill_features() -> List(dprime_types.Feature) {
  [
    dprime_types.Feature(
      name: "credential_exposure",
      importance: dprime_types.High,
      description: "Body contains credentials, API keys, bearer tokens, or private key material.",
      critical: True,
      feature_set: None,
      feature_set_importance: None,
      group: None,
      group_importance: None,
    ),
    dprime_types.Feature(
      name: "pii_exposure",
      importance: dprime_types.High,
      description: "Body contains personally identifiable information about real individuals.",
      critical: True,
      feature_set: None,
      feature_set_importance: None,
      group: None,
      group_importance: None,
    ),
    dprime_types.Feature(
      name: "internal_url_exposure",
      importance: dprime_types.Medium,
      description: "Body references internal hosts, localhost, .internal, .local, or private IP ranges.",
      critical: False,
      feature_set: None,
      feature_set_importance: None,
      group: None,
      group_importance: None,
    ),
    dprime_types.Feature(
      name: "system_internals",
      importance: dprime_types.Medium,
      description: "Body describes implementation internals, source code paths, or configuration secrets the agent shouldn't reveal.",
      critical: False,
      feature_set: None,
      feature_set_importance: None,
      group: None,
      group_importance: None,
    ),
    dprime_types.Feature(
      name: "character_violation",
      importance: dprime_types.High,
      description: "Body conflicts with the agent's highest endeavour or virtues as expressed in character.json.",
      critical: True,
      feature_set: None,
      feature_set_importance: None,
      group: None,
      group_importance: None,
    ),
  ]
}

// ---------------------------------------------------------------------------
// Deterministic pre-filter
// ---------------------------------------------------------------------------

const credential_patterns = [
  "(?i)(api[_-]?key|secret|bearer|token)\\s*[=:]\\s*[\\w\\-]{16,}",
  "-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----",
  "(?i)\\bAKIA[0-9A-Z]{16}\\b", "(?i)\\bsk-[a-zA-Z0-9]{32,}\\b",
]

const internal_url_patterns = [
  "(?i)\\blocalhost\\b", "\\b127\\.0\\.0\\.1\\b",
  "\\b10\\.\\d+\\.\\d+\\.\\d+\\b", "\\b192\\.168\\.\\d+\\.\\d+\\b",
  "\\.internal\\b", "\\.local\\b",
]

const path_patterns = ["/Users/[\\w.-]+/", "/home/[\\w.-]+/", "/etc/[\\w/.-]+"]

const env_var_patterns = ["\\$[A-Z][A-Z0-9_]+", "\\$\\{[A-Z][A-Z0-9_]+\\}"]

pub type DeterministicResult {
  DeterministicPass
  DeterministicBlock(rule: String, sample: String)
}

pub fn check_deterministic(body: String) -> DeterministicResult {
  let all_patterns =
    list.flatten([
      list.map(credential_patterns, fn(p) { #("credential", p) }),
      list.map(internal_url_patterns, fn(p) { #("internal_url", p) }),
      list.map(path_patterns, fn(p) { #("path", p) }),
      list.map(env_var_patterns, fn(p) { #("env_var", p) }),
    ])
  case
    list.find(all_patterns, fn(rule) {
      let #(_, pattern) = rule
      re_match_caseless(body, pattern)
    })
  {
    Error(_) -> DeterministicPass
    Ok(#(category, _pattern)) ->
      // Don't echo the matched substring (could itself be sensitive); the
      // operator can inspect the proposal log to see what tripped the rule.
      DeterministicBlock(rule: category, sample: "")
  }
}

// ---------------------------------------------------------------------------
// Rate limit
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

/// Count `created` events recorded today. The spec's rate window is 24h
/// rolling; for PR-D we use today's calendar window which is a close-enough
/// approximation and fits the daily-rotated log naturally.
pub fn promotions_today(skills_log_dir: String) -> Int {
  proposal_log.load_lines_for_date(skills_log_dir, get_date())
  |> list.filter(fn(line) { string.contains(line, "\"event\":\"created\"") })
  |> list.length
}

pub fn rate_limited(skills_log_dir: String, config: GateConfig) -> Bool {
  promotions_today(skills_log_dir) >= config.max_proposals_per_day
}

// ---------------------------------------------------------------------------
// D' scoring
// ---------------------------------------------------------------------------

fn build_scoring_prompt(proposal: SkillProposal) -> String {
  "Evaluate the safety of the following candidate skill body that would "
  <> "be injected into the system prompt of an autonomous agent. Score "
  <> "each feature 0-3 where 0=absent and 3=clear violation. Be strict — "
  <> "this content would become permanent prompt context for the agent.\n\n"
  <> "## Proposed skill\n\n"
  <> "Name: "
  <> proposal.name
  <> "\nAgents: "
  <> string.join(proposal.agents, ", ")
  <> "\n\n### Body\n\n"
  <> proposal.body
}

pub fn score_with_dprime(
  proposal: SkillProposal,
  provider: Provider,
  model: String,
) -> Float {
  let features = skill_features()
  let prompt = build_scoring_prompt(proposal)
  let forecasts =
    dprime_scorer.score_with_custom_prompt(
      prompt,
      features,
      provider,
      model,
      proposal.proposal_id,
      False,
    )
  // tiers=4 matches the default unified config tier count
  dprime_engine.compute_dprime(forecasts, features, 4)
}

// ---------------------------------------------------------------------------
// Promotion writes
// ---------------------------------------------------------------------------

/// Write SKILL.md + skill.toml for an Accepted proposal under
/// `<skills_dir>/<proposal_id>/`. Returns the SKILL.md path on success.
pub fn promote_to_disk(
  proposal: SkillProposal,
  skills_dir: String,
) -> Result(String, simplifile.FileError) {
  let dir = skills_dir <> "/" <> proposal.proposal_id
  let _ = simplifile.create_directory_all(dir)
  let md_path = dir <> "/SKILL.md"
  let toml_path = dir <> "/skill.toml"
  let md =
    "---\nname: "
    <> proposal.name
    <> "\ndescription: "
    <> proposal.description
    <> "\nagents: "
    <> string.join(proposal.agents, ", ")
    <> "\n---\n\n"
    <> proposal.body
  let toml =
    "id = \""
    <> proposal.proposal_id
    <> "\"\n"
    <> "name = \""
    <> proposal.name
    <> "\"\n"
    <> "description = \""
    <> escape_toml(proposal.description)
    <> "\"\n"
    <> "version = 1\n"
    <> "status = \"active\"\n\n"
    <> "[scoping]\n"
    <> "agents = ["
    <> toml_string_array(proposal.agents)
    <> "]\n"
    <> "contexts = ["
    <> toml_string_array(proposal.contexts)
    <> "]\n\n"
    <> "[provenance]\n"
    <> "author = \"agent\"\n"
    <> "agent_name = \""
    <> proposal.proposed_by
    <> "\"\n"
    <> "cycle_id = \"\"\n"
    <> "created_at = \""
    <> proposal.proposed_at
    <> "\"\n"
    <> "updated_at = \""
    <> proposal.proposed_at
    <> "\"\n"
    <> case proposal.source_cases {
      [] -> ""
      cases -> "derived_from = \"" <> string.join(cases, ",") <> "\"\n"
    }
  case simplifile.write(md_path, md) {
    Error(e) -> Error(e)
    Ok(_) ->
      case simplifile.write(toml_path, toml) {
        Error(e) -> Error(e)
        Ok(_) -> Ok(md_path)
      }
  }
}

fn escape_toml(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
}

fn toml_string_array(items: List(String)) -> String {
  items
  |> list.map(fn(s) { "\"" <> escape_toml(s) <> "\"" })
  |> string.join(", ")
}

// ---------------------------------------------------------------------------
// Top-level gate
// ---------------------------------------------------------------------------

/// Run the full gate pipeline on `proposal`. Logs the decision and writes
/// the SKILL.md on accept. Returns the GateOutcome for the caller's
/// summary.
pub fn gate_proposal(
  proposal: SkillProposal,
  _existing_skills: List(SkillMeta),
  skills_dir: String,
  log_dir: String,
  config: GateConfig,
  provider: Option(Provider),
  model: String,
) -> GateOutcome {
  // 1. Deterministic pre-filter
  case check_deterministic(proposal.body) {
    DeterministicBlock(rule:, sample: _) -> {
      let reason = "deterministic block (" <> rule <> ")"
      proposal_log.append_rejected(log_dir, proposal.proposal_id, reason)
      slog.info(
        "skills/safety_gate",
        "gate_proposal",
        "Rejected " <> proposal.proposal_id <> ": " <> reason,
        None,
      )
      GateOutcome(
        proposal_id: proposal.proposal_id,
        decision: dprime_types.Reject,
        score: 1.0,
        layer: "deterministic",
        reason: reason,
        skill_path: "",
      )
    }
    DeterministicPass -> {
      // 2. Rate limit
      case rate_limited(log_dir, config) {
        True -> {
          let reason =
            "rate limited ("
            <> int.to_string(promotions_today(log_dir))
            <> "/"
            <> int.to_string(config.max_proposals_per_day)
            <> " today)"
          proposal_log.append_rejected(log_dir, proposal.proposal_id, reason)
          slog.info(
            "skills/safety_gate",
            "gate_proposal",
            "Rejected " <> proposal.proposal_id <> ": " <> reason,
            None,
          )
          GateOutcome(
            proposal_id: proposal.proposal_id,
            decision: dprime_types.Reject,
            score: 0.0,
            layer: "rate_limit",
            reason: reason,
            skill_path: "",
          )
        }
        False -> {
          // 3. D' scorer (when enabled and a provider is wired in)
          let score = case config.enable_llm_scorer, provider {
            True, Some(p) -> score_with_dprime(proposal, p, model)
            _, _ -> 0.0
          }
          case score >=. config.reject_threshold {
            True -> {
              let reason =
                "D' score "
                <> float.to_string(score)
                <> " >= reject threshold "
                <> float.to_string(config.reject_threshold)
              proposal_log.append_rejected(
                log_dir,
                proposal.proposal_id,
                reason,
              )
              GateOutcome(
                proposal_id: proposal.proposal_id,
                decision: dprime_types.Reject,
                score: score,
                layer: "dprime",
                reason: reason,
                skill_path: "",
              )
            }
            False -> {
              // Accept — write to disk and log
              case promote_to_disk(proposal, skills_dir) {
                Error(e) -> {
                  let reason =
                    "promotion write failed: " <> simplifile.describe_error(e)
                  proposal_log.append_rejected(
                    log_dir,
                    proposal.proposal_id,
                    reason,
                  )
                  GateOutcome(
                    proposal_id: proposal.proposal_id,
                    decision: dprime_types.Reject,
                    score: score,
                    layer: "promotion",
                    reason: reason,
                    skill_path: "",
                  )
                }
                Ok(path) -> {
                  proposal_log.append_created(
                    log_dir,
                    proposal.proposal_id,
                    proposal.proposal_id,
                    path,
                  )
                  slog.info(
                    "skills/safety_gate",
                    "gate_proposal",
                    "Accepted " <> proposal.proposal_id <> " -> " <> path,
                    None,
                  )
                  GateOutcome(
                    proposal_id: proposal.proposal_id,
                    decision: dprime_types.Accept,
                    score: score,
                    layer: "accept",
                    reason: "passed all gates",
                    skill_path: path,
                  )
                }
              }
            }
          }
        }
      }
    }
  }
}
