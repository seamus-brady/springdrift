//// Sandbox manager — OTP actor managing a pool of Podman containers.
////
//// Follows the scheduler/runner.gleam pattern: starts containers at init,
//// dispatches Execute/Serve messages, health-checks periodically.

import agent/types as agent_types
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import sandbox/diagnostics
import sandbox/podman_ffi
import sandbox/types.{
  type SandboxConfig, type SandboxManager, type SandboxMessage, type SandboxSlot,
  SandboxManager, SandboxSlot,
}
import simplifile
import slog

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

type ManagerState {
  ManagerState(
    config: SandboxConfig,
    slots: Dict(Int, SandboxSlot),
    self: Subject(SandboxMessage),
    notify: Subject(agent_types.Notification),
    cognitive: Option(Subject(agent_types.CognitiveMessage)),
  )
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start the sandbox manager. Verifies podman, starts containers, returns handle.
pub fn start(
  config: SandboxConfig,
  notify: Subject(agent_types.Notification),
  cognitive: Option(Subject(agent_types.CognitiveMessage)),
) -> Result(SandboxManager, String) {
  // Pre-flight checks
  case diagnostics.check_podman() {
    Error(msg) -> Error(msg)
    Ok(version) -> {
      slog.info("sandbox", "start", "Podman: " <> version, None)

      // Check/start machine on macOS if configured
      case config.auto_machine {
        True ->
          case diagnostics.check_machine_status() {
            Ok(_) -> Nil
            Error(_) -> {
              slog.info("sandbox", "start", "Starting podman machine...", None)
              case diagnostics.start_machine() {
                Ok(_) -> Nil
                Error(msg) -> {
                  slog.warn(
                    "sandbox",
                    "start",
                    "Machine start failed: " <> msg,
                    None,
                  )
                  Nil
                }
              }
            }
          }
        False -> Nil
      }

      // Ensure image exists
      case diagnostics.check_image(config.image) {
        Ok(_) -> Nil
        Error(_) -> {
          slog.info("sandbox", "start", "Pulling image: " <> config.image, None)
          case diagnostics.pull_image(config.image, 300_000) {
            Ok(_) -> Nil
            Error(msg) -> {
              slog.warn("sandbox", "start", "Image pull failed: " <> msg, None)
              Nil
            }
          }
        }
      }

      // Sweep stale containers
      let swept = diagnostics.sweep_stale_containers()
      case swept > 0 {
        True ->
          slog.info(
            "sandbox",
            "start",
            "Swept " <> int.to_string(swept) <> " stale containers",
            None,
          )
        False -> Nil
      }

      // Create workspace directories — resolve to absolute path for podman bind mounts.
      // Relative paths resolve inside the podman machine VM, not on the host.
      let abs_workspace_dir = case
        string.starts_with(config.workspace_dir, "/")
      {
        True -> config.workspace_dir
        False ->
          case simplifile.current_directory() {
            Ok(cwd) -> cwd <> "/" <> config.workspace_dir
            Error(_) -> config.workspace_dir
          }
      }
      let abs_config =
        types.SandboxConfig(..config, workspace_dir: abs_workspace_dir)
      let _ = simplifile.create_directory_all(abs_workspace_dir)

      // Create containers (synchronous, before spawning the actor)
      let slots = create_containers(abs_config)

      let running_count =
        dict.values(slots)
        |> list.filter(fn(s) {
          case s.status {
            types.Ready -> True
            _ -> False
          }
        })
        |> list.length

      case running_count {
        0 -> {
          // Surface the first failure reason
          let reason =
            dict.values(slots)
            |> list.find_map(fn(s) {
              case s.status {
                types.Failed(reason:) -> Ok(reason)
                _ -> Error(Nil)
              }
            })
            |> option.from_result
            |> option.unwrap("unknown error")
          Error(
            "Failed to start any sandbox containers: "
            <> string.slice(reason, 0, 200),
          )
        }
        _ -> {
          // Use setup pattern: spawn actor, receive the subject back
          let setup = process.new_subject()
          process.spawn_unlinked(fn() {
            let self: Subject(SandboxMessage) = process.new_subject()
            process.send(setup, self)

            let state =
              ManagerState(
                config: abs_config,
                slots:,
                self:,
                notify:,
                cognitive:,
              )

            // Schedule first health check
            let _ = process.send_after(self, 30_000, types.HealthCheck)

            message_loop(state)
          })

          // Wait for the actor to send back its subject
          case process.receive(setup, 5000) {
            Error(_) -> Error("Sandbox actor startup timeout")
            Ok(self) -> {
              // Send notification
              let port_range =
                int.to_string(abs_config.port_base)
                <> "-"
                <> int.to_string(
                  abs_config.port_base
                  + { abs_config.pool_size - 1 }
                  * abs_config.port_stride
                  + abs_config.ports_per_slot
                  - 1,
                )
              process.send(
                notify,
                agent_types.SandboxStarted(
                  pool_size: running_count,
                  port_range:,
                ),
              )

              Ok(SandboxManager(
                subject: self,
                exec_timeout_ms: abs_config.exec_timeout_ms,
                port_base: abs_config.port_base,
                port_stride: abs_config.port_stride,
                ports_per_slot: abs_config.ports_per_slot,
                internal_port_base: types.internal_port_base,
              ))
            }
          }
        }
      }
    }
  }
}

/// Send shutdown message to the manager.
pub fn shutdown(manager: SandboxManager) -> Nil {
  process.send(manager.subject, types.Shutdown)
}

/// Wire the cognitive loop subject into the manager for sensory events.
/// Called after the cognitive loop starts.
pub fn set_cognitive(
  manager: SandboxManager,
  cognitive: Subject(agent_types.CognitiveMessage),
) -> Nil {
  process.send(manager.subject, types.SetCognitive(cognitive:))
}

// ---------------------------------------------------------------------------
// Message loop
// ---------------------------------------------------------------------------

fn message_loop(state: ManagerState) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(state.self)

  let msg = process.selector_receive_forever(selector)
  handle_message(state, msg)
}

