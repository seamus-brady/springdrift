/// OTP actor managing a Docker sandbox container lifecycle.
///
/// Usage:
///   case sandbox.start("./sandbox", [3000, 8080]) {
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
  Shutdown
}

type SandboxState {
  SandboxState(container_id: String, ports: List(Int), dockerfile_dir: String)
}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "check_docker")
fn check_docker() -> Bool

@external(erlang, "springdrift_ffi", "docker_build")
fn docker_build(context_dir: String) -> Result(Nil, String)

@external(erlang, "springdrift_ffi", "docker_run_container")
fn docker_run_container(
  image: String,
  cwd: String,
  ports: List(Int),
) -> Result(String, String)

@external(erlang, "springdrift_ffi", "docker_exec")
fn docker_exec(container_id: String, cmd: String) -> Result(String, String)

@external(erlang, "springdrift_ffi", "docker_stop")
fn docker_stop(container_id: String) -> Nil

@external(erlang, "springdrift_ffi", "docker_logs")
fn docker_logs(container_id: String, lines: Int) -> Result(String, String)

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
          case docker_run_container("springdrift-sandbox:latest", cwd, ports) {
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
                  SandboxState(container_id:, ports:, dockerfile_dir:),
                )
              })
              case process.receive(setup, 5000) {
                Ok(subj) -> {
                  let ports_str =
                    string.join(list.map(ports, int.to_string), ",")
                  app_log.info("sandbox_started", [
                    #("container_id", container_id),
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
// Actor loop
// ---------------------------------------------------------------------------

fn sandbox_loop(self: Subject(SandboxMessage), state: SandboxState) -> Nil {
  case process.receive_forever(self) {
    RunCommand(cmd:, reply_to:) -> {
      let result = docker_exec(state.container_id, cmd)
      process.send(reply_to, result)
      sandbox_loop(self, state)
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
      let cwd = case simplifile.current_directory() {
        Ok(dir) -> dir
        Error(_) -> "."
      }
      case
        docker_run_container("springdrift-sandbox:latest", cwd, state.ports)
      {
        Error(reason) -> {
          let msg = "docker run failed: " <> reason
          app_log.err("sandbox_restart_failed", [#("reason", msg)])
          process.send(reply_to, Error(msg))
          sandbox_loop(self, state)
        }
        Ok(new_container_id) -> {
          app_log.info("sandbox_restarted", [
            #("container_id", new_container_id),
          ])
          process.send(reply_to, Ok(Nil))
          sandbox_loop(
            self,
            SandboxState(..state, container_id: new_container_id),
          )
        }
      }
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
