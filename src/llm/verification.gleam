//// Verification evidence as a string-level contract on tool content.
////
//// Plan B Lever 1. When a tool can judge whether its output confirms
//// the intended effect (not just that the process ran), it appends a
//// single `Verification:` line to its `ToolSuccess.content`. The
//// coder agent's honesty contract (Plan B L3) teaches it to read that
//// line and treat `UNVERIFIED` as "not done" rather than bluffing past.
////
//// Why a string convention instead of a structured field on
//// `ToolResult`? The LLM only ever consumes the content string.
//// Adding a structured field would cascade across ~150 construction
//// sites in exchange for information the LLM can't read directly. A
//// pure string helper is visible to the LLM, testable in isolation,
//// and leaves future metrics/CBR code free to parse the line back
//// out if it wants structure later.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/string

/// An Outcome is a judgement by the tool about what its own output
/// confirms:
///
///   - `Verified(evidence)` — the tool has positive evidence the
///     work succeeded. `evidence` is a short phrase (e.g. `exit=0`,
///     `status=200`) shown verbatim to the agent.
///   - `Unverified(reason)` — the tool ran to completion but could
///     NOT confirm the work succeeded. `reason` names the specific
///     thing that prevented verification (non-zero exit, stderr
///     present, probe refused connection).
///   - `NotApplicable` — the tool has no coherent notion of
///     verification beyond "it ran without raising". Used by pure
///     tools like `calculator`, `get_current_datetime`. No line
///     is appended; caller content is passed through.
///
/// Note: `Unverified` is distinct from a tool FAILING outright.
/// A failed tool returns `ToolFailure`. `Unverified` means the tool
/// returned a normal result but the evidence isn't strong enough to
/// support a completion claim.
pub type Outcome {
  Verified(evidence: String)
  Unverified(reason: String)
  NotApplicable
}

/// Render an Outcome to its canonical content-line form. Returns the
/// empty string for NotApplicable so callers can unconditionally
/// concatenate without worrying about trailing blank lines.
///
/// The format is stable and greppable:
///
///   Verification: VERIFIED <evidence>
///   Verification: UNVERIFIED <reason>
///
/// Keep the prefix stable if you change anything — existing agent
/// prompts and any future parsing code depend on it.
pub fn format(outcome: Outcome) -> String {
  case outcome {
    Verified(evidence:) -> "Verification: VERIFIED " <> evidence
    Unverified(reason:) -> "Verification: UNVERIFIED " <> reason
    NotApplicable -> ""
  }
}

/// Append an Outcome's rendered line to a content string. Inserts a
/// newline separator only when both sides are non-empty; avoids
/// producing a trailing newline for NotApplicable.
pub fn append(content: String, outcome: Outcome) -> String {
  case format(outcome) {
    "" -> content
    line ->
      case string.trim(content) {
        "" -> line
        _ -> content <> "\n" <> line
      }
  }
}

/// Derive an Outcome from the classic exit-code / stderr pair used by
/// run_code and sandbox_exec. Non-zero exit ⇒ Unverified; stderr with
/// content (even on exit 0) ⇒ Unverified with the first line of
/// stderr as the reason; otherwise Verified with `exit=0`.
pub fn from_exec(exit_code: Int, stderr: String) -> Outcome {
  case exit_code != 0, string.trim(stderr) {
    True, _ -> Unverified(reason: "exit=" <> int_to_string(exit_code))
    False, "" -> Verified(evidence: "exit=0")
    False, stderr_trimmed ->
      Unverified(reason: "stderr: " <> first_line_prefix(stderr_trimmed, 120))
  }
}

/// Derive an Outcome from the `verification` string the sandbox
/// manager attaches to `ServeResult`. The probe output has two
/// canonical prefixes:
///
///   VERIFIED status=<n> preview=<...>
///   UNVERIFIED <reason>
///
/// Anything else is treated as Unverified with the raw string as the
/// reason (paranoid default — better to mark Unverified than to claim
/// success on an unrecognised string).
pub fn from_probe_string(probe: String) -> Outcome {
  let trimmed = string.trim(probe)
  case string.starts_with(trimmed, "VERIFIED ") {
    True ->
      Verified(evidence: string.drop_start(trimmed, string.length("VERIFIED ")))
    False ->
      case string.starts_with(trimmed, "UNVERIFIED ") {
        True ->
          Unverified(reason: string.drop_start(
            trimmed,
            string.length("UNVERIFIED "),
          ))
        False -> Unverified(reason: trimmed)
      }
  }
}

// ---------------------------------------------------------------------------
// Internal helpers (keep the module free of gleam/int etc in the public API)
// ---------------------------------------------------------------------------

@external(erlang, "erlang", "integer_to_binary")
fn int_to_string(n: Int) -> String

fn first_line_prefix(s: String, limit: Int) -> String {
  let first_line = case string.split_once(s, "\n") {
    Ok(#(head, _rest)) -> head
    Error(_) -> s
  }
  case string.length(first_line) > limit {
    True -> string.slice(first_line, 0, limit) <> "…"
    False -> first_line
  }
}