fn handle_message(state: ManagerState, msg: SandboxMessage) -> Nil {
  case msg {
    types.Acquire(reply_to) -> {
      case find_ready_slot(state.slots) {
        Some(slot_id) -> {
          let new_slots =
            dict.insert(
              state.slots,
              slot_id,
              SandboxSlot(..get_slot(state.slots, slot_id), status: types.Busy),
            )
          process.send(reply_to, Ok(slot_id))
          message_loop(ManagerState(..state, slots: new_slots))
        }
        None -> {
          let serving_count =
            dict.values(state.slots)
            |> list.count(fn(s) {
              case s.status {
                types.Serving(_) -> True
                _ -> False
              }
            })
          let busy_count =
            dict.values(state.slots)
            |> list.count(fn(s) {
              case s.status {
                types.Busy -> True
                _ -> False
              }
            })
          let hint = case serving_count > 0 {
            True ->
              " ("
              <> int.to_string(serving_count)
              <> " serving, "
              <> int.to_string(busy_count)
              <> " busy — use stop_serve to free a slot)"
            False ->
              " ("
              <> int.to_string(busy_count)
              <> " busy — wait for current execution to finish)"
          }
          process.send(reply_to, Error("No available sandbox slots" <> hint))
          message_loop(state)
        }
      }
    }

    types.Release(slot_id) -> {
      // Don't clean workspace on release — allow iterative builds across
      // multiple run_code calls. Workspace is cleaned on stop_serve,
      // container restart, or shutdown.
      let new_slots = case dict.get(state.slots, slot_id) {
        Ok(slot) ->
          dict.insert(
            state.slots,
            slot_id,
            SandboxSlot(..slot, status: types.Ready),
          )
        Error(_) -> state.slots
      }
      message_loop(ManagerState(..state, slots: new_slots))
    }

    types.Execute(slot_id, code, language, timeout_ms, reply_to) -> {
      case dict.get(state.slots, slot_id) {
        Ok(slot) -> {
          let result = execute_in_slot(slot, code, language, timeout_ms)
          process.send(reply_to, result)
        }
        Error(_) ->
          process.send(
            reply_to,
            Error("Invalid slot: " <> int.to_string(slot_id)),
          )
      }
      message_loop(state)
    }

    types.Serve(slot_id, code, language, port_index, reply_to) -> {
      case dict.get(state.slots, slot_id) {
        Ok(slot) -> {
          let result =
            serve_in_slot(slot, code, language, port_index, state.config)
          case result {
            Ok(serve_result) -> {
              let new_slots =
                dict.insert(
                  state.slots,
                  slot_id,
                  SandboxSlot(
                    ..slot,
                    status: types.Serving(port: serve_result.host_port),
                  ),
                )
              process.send(reply_to, Ok(serve_result))
              message_loop(ManagerState(..state, slots: new_slots))
            }
            Error(err_msg) -> {
              process.send(reply_to, Error(err_msg))
              message_loop(state)
            }
          }
        }
        Error(_) -> {
          process.send(
            reply_to,
            Error("Invalid slot: " <> int.to_string(slot_id)),
          )
          message_loop(state)
        }
      }
    }

    types.StopServe(slot_id, reply_to) -> {
      case dict.get(state.slots, slot_id) {
        Ok(slot) -> {
          let _ =
            podman_ffi.run_cmd(
              "podman",
              ["exec", slot.container_id, "pkill", "-f", "/workspace/"],
              5000,
            )
          clean_workspace(slot.workspace)
          let new_slots =
            dict.insert(
              state.slots,
              slot_id,
              SandboxSlot(..slot, status: types.Ready),
            )
          process.send(reply_to, Ok(Nil))
          message_loop(ManagerState(..state, slots: new_slots))
        }
        Error(_) -> {
          process.send(
            reply_to,
            Error("Invalid slot: " <> int.to_string(slot_id)),
          )
          message_loop(state)
        }
      }
    }

    types.ShellExec(slot_id, command, timeout_ms, reply_to) -> {
      case dict.get(state.slots, slot_id) {
        Ok(slot) -> {
          let result = shell_exec_in_slot(slot, command, timeout_ms)
          process.send(reply_to, result)
        }
        Error(_) ->
          process.send(
            reply_to,
            Error("Invalid slot: " <> int.to_string(slot_id)),
          )
      }
      message_loop(state)
    }

    types.HealthCheck -> {
      let new_slots = health_check_slots(state)
      let _ = process.send_after(state.self, 30_000, types.HealthCheck)
      message_loop(ManagerState(..state, slots: new_slots))
    }

    types.GetStatus(reply_to) -> {
      process.send(reply_to, dict.values(state.slots))
      message_loop(state)
    }

    types.SetCognitive(cognitive:) -> {
      message_loop(ManagerState(..state, cognitive: Some(cognitive)))
    }

    types.Shutdown -> {
      slog.info("sandbox", "shutdown", "Shutting down sandbox containers", None)
      dict.values(state.slots)
      |> list.each(fn(slot) {
        let _ =
          podman_ffi.run_cmd("podman", ["rm", "-f", slot.container_id], 10_000)
        Nil
      })
      process.send(
        state.notify,
        agent_types.SandboxUnavailable(reason: "shutdown"),
      )
      Nil
    }
  }
}

