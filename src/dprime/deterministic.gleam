//// Deterministic pre-filter for D' safety gates.
//// Pure-function module — no external calls at evaluation time.
//// Runs regex-based rules against input/tool/output text and returns
//// Block, Escalate, or Pass decisions without any LLM calls.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import slog

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

/// Case-insensitive regex match. Returns True if pattern matches anywhere
/// in text, False otherwise. Returns False on invalid patterns (fail-open).
@external(erlang, "springdrift_ffi", "re_match_caseless")
fn re_match_caseless(text: String, pattern: String) -> Bool

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// A single deterministic rule with a regex pattern and an action.
pub type DeterministicRule {
  DeterministicRule(id: String, pattern: String, action: RuleAction)
}

/// What to do when a rule matches.
pub type RuleAction {
  BlockAction
  EscalateAction
}

/// Result of a deterministic check.
pub type DeterministicResult {
  Pass
  Blocked(rule_id: String, reason: String)
  Escalated(rule_id: String, context: String)
}

/// Configuration for deterministic pre-filtering.
pub type DeterministicConfig {
  DeterministicConfig(
    enabled: Bool,
    input_rules: List(DeterministicRule),
    tool_rules: List(DeterministicRule),
    output_rules: List(DeterministicRule),
    path_allowlist: List(String),
    domain_allowlist: List(String),
  )
}

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

/// Default config: enabled with empty rules (no filtering).
pub fn default_config() -> DeterministicConfig {
  DeterministicConfig(
    enabled: True,
    input_rules: [],
    tool_rules: [],
    output_rules: [],
    path_allowlist: [],
    domain_allowlist: [],
  )
}

// ---------------------------------------------------------------------------
// Public check functions
// ---------------------------------------------------------------------------

/// Check user/scheduler input text against input rules.
pub fn check_input(
  text: String,
  config: DeterministicConfig,
) -> DeterministicResult {
  case config.enabled {
    False -> Pass
    True -> check_rules(text, config.input_rules)
  }
}

/// Check a tool call against tool rules, path allowlist, and domain allowlist.
pub fn check_tool(
  tool_name: String,
  tool_input: String,
  config: DeterministicConfig,
) -> DeterministicResult {
  case config.enabled {
    False -> Pass
    True -> {
      let combined = tool_name <> " " <> tool_input
      case check_rules(combined, config.tool_rules) {
        Pass ->
          case check_path_allowlist(tool_input, config.path_allowlist) {
            Pass -> check_domain_allowlist(tool_input, config.domain_allowlist)
            other -> other
          }
        other -> other
      }
    }
  }
}

/// Check output text against output rules.
pub fn check_output(
  text: String,
  config: DeterministicConfig,
) -> DeterministicResult {
  case config.enabled {
    False -> Pass
    True -> check_rules(text, config.output_rules)
  }
}

// ---------------------------------------------------------------------------
// Internal: rule matching
// ---------------------------------------------------------------------------

/// Run a list of rules against text. Returns first Block, then first Escalate,
/// or Pass if nothing matches. Invalid regex patterns are skipped with a warning.
fn check_rules(
  text: String,
  rules: List(DeterministicRule),
) -> DeterministicResult {
  do_check_rules(text, rules, None)
}

fn do_check_rules(
  text: String,
  rules: List(DeterministicRule),
  first_escalate: Option(DeterministicResult),
) -> DeterministicResult {
  case rules {
    [] ->
      case first_escalate {
        Some(esc) -> esc
        None -> Pass
      }
    [rule, ..rest] -> {
      case is_valid_regex(rule.pattern) {
        False -> {
          slog.warn(
            "dprime/deterministic",
            "check_rules",
            "Skipping rule '"
              <> rule.id
              <> "' with invalid regex: "
              <> rule.pattern,
            None,
          )
          do_check_rules(text, rest, first_escalate)
        }
        True -> {
          case re_match_caseless(text, rule.pattern) {
            False -> do_check_rules(text, rest, first_escalate)
            True ->
              case rule.action {
                BlockAction ->
                  Blocked(
                    rule_id: rule.id,
                    reason: "Matched deterministic rule: " <> rule.id,
                  )
                EscalateAction -> {
                  let esc = case first_escalate {
                    Some(_) -> first_escalate
                    None ->
                      Some(Escalated(
                        rule_id: rule.id,
                        context: "Matched deterministic rule: " <> rule.id,
                      ))
                  }
                  do_check_rules(text, rest, esc)
                }
              }
          }
        }
      }
    }
  }
}

