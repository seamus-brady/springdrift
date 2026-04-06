//// Gleam-side FFI declarations for subprocess execution.
////
//// Delegates to springdrift_ffi.erl for actual process spawning.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import sandbox/types.{type ExecResult, ExecResult}

/// Run a command with arguments and a timeout. Returns ExecResult or error string.
pub fn run_cmd(
  cmd: String,
  args: List(String),
  timeout_ms: Int,
) -> Result(ExecResult, String) {
  case do_run_cmd(cmd, args, timeout_ms) {
    Ok(#(exit_code, stdout, stderr)) ->
      Ok(ExecResult(exit_code:, stdout:, stderr:))
    Error(reason) -> Error(reason)
  }
}

@external(erlang, "springdrift_ffi", "run_cmd")
fn do_run_cmd(
  cmd: String,
  args: List(String),
  timeout_ms: Int,
) -> Result(#(Int, String, String), String)

/// Check if a binary exists on PATH.
@external(erlang, "springdrift_ffi", "which")
pub fn which(name: String) -> Result(String, Nil)
