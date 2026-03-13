import agent/framework
import agent/types.{
  type AgentLifecycleEvent, type AgentSpec, type CognitiveMessage,
  type SupervisorMessage, AgentCrashed, AgentEvent, AgentRestartFailed,
  AgentRestarted, AgentStarted, AgentStopped, Permanent, ShutdownAll, StartChild,
  StopChild, Temporary, Transient,
}
import gleam/erlang/process.{type ExitMessage, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import slog

@external(erlang, "springdrift_ffi", "monotonic_now_ms")
fn monotonic_now_ms() -> Int

// ---------------------------------------------------------------------------
// Internal types
// ---------------------------------------------------------------------------

type ChildEntry {
  ChildEntry(
    spec: AgentSpec,
    pid: Pid,
    task_subject: Subject(types.AgentTask),
    restart_timestamps: List(Int),
  )
}

type SupervisorState {
  SupervisorState(
    self: Subject(SupervisorMessage),
    cognitive: Subject(CognitiveMessage),
    children: List(ChildEntry),
    max_restarts: Int,
  )
}

type SupervisorEvent {
  External(SupervisorMessage)
  ChildExited(ExitMessage)
}

/// Sliding restart window duration in milliseconds (60 seconds).
const restart_window_ms = 60_000

/// Count restarts within the sliding window, pruning old entries.
fn restarts_in_window(timestamps: List(Int), now: Int) -> #(Int, List(Int)) {
  let cutoff = now - restart_window_ms
  let recent = list.filter(timestamps, fn(ts) { ts >= cutoff })
  #(list.length(recent), recent)
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn start(
  cognitive: Subject(CognitiveMessage),
  max_restarts: Int,
) -> Result(Subject(SupervisorMessage), Nil) {
  slog.info("supervisor", "start", "Starting supervisor", None)
  let setup = process.new_subject()
  process.spawn_unlinked(fn() {
    process.trap_exits(True)
    let self = process.new_subject()
    let state = SupervisorState(self:, cognitive:, children: [], max_restarts:)
    process.send(setup, self)
    supervisor_loop(state)
  })
  case process.receive(setup, 5000) {
    Ok(subj) -> Ok(subj)
    Error(_) -> {
      slog.log_error(
        "supervisor",
        "start",
        "Supervisor failed to start within 5s",
        None,
      )
      Error(Nil)
    }
  }
}

// ---------------------------------------------------------------------------
// Internal loop
// ---------------------------------------------------------------------------

fn supervisor_loop(state: SupervisorState) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(state.self, External)
    |> process.select_trapped_exits(ChildExited)

  case process.selector_receive_forever(selector) {
    External(msg) -> handle_external(state, msg)
    ChildExited(exit_msg) -> handle_child_exit(state, exit_msg)
  }
}

fn handle_external(state: SupervisorState, msg: SupervisorMessage) -> Nil {
  slog.debug(
    "supervisor",
    "handle_external",
    case msg {
      StartChild(spec:, ..) -> "StartChild: " <> spec.name
      StopChild(name:) -> "StopChild: " <> name
      ShutdownAll -> "ShutdownAll"
    },
    None,
  )
  case msg {
    StartChild(spec:, reply_to:) -> {
      case framework.start_agent(spec) {
        Ok(#(pid, task_subject)) -> {
          let entry =
            ChildEntry(spec:, pid:, task_subject:, restart_timestamps: [])
          let new_state =
            SupervisorState(
              ..state,
              children: list.append(state.children, [entry]),
            )
          notify(state.cognitive, AgentStarted(name: spec.name, task_subject:))
          process.send(reply_to, Ok(task_subject))
          supervisor_loop(new_state)
        }
        Error(reason) -> {
          process.send(reply_to, Error(reason))
          supervisor_loop(state)
        }
      }
    }

    StopChild(name:) -> {
      // Kill the agent process before removing from children
      list.each(state.children, fn(c) {
        case c.spec.name == name {
          True -> process.kill(c.pid)
          False -> Nil
        }
      })
      let new_children =
        list.filter(state.children, fn(c) { c.spec.name != name })
      notify(state.cognitive, AgentStopped(name:))
      supervisor_loop(SupervisorState(..state, children: new_children))
    }

    ShutdownAll -> {
      list.each(state.children, fn(c) {
        process.kill(c.pid)
        notify(state.cognitive, AgentStopped(name: c.spec.name))
      })
      Nil
    }
  }
}

fn handle_child_exit(state: SupervisorState, exit_msg: ExitMessage) -> Nil {
  case find_child_by_pid(state.children, exit_msg.pid) {
    None -> supervisor_loop(state)
    Some(child) -> {
      let reason_str = case exit_msg.reason {
        process.Normal -> "normal"
        process.Killed -> "killed"
        process.Abnormal(_) -> "abnormal"
      }

      let should_restart = case child.spec.restart, exit_msg.reason {
        Permanent, _ -> True
        Transient, process.Normal -> False
        Transient, _ -> True
        Temporary, _ -> False
      }

      case should_restart {
        False -> {
          notify(state.cognitive, AgentStopped(name: child.spec.name))
          let new_children =
            list.filter(state.children, fn(c) { c.spec.name != child.spec.name })
          supervisor_loop(SupervisorState(..state, children: new_children))
        }

        True -> {
          let now = monotonic_now_ms()
          let #(recent_count, recent_timestamps) =
            restarts_in_window(child.restart_timestamps, now)
          slog.info(
            "supervisor",
            "restart_child",
            "Restarting "
              <> child.spec.name
              <> " ("
              <> int.to_string(recent_count + 1)
              <> " in window)",
            None,
          )
          notify(
            state.cognitive,
            AgentCrashed(name: child.spec.name, reason: reason_str),
          )
          case recent_count + 1 > state.max_restarts {
            True -> {
              notify(
                state.cognitive,
                AgentRestartFailed(
                  name: child.spec.name,
                  reason: "max restarts exceeded",
                ),
              )
              let new_children =
                list.filter(state.children, fn(c) {
                  c.spec.name != child.spec.name
                })
              supervisor_loop(SupervisorState(..state, children: new_children))
            }
            False -> {
              case framework.start_agent(child.spec) {
                Ok(#(pid, task_subject)) -> {
                  notify(
                    state.cognitive,
                    AgentRestarted(
                      name: child.spec.name,
                      attempt: recent_count + 1,
                      task_subject:,
                    ),
                  )
                  let new_entry =
                    ChildEntry(
                      ..child,
                      pid:,
                      task_subject:,
                      restart_timestamps: [now, ..recent_timestamps],
                    )
                  let new_children =
                    list.map(state.children, fn(c) {
                      case c.spec.name == child.spec.name {
                        True -> new_entry
                        False -> c
                      }
                    })
                  supervisor_loop(
                    SupervisorState(..state, children: new_children),
                  )
                }
                Error(reason) -> {
                  notify(
                    state.cognitive,
                    AgentRestartFailed(name: child.spec.name, reason:),
                  )
                  let new_children =
                    list.filter(state.children, fn(c) {
                      c.spec.name != child.spec.name
                    })
                  supervisor_loop(
                    SupervisorState(..state, children: new_children),
                  )
                }
              }
            }
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn find_child_by_pid(
  children: List(ChildEntry),
  pid: Pid,
) -> option.Option(ChildEntry) {
  case list.find(children, fn(c) { c.pid == pid }) {
    Ok(child) -> Some(child)
    Error(_) -> None
  }
}

fn notify(
  cognitive: Subject(CognitiveMessage),
  event: AgentLifecycleEvent,
) -> Nil {
  process.send(cognitive, AgentEvent(event:))
}
