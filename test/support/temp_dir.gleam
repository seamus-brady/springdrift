//// Test helper — create and clean up temporary directories.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/string
import simplifile

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_uuid() -> String

/// Create a fresh temporary directory under /tmp/springdrift_test/.
/// Returns the absolute path. Caller should call `cleanup` when done.
pub fn create() -> String {
  let id = string.slice(generate_uuid(), 0, 8)
  let path = "/tmp/springdrift_test/" <> id
  let assert Ok(_) = simplifile.create_directory_all(path)
  path
}

/// Remove a temporary directory and all its contents.
pub fn cleanup(path: String) -> Nil {
  let _ = simplifile.delete(path)
  Nil
}
