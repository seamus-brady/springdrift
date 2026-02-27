import gleam/erlang/process.{type Monitor}
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

@external(erlang, "springdrift_ffi", "tui_run")
fn tui_run(loop: fn() -> Nil, cleanup: fn() -> Nil) -> Nil

@external(erlang, "springdrift_ffi", "throw_tui_exit")
fn throw_tui_exit() -> Nil

type Crashed {
  Crashed
}

// throw:tui_exit is a clean exit — tui_run returns normally.
pub fn tui_run_clean_exit_test() {
  tui_run(fn() { throw_tui_exit() }, fn() { Nil })
}

// Any other exception is re-raised so the process terminates.
pub fn tui_run_reraises_exception_test() {
  let child_pid =
    process.spawn_unlinked(fn() {
      tui_run(fn() { panic as "test crash" }, fn() { Nil })
    })
  let mon: Monitor = process.monitor(child_pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(mon, fn(_) { Crashed })
  case process.selector_receive(selector, 2000) {
    Ok(Crashed) -> Nil
    Error(Nil) -> should.fail()
  }
}