/// Check if a regex pattern is valid by attempting compilation via FFI.
/// We use a simple heuristic: try matching against empty string.
/// If the pattern is invalid, re_match_caseless returns False, but we
/// need to distinguish invalid from "doesn't match empty". So we use
/// a dedicated check.
fn is_valid_regex(pattern: String) -> Bool {
  // Try to match against a canary string that should never cause issues.
  // If the pattern is invalid, the FFI returns false regardless.
  // We need a real validity check — call the FFI and also test with a
  // string that most patterns won't match. The FFI itself returns false
  // for invalid patterns, which is indistinguishable from "no match".
  // Since we're fail-open, we just try the match and if the pattern
  // is bad, it won't match anything (safe). But we want to warn.
  // Use a separate FFI call to actually check validity.
  do_is_valid_regex(pattern)
}

@external(erlang, "springdrift_ffi", "re_is_valid_pattern")
fn do_is_valid_regex(pattern: String) -> Bool

// ---------------------------------------------------------------------------
// Internal: path allowlist
// ---------------------------------------------------------------------------

/// If allowlist is non-empty and tool_input contains path-like strings
/// outside allowed directories, escalate. Empty allowlist = no filtering.
fn check_path_allowlist(
  tool_input: String,
  allowlist: List(String),
) -> DeterministicResult {
  case allowlist {
    [] -> Pass
    _ -> {
      let paths = extract_paths(tool_input)
      case paths {
        [] -> Pass
        _ -> check_paths_against_allowlist(paths, allowlist)
      }
    }
  }
}

/// Extract path-like strings from text. A path starts with / or ./ or ../
fn extract_paths(text: String) -> List(String) {
  text
  |> string.split(" ")
  |> list.flat_map(fn(word) {
    let trimmed = string.trim(word)
    case trimmed {
      "/" <> _ -> [trimmed]
      "./" <> _ -> [trimmed]
      "../" <> _ -> [trimmed]
      _ -> []
    }
  })
}

/// Check each extracted path against the allowlist. All paths must be
/// under at least one allowed prefix; otherwise escalate.
fn check_paths_against_allowlist(
  paths: List(String),
  allowlist: List(String),
) -> DeterministicResult {
  case paths {
    [] -> Pass
    [path, ..rest] -> {
      let allowed =
        list.any(allowlist, fn(prefix) { is_path_under(path, prefix) })
      case allowed {
        True -> check_paths_against_allowlist(rest, allowlist)
        False ->
          Escalated(
            rule_id: "path_allowlist",
            context: "Path outside allowlist: " <> path,
          )
      }
    }
  }
}

/// Check if a path is under a given prefix directory.
fn is_path_under(path: String, prefix: String) -> Bool {
  // Normalize: ensure prefix ends with /
  let norm_prefix = case string.ends_with(prefix, "/") {
    True -> prefix
    False -> prefix <> "/"
  }
  string.starts_with(path, norm_prefix) || path == prefix
}

// ---------------------------------------------------------------------------
// Internal: domain allowlist
// ---------------------------------------------------------------------------

/// If allowlist is non-empty and tool_input contains URLs with domains not
/// in the allowlist, escalate. Empty allowlist = no filtering.
fn check_domain_allowlist(
  tool_input: String,
  allowlist: List(String),
) -> DeterministicResult {
  case allowlist {
    [] -> Pass
    _ -> {
      let domains = extract_domains(tool_input)
      case domains {
        [] -> Pass
        _ -> check_domains_against_allowlist(domains, allowlist)
      }
    }
  }
}

/// Extract domains from URLs in text (http:// or https://).
fn extract_domains(text: String) -> List(String) {
  text
  |> string.split(" ")
  |> list.filter_map(fn(word) {
    let trimmed = string.trim(word)
    case string.split_once(trimmed, "://") {
      Ok(#(scheme, rest)) ->
        case scheme {
          "http" | "https" -> {
            // Extract domain (up to first / or end)
            let domain = case string.split_once(rest, "/") {
              Ok(#(d, _)) -> d
              Error(_) -> rest
            }
            // Strip port if present
            let domain_no_port = case string.split_once(domain, ":") {
              Ok(#(d, _)) -> d
              Error(_) -> domain
            }
            Ok(domain_no_port)
          }
          _ -> Error(Nil)
        }
      Error(_) -> Error(Nil)
    }
  })
}

/// Check extracted domains against the allowlist.
fn check_domains_against_allowlist(
  domains: List(String),
  allowlist: List(String),
) -> DeterministicResult {
  case domains {
    [] -> Pass
    [domain, ..rest] -> {
      let allowed =
        list.any(allowlist, fn(allowed_domain) {
          domain == allowed_domain
          || string.ends_with(domain, "." <> allowed_domain)
        })
      case allowed {
        True -> check_domains_against_allowlist(rest, allowlist)
        False ->
          Escalated(
            rule_id: "domain_allowlist",
            context: "Domain outside allowlist: " <> domain,
          )
      }
    }
  }
}