// ---------------------------------------------------------------------------
// Container creation
// ---------------------------------------------------------------------------

fn create_containers(config: SandboxConfig) -> Dict(Int, SandboxSlot) {
  do_create_containers(config, 0, dict.new())
}

fn do_create_containers(
  config: SandboxConfig,
  slot_id: Int,
  acc: Dict(Int, SandboxSlot),
) -> Dict(Int, SandboxSlot) {
  case slot_id >= config.pool_size {
    True -> acc
    False -> {
      let slot = create_container(config, slot_id)
      do_create_containers(config, slot_id + 1, dict.insert(acc, slot_id, slot))
    }
  }
}

fn create_container(config: SandboxConfig, slot_id: Int) -> SandboxSlot {
  let container_name = "springdrift-sandbox-" <> int.to_string(slot_id)
  let workspace = config.workspace_dir <> "/" <> int.to_string(slot_id)
  let _ = simplifile.create_directory_all(workspace)

  let host_ports =
    types.host_ports_for_slot(
      config.port_base,
      config.port_stride,
      config.ports_per_slot,
      slot_id,
    )

  let port_args =
    diagnostics.port_mapping_args(
      config.port_base,
      config.port_stride,
      config.ports_per_slot,
      slot_id,
      types.internal_port_base,
    )

  let base_args = [
    "run",
    "-d",
    "--name",
    container_name,
    "--memory",
    int.to_string(config.memory_mb) <> "m",
    "--cpus",
    config.cpus,
    "--security-opt",
    "no-new-privileges",
    "-v",
    workspace <> ":/workspace",
  ]

  let image_args = [config.image, "sleep", "infinity"]
  let all_args = list.flatten([base_args, port_args, image_args])

  case podman_ffi.run_cmd("podman", all_args, 30_000) {
    Ok(result) ->
      case result.exit_code {
        0 -> {
          let container_id = string.trim(result.stdout)
          slog.info(
            "sandbox",
            "create",
            "Container "
              <> container_name
              <> " started (id="
              <> string.slice(container_id, 0, 12)
              <> ")",
            None,
          )
          SandboxSlot(
            slot_id:,
            container_id:,
            status: types.Ready,
            workspace:,
            host_ports:,
          )
        }
        _ -> {
          slog.log_error(
            "sandbox",
            "create",
            "Container " <> container_name <> " failed: " <> result.stderr,
            None,
          )
          SandboxSlot(
            slot_id:,
            container_id: "",
            status: types.Failed(reason: result.stderr),
            workspace:,
            host_ports:,
          )
        }
      }
    Error(msg) -> {
      slog.log_error(
        "sandbox",
        "create",
        "Container " <> container_name <> " failed: " <> msg,
        None,
      )
      SandboxSlot(
        slot_id:,
        container_id: "",
        status: types.Failed(reason: msg),
        workspace:,
        host_ports:,
      )
    }
  }
}

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------

