/// OTP actor managing a Docker sandbox container lifecycle.
///
/// Usage:
///   case sandbox.start("./sandbox", [10001, 10002, 10003, 10004]) {
///     Ok(subj)   -> // send RunCommand, GetStatus, GetLogs, Restart, Shutdown
///     Error(msg) -> // Docker unavailable
///   }
import app_log
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import simplifile

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type SandboxStatus {
  SandboxRunning(container_id: String, ports: List(Int))
}

pub type SandboxMessage {
  RunCommand(cmd: String, reply_to: Subject(Result(String, String)))
  GetStatus(reply_to: Subject(SandboxStatus))
  GetLogs(lines: Int, reply_to: Subject(Result(String, String)))
  Restart(reply_to: Subject(Result(Nil, String)))
  CopyFromSandbox(
    container_path: String,
    reply_to: Subject(Result(String, String)),
  )
  CopyToSandbox(
    host_path: String,
    container_dest: String,
    reply_to: Subject(Result(Nil, String)),
  )
  Shutdown
}

type SandboxState {
  SandboxState(
    container_id: String,
    project_name: String,
    ports: List(Int),
    dockerfile_dir: String,
  )
}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "check_docker")
fn check_docker() -> Bool

@external(erlang, "springdrift_ffi", "docker_build")
fn docker_build(context_dir: String) -> Result(Nil, String)

@external(erlang, "springdrift_ffi", "project_container_name")
fn project_container_name(cwd: String) -> String

@external(erlang, "springdrift_ffi", "docker_run_container")
fn docker_run_container(
  image: String,
  name: String,
  cwd: String,
  ports: List(Int),
) -> Result(String, String)

@external(erlang, "springdrift_ffi", "docker_exec")
fn docker_exec(container_id: String, cmd: String) -> Result(String, String)

@external(erlang, "springdrift_ffi", "docker_stop")
fn docker_stop(container_id: String) -> Nil

@external(erlang, "springdrift_ffi", "docker_logs")
fn docker_logs(container_id: String, lines: Int) -> Result(String, String)

