import agent/framework
import agent/types.{
  type AgentLifecycleEvent, type AgentSpec, type CognitiveMessage,
  type SupervisorMessage, AgentCrashed, AgentEvent, AgentRestartFailed,
  AgentRestarted, AgentStarted, AgentStopped, Permanent, ShutdownAll, StartChild,
  StopChild, Temporary, Transient,
}
import gleam/erlang/process.{type ExitMessage, type Pid, type Subject}
import gleam/list
import gleam/option.{None, Some}

// ---------------------------------------------------------------------------
// Internal types
// ---------------------------------------------------------------------------

type ChildEntry {
  ChildEntry(
    spec: AgentSpec,
    pid: Pid,
    task_subject: Subject(types.AgentTask),
    restart_count: Int,
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

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn start(
  cognitive: Subject(CognitiveMessage),
  max_restarts: Int,
) -> Subject(SupervisorMessage) {
  let setup = process.new_subject()
  process.spawn_unlinked(fn() {
    process.trap_exits(True)
    let self = process.new_subject()
    let state = SupervisorState(self:, cognitive:, children: [], max_restarts:)
    process.send(setup, self)
    supervisor_loop(state)
  })
  let assert Ok(subj) = process.receive(setup, 5000)
  subj
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
  case msg {
    StartChild(spec:, reply_to:) -> {
      case framework.start_agent(spec) {
        Ok(#(pid, task_subject)) -> {
          let entry = ChildEntry(spec:, pid:, task_subject:, restart_count: 0)
          let new_state =
            SupervisorState(
              ..state,
              children: list.append(state.children, [entry]),
            )
          notify(state.cognitive, AgentStarted(name: spec.name))
          process.send(reply_to, Ok(Nil))
          supervisor_loop(new_state)
        }
        Error(reason) -> {
          process.send(reply_to, Error(reason))
          supervisor_loop(state)
        }
      }
    }

    StopChild(name:) -> {
      let new_children =
        list.filter(state.children, fn(c) { c.spec.name != name })
      notify(state.cognitive, AgentStopped(name:))
      supervisor_loop(SupervisorState(..state, children: new_children))
    }

    ShutdownAll -> {
      list.each(state.children, fn(c) {
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
          notify(
            state.cognitive,
            AgentCrashed(name: child.spec.name, reason: reason_str),
          )
          let new_count = child.restart_count + 1
          case new_count > state.max_restarts {
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
                    AgentRestarted(name: child.spec.name, attempt: new_count),
                  )
                  let new_entry =
                    ChildEntry(
                      ..child,
                      pid:,
                      task_subject:,
                      restart_count: new_count,
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
