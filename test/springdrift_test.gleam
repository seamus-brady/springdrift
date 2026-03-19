import gleeunit

@external(erlang, "xstructor_ffi", "suppress_xmerl_logging")
fn suppress_xmerl_logging() -> a

pub fn main() -> Nil {
  // Suppress xmerl's noisy error_logger output during XML validation tests.
  // Invalid XML triggers "expected_element_start_tag" errors to stderr which
  // are expected in negative test cases but look alarming in test output.
  let _ = suppress_xmerl_logging()
  gleeunit.main()
}

// gleeunit test functions end in `_test`
pub fn hello_world_test() {
  let name = "Joe"
  let greeting = "Hello, " <> name <> "!"

  assert greeting == "Hello, Joe!"
}
