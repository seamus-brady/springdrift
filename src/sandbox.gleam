/// OTP actor managing a Docker sandbox container lifecycle.
///
/// Usage:
///   case sandbox.start("./sandbox") {
///     Ok(subj)  -> // send RunCommand, Shutdown
///     Error(msg) -> // Docker unavailable
///   }
import gleam/erlang/process.{type Subject}
import simplifile

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type SandboxMessage {
  RunCommand(cmd: String, reply_to: Subject(Result(String, String)))
  Shutdown
}

type SandboxState {
  SandboxState(container_id: String)
}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "check_docker")
fn check_docker() -> Bool

@external(erlang, "springdrift_ffi", "docker_build")
fn docker_build(context_dir: String) -> Result(Nil, String)

@external(erlang, "springdrift_ffi", "docker_run_container")
fn docker_run_container(image: String, cwd: String) -> Result(String, String)

@external(erlang, "springdrift_ffi", "docker_exec")
fn docker_exec(container_id: String, cmd: String) -> Result(String, String)

@external(erlang, "springdrift_ffi", "docker_stop")
fn docker_stop(container_id: String) -> Nil

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Try to start the Docker sandbox. Returns Error(reason) if Docker is
/// unavailable or the container fails to start.
pub fn start(dockerfile_dir: String) -> Result(Subject(SandboxMessage), String) {
  case check_docker() {
    False -> Error("Docker daemon not reachable")
    True -> {
      case docker_build(dockerfile_dir) {
        Error(reason) -> Error("docker build failed: " <> reason)
        Ok(_) -> {
          let cwd = case simplifile.current_directory() {
            Ok(dir) -> dir
            Error(_) -> "."
          }
          case docker_run_container("springdrift-sandbox:latest", cwd) {
            Error(reason) -> Error("docker run failed: " <> reason)
            Ok(container_id) -> {
              let setup = process.new_subject()
              process.spawn_unlinked(fn() {
                let self = process.new_subject()
                process.send(setup, self)
                sandbox_loop(self, SandboxState(container_id:))
              })
              case process.receive(setup, 5000) {
                Ok(subj) -> Ok(subj)
                Error(_) -> Error("sandbox actor failed to start")
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
    Shutdown -> {
      docker_stop(state.container_id)
      Nil
    }
  }
}
