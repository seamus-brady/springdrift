//// Subprocess safety tests — verify run_cmd never interprets shell
//// metacharacters in its arguments.
////
//// Background: an earlier version of run_cmd built a shell command
//// via string-join and passed it to /bin/sh -c. Any argument containing
//// `;`, `&&`, `$()`, redirects, or backticks could break out of the
//// argv envelope and execute attacker-chosen commands. Severity is
//// high because the run_cmd surface is reachable from operator-tunable
//// inputs (paths, image names, sandbox commands).
////
//// These tests drive run_cmd against `printf` (POSIX, present on every
//// host that runs the agent) and assert that metacharacter-rich inputs
//// come back as literal output, never as a side effect of shell
//// interpretation.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/string
import gleeunit/should
import sandbox/podman_ffi as exec

// ---------------------------------------------------------------------------
// Argv literalness — shell metacharacters stay as data
// ---------------------------------------------------------------------------

pub fn semicolon_in_arg_does_not_chain_commands_test() {
  // If args were re-parsed by a shell, `; echo PWNED` would be a
  // second statement and the output would contain "PWNED". With
  // argv-only spawn, `; echo PWNED` is a single literal argument
  // printed verbatim by printf.
  let assert Ok(result) =
    exec.run_cmd("printf", ["%s", "hello; echo PWNED"], 5000)
  result.exit_code |> should.equal(0)
  result.stdout |> should.equal("hello; echo PWNED")
  result.stdout |> string.contains("PWNED\n") |> should.be_false
}

pub fn double_ampersand_does_not_chain_test() {
  let assert Ok(result) =
    exec.run_cmd("printf", ["%s", "first && touch /tmp/PWNED"], 5000)
  result.exit_code |> should.equal(0)
  result.stdout |> should.equal("first && touch /tmp/PWNED")
}

pub fn command_substitution_is_literal_test() {
  // $(id) would expand to the user id under shell interpretation.
  // Argv-safe: it stays as the four characters $(id).
  let assert Ok(result) =
    exec.run_cmd("printf", ["%s", "before $(id) after"], 5000)
  result.exit_code |> should.equal(0)
  result.stdout |> should.equal("before $(id) after")
  result.stdout |> string.contains("uid=") |> should.be_false
}

pub fn backticks_are_literal_test() {
  let assert Ok(result) = exec.run_cmd("printf", ["%s", "x`whoami`y"], 5000)
  result.exit_code |> should.equal(0)
  result.stdout |> should.equal("x`whoami`y")
  result.stdout |> string.contains("root") |> should.be_false
}

pub fn redirects_are_literal_test() {
  // `>` and `<` would redirect under a shell. Argv-safe: just data.
  let assert Ok(result) =
    exec.run_cmd("printf", ["%s", "data > /tmp/leak < /etc/passwd"], 5000)
  result.exit_code |> should.equal(0)
  result.stdout |> should.equal("data > /tmp/leak < /etc/passwd")
}

pub fn pipe_is_literal_test() {
  let assert Ok(result) =
    exec.run_cmd("printf", ["%s", "cat | grep secret"], 5000)
  result.exit_code |> should.equal(0)
  result.stdout |> should.equal("cat | grep secret")
}

pub fn spaces_are_one_argument_test() {
  // A space would split into multiple argv entries under a shell.
  // Argv-safe: stays one argument.
  let assert Ok(result) =
    exec.run_cmd("printf", ["%s", "one two three four"], 5000)
  result.exit_code |> should.equal(0)
  result.stdout |> should.equal("one two three four")
}

pub fn newlines_in_arg_preserved_test() {
  let assert Ok(result) = exec.run_cmd("printf", ["%s", "line1\nline2"], 5000)
  result.exit_code |> should.equal(0)
  result.stdout |> string.contains("line1\nline2") |> should.be_true
}

// ---------------------------------------------------------------------------
// Sad paths
// ---------------------------------------------------------------------------

pub fn missing_executable_returns_error_test() {
  // No shell to swallow the failure; the FFI tells us up front.
  case exec.run_cmd("definitely-not-a-real-binary-xyz", [], 5000) {
    Error(reason) -> reason |> string.contains("not found") |> should.be_true
    Ok(_) -> should.fail()
  }
}

pub fn nonzero_exit_is_reported_test() {
  // `false` always exits 1. Verifies we surface non-zero exit codes
  // cleanly (so callers can branch on result.exit_code) rather than
  // reporting an opaque error.
  let assert Ok(result) = exec.run_cmd("false", [], 5000)
  result.exit_code |> should.equal(1)
}