@external(erlang, "springdrift_ffi", "docker_cp")
fn docker_cp(src: String, dst: String) -> Result(Nil, String)

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Try to start the Docker sandbox. Prints progress to stdout.
/// Returns Error(reason) if Docker is unavailable or the container fails.
pub fn start(
  dockerfile_dir: String,
  ports: List(Int),
) -> Result(Subject(SandboxMessage), String) {
  case check_docker() {
    False -> Error("Docker daemon not reachable")
    True -> {
      io.println("  Building sandbox image...")
      case docker_build(dockerfile_dir) {
        Error(reason) -> {
          let msg = "docker build failed: " <> reason
          app_log.err("sandbox_start_failed", [#("reason", msg)])
          Error(msg)
        }
        Ok(_) -> {
          io.println("  Starting container...")
          let cwd = case simplifile.current_directory() {
            Ok(dir) -> dir
            Error(_) -> "."
          }
          let project_name = project_container_name(cwd)
          cleanup_old_container(project_name)
          case
            docker_run_container(
              "springdrift-sandbox:latest",
              project_name,
              cwd,
              ports,
            )
          {
            Error(reason) -> {
              let msg = "docker run failed: " <> reason
              app_log.err("sandbox_start_failed", [#("reason", msg)])
              Error(msg)
            }
            Ok(container_id) -> {
              let setup = process.new_subject()
              process.spawn_unlinked(fn() {
                let self = process.new_subject()
                process.send(setup, self)
                sandbox_loop(
                  self,
                  SandboxState(
                    container_id:,
                    project_name:,
                    ports:,
                    dockerfile_dir:,
                  ),
                )
              })
              case process.receive(setup, 5000) {
                Ok(subj) -> {
                  let ports_str =
                    string.join(list.map(ports, int.to_string), ",")
                  app_log.info("sandbox_started", [
                    #("container_id", container_id),
                    #("container_name", project_name),
                    #("ports", ports_str),
                  ])
                  Ok(subj)
                }
                Error(_) -> {
                  app_log.err("sandbox_start_failed", [
                    #("reason", "sandbox actor failed to start"),
                  ])
                  Error("sandbox actor failed to start")
                }
              }
            }
          }
        }
      }
    }
  }
}

/// Send a Shutdown message to the sandbox actor (non-blocking).
pub fn send_shutdown(subj: Subject(SandboxMessage)) -> Nil {
  process.send(subj, Shutdown)
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Stop and remove a container by name (silent if it doesn't exist).
/// Used on startup to clean up any leftover container from a previous run.
fn cleanup_old_container(name: String) -> Nil {
  app_log.info("sandbox_cleanup_attempt", [#("container_name", name)])
  docker_stop(name)
  app_log.info("sandbox_cleanup_done", [#("container_name", name)])
}

/// Returns True when a docker_exec error indicates the container is no longer
/// running (stopped, removed, or never existed). These errors warrant an
/// auto-restart attempt rather than surfacing raw Docker output to the user.
fn is_container_gone(reason: String) -> Bool {
  string.contains(reason, "No such container")
  || string.contains(reason, "is not running")
  || string.contains(reason, "container not found")
  || string.contains(reason, "Cannot connect to the Docker daemon")
}

/// Attempt to restart the container using the stored project name and ports.
/// Returns a SandboxState with the new container_id on success, or the
/// original state (unchanged container_id) on failure.
fn attempt_auto_restart(state: SandboxState) -> SandboxState {
  let cwd = case simplifile.current_directory() {
    Ok(dir) -> dir
    Error(_) -> "."
  }
  case
    docker_run_container(
      "springdrift-sandbox:latest",
      state.project_name,
      cwd,
      state.ports,
    )
  {
    Error(reason) -> {
      app_log.err("sandbox_auto_restart_failed", [#("reason", reason)])
      state
    }
    Ok(new_id) -> {
      app_log.info("sandbox_auto_restarted", [
        #("container_id", new_id),
        #("container_name", state.project_name),
      ])
      SandboxState(..state, container_id: new_id)
    }
  }
}

// ---------------------------------------------------------------------------
// Actor loop
// ---------------------------------------------------------------------------

fn sandbox_loop(self: Subject(SandboxMessage), state: SandboxState) -> Nil {
  case process.receive_forever(self) {
    RunCommand(cmd:, reply_to:) -> {
      case docker_exec(state.container_id, cmd) {
        Ok(output) -> {
          process.send(reply_to, Ok(output))
          sandbox_loop(self, state)
        }
        Error(reason) -> {
          case is_container_gone(reason) {
            False -> {
              process.send(reply_to, Error(reason))
              sandbox_loop(self, state)
            }
            True -> {
              app_log.warn("sandbox_container_gone", [#("reason", reason)])
              let new_state = attempt_auto_restart(state)
              case new_state.container_id == state.container_id {
                True -> {
                  // Restart failed — return descriptive error
                  process.send(
                    reply_to,
                    Error(
                      "Sandbox container stopped. Use restart_sandbox to restart it.",
                    ),
                  )
                  sandbox_loop(self, new_state)
                }
                False -> {
                  // Restart succeeded — retry command once
                  let retry = docker_exec(new_state.container_id, cmd)
                  process.send(reply_to, retry)
                  sandbox_loop(self, new_state)
                }
              }
            }
          }
        }
      }
    }
    GetStatus(reply_to:) -> {
      process.send(
        reply_to,
        SandboxRunning(container_id: state.container_id, ports: state.ports),
      )
      sandbox_loop(self, state)
    }
    GetLogs(lines:, reply_to:) -> {
      let result = docker_logs(state.container_id, lines)
      process.send(reply_to, result)
      sandbox_loop(self, state)
    }
    Restart(reply_to:) -> {
      docker_stop(state.container_id)
      let new_state = attempt_auto_restart(state)
      case new_state.container_id == state.container_id {
        True ->
          process.send(
            reply_to,
            Error("Restart failed — check springdrift.log for details"),
          )
        False -> process.send(reply_to, Ok(Nil))
      }
      sandbox_loop(self, new_state)
    }
    CopyFromSandbox(container_path:, reply_to:) -> {
      let short_id = string.slice(state.container_id, 0, 12)
      let out_dir = "sandbox-out/" <> short_id
      let basename = case string.split(container_path, "/") {
        [] -> "file"
        parts -> {
          let assert Ok(last) = list.last(parts)
          case last {
            "" -> "file"
            name -> name
          }
        }
      }
      let host_dest = out_dir <> "/" <> basename
      let result = case simplifile.create_directory_all(out_dir) {
        Error(_) -> Error("Failed to create output directory: " <> out_dir)
        Ok(_) -> {
          let src = state.container_id <> ":" <> container_path
          case docker_cp(src, host_dest) {
            Ok(_) -> Ok("Copied to " <> host_dest)
            Error(msg) -> Error(msg)
          }
        }
      }
      process.send(reply_to, result)
      sandbox_loop(self, state)
    }
    CopyToSandbox(host_path:, container_dest:, reply_to:) -> {
      let dst = state.container_id <> ":" <> container_dest
      let result = docker_cp(host_path, dst)
      process.send(reply_to, result)
      sandbox_loop(self, state)
    }
    Shutdown -> {
      app_log.info("sandbox_shutdown", [
        #("container_id", state.container_id),
      ])
      docker_stop(state.container_id)
      Nil
    }
  }
}
