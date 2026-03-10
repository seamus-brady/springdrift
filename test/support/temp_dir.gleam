//// Test helper — create and clean up temporary directories.

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
