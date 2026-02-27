import gleam/erlang
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

@external(erlang, "springdrift_ffi", "tui_run")
fn tui_run(loop: fn() -> Nil, cleanup: fn() -> Nil) -> Nil

@external(erlang, "springdrift_ffi", "throw_tui_exit")
fn throw_tui_exit() -> Nil

// throw:tui_exit is a clean exit — tui_run returns normally.
pub fn tui_run_clean_exit_test() {
  let result =
    erlang.rescue(fn() {
      tui_run(fn() { throw_tui_exit() }, fn() { Nil })
    })
  result |> should.be_ok()
}

// Any other exception is re-raised so the caller sees an error.
pub fn tui_run_reraises_exception_test() {
  let result =
    erlang.rescue(fn() {
      tui_run(fn() { panic as "test crash" }, fn() { Nil })
    })
  result |> should.be_error()
}