fn shell_exec_in_slot(
  slot: SandboxSlot,
  command: String,
  timeout_ms: Int,
) -> Result(types.ExecResult, String) {
  let args = [
    "exec", "--workdir", "/workspace", slot.container_id, "/bin/sh", "-c",
    command,
  ]
  case podman_ffi.run_cmd("podman", args, timeout_ms) {
    Ok(result) -> Ok(result)
    Error(msg) -> Error("Shell exec failed: " <> msg)
  }
}

fn execute_in_slot(
  slot: SandboxSlot,
  code: String,
  language: String,
  timeout_ms: Int,
) -> Result(types.ExecResult, String) {
  let #(filename, interpreter) = language_config(language)
  let filepath = slot.workspace <> "/" <> filename

  case simplifile.write(filepath, code) {
    Error(_) -> Error("Failed to write code to workspace")
    Ok(_) -> {
      let args = [
        "exec",
        slot.container_id,
        interpreter,
        "/workspace/" <> filename,
      ]
      case podman_ffi.run_cmd("podman", args, timeout_ms) {
        Ok(result) -> Ok(result)
        Error(msg) -> Error("Execution failed: " <> msg)
      }
    }
  }
}

fn serve_in_slot(
  slot: SandboxSlot,
  code: String,
  language: String,
  port_index: Int,
  config: SandboxConfig,
) -> Result(types.ServeResult, String) {
  case port_index >= 0 && port_index < config.ports_per_slot {
    False ->
      Error("port_index must be 0-" <> int.to_string(config.ports_per_slot - 1))
    True -> {
      let #(filename, interpreter) = language_config(language)
      let filepath = slot.workspace <> "/" <> filename

      case simplifile.write(filepath, code) {
        Error(_) -> Error("Failed to write code to workspace")
        Ok(_) -> {
          let args = [
            "exec",
            "-d",
            slot.container_id,
            interpreter,
            "/workspace/" <> filename,
          ]
          case podman_ffi.run_cmd("podman", args, 10_000) {
            Ok(result) ->
              case result.exit_code {
                0 -> {
                  let hp =
                    types.host_port(
                      config.port_base,
                      config.port_stride,
                      slot.slot_id,
                      port_index,
                    )
                  let cp = types.internal_port_base + port_index
                  Ok(types.ServeResult(
                    host_port: hp,
                    container_port: cp,
                    slot_id: slot.slot_id,
                  ))
                }
                _ -> Error("Failed to start serve process: " <> result.stderr)
              }
            Error(msg) -> Error("Serve failed: " <> msg)
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn language_config(language: String) -> #(String, String) {
  case string.lowercase(language) {
    "javascript" | "js" | "node" -> #("run.js", "node")
    "bash" | "sh" -> #("run.sh", "/bin/sh")
    _ -> #("run.py", "python3")
  }
}

fn find_ready_slot(slots: Dict(Int, SandboxSlot)) -> Option(Int) {
  dict.to_list(slots)
  |> list.find_map(fn(pair) {
    let #(id, slot) = pair
    case slot.status {
      types.Ready -> Ok(id)
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

fn get_slot(slots: Dict(Int, SandboxSlot), slot_id: Int) -> SandboxSlot {
  case dict.get(slots, slot_id) {
    Ok(slot) -> slot
    Error(_) ->
      SandboxSlot(
        slot_id:,
        container_id: "",
        status: types.Failed(reason: "not found"),
        workspace: "",
        host_ports: [],
      )
  }
}

fn clean_workspace(workspace: String) -> Nil {
  case simplifile.read_directory(workspace) {
    Ok(entries) ->
      list.each(entries, fn(entry) {
        let _ = simplifile.delete(workspace <> "/" <> entry)
        Nil
      })
    Error(_) -> Nil
  }
}

fn health_check_slots(state: ManagerState) -> Dict(Int, SandboxSlot) {
  dict.fold(state.slots, state.slots, fn(acc, slot_id, slot) {
    case slot.status {
      types.Failed(_) -> acc
      _ ->
        case slot.container_id {
          "" -> acc
          cid ->
            case
              podman_ffi.run_cmd(
                "podman",
                ["inspect", "--format", "{{.State.Running}}", cid],
                5000,
              )
            {
              Ok(result) ->
                case string.contains(result.stdout, "true") {
                  True -> acc
                  False -> {
                    // Capture container logs before restarting
                    let container_logs = case
                      podman_ffi.run_cmd(
                        "podman",
                        ["logs", "--tail", "50", cid],
                        5000,
                      )
                    {
                      Ok(log_result) -> {
                        let combined =
                          string.trim(log_result.stdout)
                          <> case string.trim(log_result.stderr) {
                            "" -> ""
                            err -> "\nSTDERR:\n" <> err
                          }
                        case combined {
                          "" -> "(no output)"
                          c -> c
                        }
                      }
                      Error(_) -> "(failed to capture logs)"
                    }

                    let slot_label = "Sandbox slot " <> int.to_string(slot_id)
                    slog.warn(
                      "sandbox",
                      "health_check",
                      slot_label <> " not running, restarting",
                      None,
                    )

                    // Notify UI
                    process.send(
                      state.notify,
                      agent_types.SandboxContainerFailed(
                        slot: slot_id,
                        reason: "container stopped",
                      ),
                    )

                    // Send sensory event to cognitive loop with crash logs
                    case state.cognitive {
                      Some(cog) ->
                        process.send(
                          cog,
                          agent_types.QueuedSensoryEvent(
                            event: agent_types.SensoryEvent(
                              name: "sandbox_crash",
                              title: slot_label <> " crashed",
                              body: string.slice(container_logs, 0, 2000),
                              fired_at: get_datetime(),
                            ),
                          ),
                        )
                      None -> Nil
                    }

                    let new_slot = create_container(state.config, slot_id)
                    dict.insert(acc, slot_id, new_slot)
                  }
                }
              Error(_) -> acc
            }
        }
    }
  })
}
