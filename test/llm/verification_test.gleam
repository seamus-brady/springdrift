//// Pure helpers for the tool-result verification-evidence convention.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/string
import gleeunit/should
import llm/verification

// ---------------------------------------------------------------------------
// format
// ---------------------------------------------------------------------------

pub fn format_verified_has_canonical_prefix_test() {
  verification.format(verification.Verified(evidence: "exit=0"))
  |> should.equal("Verification: VERIFIED exit=0")
}

pub fn format_unverified_has_canonical_prefix_test() {
  verification.format(verification.Unverified(reason: "exit=1"))
  |> should.equal("Verification: UNVERIFIED exit=1")
}

pub fn format_not_applicable_returns_empty_test() {
  verification.format(verification.NotApplicable) |> should.equal("")
}

// ---------------------------------------------------------------------------
// append
// ---------------------------------------------------------------------------

pub fn append_not_applicable_is_identity_test() {
  verification.append("some content", verification.NotApplicable)
  |> should.equal("some content")
}

pub fn append_inserts_newline_between_content_and_line_test() {
  let out =
    verification.append("ran ok", verification.Verified(evidence: "exit=0"))
  out |> should.equal("ran ok\nVerification: VERIFIED exit=0")
}

pub fn append_to_empty_content_has_no_leading_newline_test() {
  verification.append("", verification.Unverified(reason: "exit=2"))
  |> should.equal("Verification: UNVERIFIED exit=2")
}

// ---------------------------------------------------------------------------
// from_exec
// ---------------------------------------------------------------------------

pub fn from_exec_zero_exit_clean_stderr_is_verified_test() {
  case verification.from_exec(0, "") {
    verification.Verified(evidence: e) -> e |> should.equal("exit=0")
    _ -> should.fail()
  }
}

pub fn from_exec_nonzero_exit_is_unverified_test() {
  case verification.from_exec(2, "") {
    verification.Unverified(reason: r) -> r |> should.equal("exit=2")
    _ -> should.fail()
  }
}

pub fn from_exec_stderr_on_zero_exit_is_still_unverified_test() {
  // A process can exit 0 but emit warnings/errors to stderr — treat
  // that as unverified so the agent has to judge the stderr content
  // rather than claiming success.
  case verification.from_exec(0, "warning: ignoring bad flag\n") {
    verification.Unverified(reason: r) -> {
      string.starts_with(r, "stderr:") |> should.equal(True)
      string.contains(r, "warning: ignoring bad flag") |> should.equal(True)
    }
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// from_probe_string
// ---------------------------------------------------------------------------

pub fn from_probe_string_verified_test() {
  case verification.from_probe_string("VERIFIED status=200 preview=hello") {
    verification.Verified(evidence: e) ->
      e |> should.equal("status=200 preview=hello")
    _ -> should.fail()
  }
}

pub fn from_probe_string_unverified_test() {
  case verification.from_probe_string("UNVERIFIED ConnectionRefusedError") {
    verification.Unverified(reason: r) ->
      r |> should.equal("ConnectionRefusedError")
    _ -> should.fail()
  }
}

pub fn from_probe_string_unrecognised_is_paranoid_unverified_test() {
  case verification.from_probe_string("something weird") {
    verification.Unverified(reason: r) -> r |> should.equal("something weird")
    _ -> should.fail()
  }
}
