//// CoderManager — coordinator for N concurrent ACP-driven coder
//// sessions.
////
//// Springdrift's role per the locked v2 architecture:
////   - own a pool of persistent containers (1 warm + spawn-on-demand)
////   - allocate a container per dispatch, spawn a driver, hand off
////   - track hourly aggregate cost across all dispatches
////   - route operator cancellations to the right driver
////   - reap idle containers via janitor TTL
////   - shut everything down cleanly on app exit
////
//// What the manager DOES NOT do:
////   - look over the in-container LLM's shoulder
////   - duplicate verification work the agent does in-container
////   - hardcode anything the operator should configure
////
//// Each dispatch spawns a driver process (see drive_session/...).
//// The driver owns the ACP handle for one session and runs the
//// per-task budget enforcement / cancel chain. The manager just
//// coordinates.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import coder/acp
import coder/circuit
import coder/ingest
import coder/types.{
  type BudgetClamp, type CoderConfig, type CoderError, type DispatchResult,
  type SessionId, type SessionSummary, type TaskBudget, BudgetClamp,
  DispatchResult, NetworkError, SessionSummary, TaskBudget,
}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sandbox/podman_ffi
import sandbox/recovery
import slog

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub type CoderMessage {
  /// Dispatch a coding task. Allocates a container, spawns a driver,
  /// drives the ACP session to completion. Reply carries a
  /// DispatchResult or CoderError.
  Dispatch(
    brief: String,
    budget: TaskBudget,
    reply_to: Subject(Result(DispatchResult, CoderError)),
  )
  /// Cancel a running session. Routes to the owning driver, which
  /// runs the three-stage kill chain.
  Cancel(session_id: SessionId, reply_to: Subject(Result(Nil, CoderError)))
  /// Read-only: list sessions currently in flight.
  ListSessions(reply_to: Subject(List(SessionSummary)))
  /// Read-only: container pool snapshot for diagnostics.
  GetState(reply_to: Subject(ManagerSnapshot))
  /// Stop the manager, tear everything down.
  Shutdown
  // ── Internal — sent by drivers and timers ──
  DriverStarted(
    session_id: SessionId,
    container_id: String,
    driver: Subject(DriverMessage),
  )
  DriverFinished(session_id: SessionId, cost_usd: Float, total_tokens: Int)
  DriverFailed(session_id: SessionId, reason: String)
  JanitorTick
}

/// Public projection of the manager's current state.
pub type ManagerSnapshot {
  ManagerSnapshot(
    containers: Int,
    idle_containers: Int,
    active_sessions: Int,
    hourly_cost_usd: Float,
  )
}

/// Driver-facing messages. Drivers run as separate processes; the
/// manager sends these to control them.
pub type DriverMessage {
  /// Cancel this driver's session. Driver runs:
  ///   1. acp.session_cancel
  ///   2. wait up to N seconds for stopReason: cancelled
  ///   3. close the ACP handle (kills the subprocess)
  ///   4. caller of dispatch sees stop_reason: "cancelled"
  DrvCancel
  /// Stop the driver immediately (used on manager shutdown).
  DrvHardStop
}

/// Opaque manager handle.
pub type CoderManager {
  CoderManager(subject: Subject(CoderMessage))
}

// ---------------------------------------------------------------------------
// Internal state
// ---------------------------------------------------------------------------

type ContainerInfo {
  ContainerInfo(
    name: String,
    started_at_ms: Int,
    last_used_at_ms: Int,
    /// True when an active session is using this container. The pool
    /// is one-session-per-container in this design (simpler model;
    /// resources are bounded per container anyway).
    busy: Bool,
  )
}

type SessionInfo {
  SessionInfo(
    session_id: SessionId,
    container_name: String,
    driver: Subject(DriverMessage),
    started_at_ms: Int,
    /// Most-recent usage report from the driver. Updated as the
    /// driver receives ACP usage_update events.
    last_cost_usd: Float,
    last_tokens: Int,
  )
}

type ManagerState {
  ManagerState(
    self: Subject(CoderMessage),
    config: CoderConfig,
    api_key: String,
    cbr_dir: String,
    sessions_dir: String,
    /// Container pool keyed by container name (e.g.
    /// "springdrift-coder-100").
    containers: Dict(String, ContainerInfo),
    /// In-flight sessions keyed by ACP session_id.
    sessions: Dict(SessionId, SessionInfo),
    /// Monotonic slot allocator. Increments on every container spawn.
    next_slot_id: Int,
    /// Rolling-hour cost.
    hourly: circuit.HourlyCost,
    /// Pool config (split out for readability). Resolved at start.
    pool: PoolConfig,
  )
}

pub type PoolConfig {
  PoolConfig(
    warm_pool_size: Int,
    max_concurrent_sessions: Int,
    container_idle_ttl_ms: Int,
    container_name_prefix: String,
    slot_id_base: Int,
    container_memory_mb: Int,
    container_cpus: String,
    container_pids_limit: Int,
  )
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

const default_warm_pool_size: Int = 1

const default_max_concurrent_sessions: Int = 4

const default_idle_ttl_ms: Int = 3_600_000

const default_name_prefix: String = "springdrift-coder"

const default_slot_id_base: Int = 100

const default_memory_mb: Int = 2048

const default_cpus: String = "2"

const default_pids_limit: Int = 256

const janitor_tick_ms: Int = 60_000

pub fn start(
  config: CoderConfig,
  api_key: String,
  cbr_dir: String,
  sessions_dir: String,
  pool: PoolConfig,
) -> Result(CoderManager, String) {
  case api_key {
    "" -> Error("CoderManager: ANTHROPIC_API_KEY is empty.")
    _ -> {
      // Sweep stale coder containers from prior runs before warming
      // the pool. Mirrors sandbox/diagnostics.sweep_stale_containers.
      // Without this, a previous crashed run leaves
      // springdrift-coder-100 etc. behind and the next spawn collides
      // on the container name.
      let swept = sweep_stale_coder_containers(pool.container_name_prefix)
      case swept > 0 {
        True ->
          slog.info(
            "coder/manager",
            "start",
            "Swept "
              <> int.to_string(swept)
              <> " stale "
              <> pool.container_name_prefix
              <> "-* containers",
            None,
          )
        False -> Nil
      }

      let setup = process.new_subject()
      process.spawn(fn() {
        let self: Subject(CoderMessage) = process.new_subject()
        process.send(setup, self)

        let now = now_ms()
        let state =
          ManagerState(
            self: self,
            config: config,
            api_key: api_key,
            cbr_dir: cbr_dir,
            sessions_dir: sessions_dir,
            containers: dict.new(),
            sessions: dict.new(),
            next_slot_id: pool.slot_id_base,
            hourly: circuit.new_hourly(now),
            pool: pool,
          )

        let warmed = warm_pool_at_boot(state)
        process.send_after(self, janitor_tick_ms, JanitorTick)
        message_loop(warmed)
      })

      case process.receive(setup, 5000) {
        Error(_) -> Error("CoderManager startup timeout")
        Ok(self) -> Ok(CoderManager(subject: self))
      }
    }
  }
}

/// Build a PoolConfig from defaults + optional overrides. Helper for
/// the start-up wiring in springdrift.gleam.
pub fn pool_config_from_options(
  warm_pool_size warm_pool_size: Option(Int),
  max_concurrent_sessions max_concurrent_sessions: Option(Int),
  container_idle_ttl_ms container_idle_ttl_ms: Option(Int),
  container_name_prefix container_name_prefix: Option(String),
  slot_id_base slot_id_base: Option(Int),
  container_memory_mb container_memory_mb: Option(Int),
  container_cpus container_cpus: Option(String),
  container_pids_limit container_pids_limit: Option(Int),
) -> PoolConfig {
  PoolConfig(
    warm_pool_size: option.unwrap(warm_pool_size, default_warm_pool_size),
    max_concurrent_sessions: option.unwrap(
      max_concurrent_sessions,
      default_max_concurrent_sessions,
    ),
    container_idle_ttl_ms: option.unwrap(
      container_idle_ttl_ms,
      default_idle_ttl_ms,
    ),
    container_name_prefix: option.unwrap(
      container_name_prefix,
      default_name_prefix,
    ),
    slot_id_base: option.unwrap(slot_id_base, default_slot_id_base),
    container_memory_mb: option.unwrap(container_memory_mb, default_memory_mb),
    container_cpus: option.unwrap(container_cpus, default_cpus),
    container_pids_limit: option.unwrap(
      container_pids_limit,
      default_pids_limit,
    ),
  )
}

pub fn shutdown(manager: CoderManager) -> Nil {
  process.send(manager.subject, Shutdown)
}

/// Dispatch a coding task. Blocks until completion (or AcpError).
pub fn dispatch_task(
  manager: CoderManager,
  brief: String,
  budget: TaskBudget,
) -> Result(DispatchResult, CoderError) {
  let reply = process.new_subject()
  process.send(
    manager.subject,
    Dispatch(brief: brief, budget: budget, reply_to: reply),
  )
  // Receive timeout = budget.max_minutes + 30s slack. Manager-side
  // timer enforces the real cap; this is just to free the caller if
  // the manager itself wedges.
  let receive_timeout = { budget.max_minutes * 60 * 1000 } + 30_000
  case process.receive(reply, receive_timeout) {
    Ok(r) -> r
    Error(_) ->
      Error(NetworkError("CoderManager dispatch timeout (manager unresponsive)"))
  }
}

pub fn cancel_session(
  manager: CoderManager,
  session_id: SessionId,
) -> Result(Nil, CoderError) {
  let reply = process.new_subject()
  process.send(manager.subject, Cancel(session_id: session_id, reply_to: reply))
  case process.receive(reply, 30_000) {
    Ok(r) -> r
    Error(_) -> Error(NetworkError("CoderManager cancel timeout"))
  }
}

pub fn list_sessions(manager: CoderManager) -> List(SessionSummary) {
  let reply = process.new_subject()
  process.send(manager.subject, ListSessions(reply_to: reply))
  case process.receive(reply, 5000) {
    Ok(s) -> s
    Error(_) -> []
  }
}

pub fn get_state(manager: CoderManager) -> ManagerSnapshot {
  let reply = process.new_subject()
  process.send(manager.subject, GetState(reply_to: reply))
  case process.receive(reply, 5000) {
    Ok(s) -> s
    Error(_) ->
      ManagerSnapshot(
        containers: 0,
        idle_containers: 0,
        active_sessions: 0,
        hourly_cost_usd: 0.0,
      )
  }
}

// ---------------------------------------------------------------------------
// Budget helpers — pure
// ---------------------------------------------------------------------------

/// Resolve a per-task budget against config defaults + ceilings.
/// Returns the resolved budget and a list of clamps (empty when the
/// requested budget fit under all ceilings).
///
/// This is the "agent has agency within bounds" enforcement point.
pub fn resolve_budget(
  config: CoderConfig,
  defaults: TaskBudget,
  ceilings: TaskBudget,
  requested: Option(TaskBudget),
) -> #(TaskBudget, List(BudgetClamp)) {
  case requested {
    None -> #(defaults, [])
    Some(req) -> {
      let _ = config
      let #(tokens, c1) =
        clamp_int(
          "max_tokens",
          req.max_tokens,
          ceilings.max_tokens,
          defaults.max_tokens,
        )
      let #(cost, c2) =
        clamp_float(
          "max_cost_usd",
          req.max_cost_usd,
          ceilings.max_cost_usd,
          defaults.max_cost_usd,
        )
      let #(minutes, c3) =
        clamp_int(
          "max_minutes",
          req.max_minutes,
          ceilings.max_minutes,
          defaults.max_minutes,
        )
      let #(turns, c4) =
        clamp_int(
          "max_turns",
          req.max_turns,
          ceilings.max_turns,
          defaults.max_turns,
        )
      let clamps =
        [c1, c2, c3, c4]
        |> list.filter_map(fn(o) {
          case o {
            Some(c) -> Ok(c)
            None -> Error(Nil)
          }
        })
      #(
        TaskBudget(
          max_tokens: tokens,
          max_cost_usd: cost,
          max_minutes: minutes,
          max_turns: turns,
        ),
        clamps,
      )
    }
  }
}

fn clamp_int(
  name: String,
  requested: Int,
  ceiling: Int,
  default_val: Int,
) -> #(Int, Option(BudgetClamp)) {
  let _ = default_val
  case requested > ceiling {
    True -> #(
      ceiling,
      Some(BudgetClamp(
        field: name,
        requested: int.to_string(requested),
        clamped: int.to_string(ceiling),
      )),
    )
    False -> #(requested, None)
  }
}

fn clamp_float(
  name: String,
  requested: Float,
  ceiling: Float,
  default_val: Float,
) -> #(Float, Option(BudgetClamp)) {
  let _ = default_val
  case requested >. ceiling {
    True -> #(
      ceiling,
      Some(BudgetClamp(
        field: name,
        requested: float_to_string(requested),
        clamped: float_to_string(ceiling),
      )),
    )
    False -> #(requested, None)
  }
}

// ---------------------------------------------------------------------------
// Message loop
// ---------------------------------------------------------------------------

fn message_loop(state: ManagerState) -> Nil {
  let msg = process.receive_forever(state.self)
  case msg {
    Shutdown -> handle_shutdown(state)
    Dispatch(brief:, budget:, reply_to:) -> {
      let new_state = handle_dispatch(state, brief, budget, reply_to)
      message_loop(new_state)
    }
    Cancel(session_id:, reply_to:) -> {
      handle_cancel(state, session_id, reply_to)
      message_loop(state)
    }
    ListSessions(reply_to:) -> {
      process.send(reply_to, snapshot_sessions(state))
      message_loop(state)
    }
    GetState(reply_to:) -> {
      process.send(reply_to, snapshot(state))
      message_loop(state)
    }
    DriverStarted(session_id:, container_id:, driver:) -> {
      let info =
        SessionInfo(
          session_id: session_id,
          container_name: container_id,
          driver: driver,
          started_at_ms: now_ms(),
          last_cost_usd: 0.0,
          last_tokens: 0,
        )
      let new_state =
        ManagerState(
          ..state,
          sessions: dict.insert(state.sessions, session_id, info),
        )
      message_loop(new_state)
    }
    DriverFinished(session_id:, cost_usd:, total_tokens: _) -> {
      let new_state = handle_driver_finished(state, session_id, cost_usd)
      message_loop(new_state)
    }
    DriverFailed(session_id:, reason:) -> {
      slog.warn(
        "coder/manager",
        "driver_failed",
        "session=" <> session_id <> " reason=" <> reason,
        Some(session_id),
      )
      let new_state = release_session(state, session_id)
      message_loop(new_state)
    }
    JanitorTick -> {
      // Health-check first (drops idle dead containers) then run the
      // TTL janitor (reaps idle-too-long containers). Order matters
      // only insofar as the health check shrinks the dict the
      // janitor walks — both are idempotent.
      let new_state =
        state
        |> run_health_check
        |> run_janitor
      let _ = process.send_after(state.self, janitor_tick_ms, JanitorTick)
      message_loop(new_state)
    }
  }
}

// ---------------------------------------------------------------------------
// Dispatch handler — allocates container + spawns driver
// ---------------------------------------------------------------------------

fn handle_dispatch(
  state: ManagerState,
  brief: String,
  budget: TaskBudget,
  reply_to: Subject(Result(DispatchResult, CoderError)),
) -> ManagerState {
  // Hourly cap check first — refuse new dispatch if hourly is full.
  let now = now_ms()
  let hourly = circuit.maybe_roll_hourly(state.hourly, now)
  case hourly.accumulated_usd >=. state.config.max_cost_per_hour_usd {
    True -> {
      process.send(
        reply_to,
        Error(types.HourlyBudgetExceeded(
          consumed_usd: hourly.accumulated_usd,
          cap_usd: state.config.max_cost_per_hour_usd,
        )),
      )
      ManagerState(..state, hourly: hourly)
    }
    False -> {
      // Concurrent-session cap.
      let active_count = dict.size(state.sessions)
      case active_count >= state.pool.max_concurrent_sessions {
        True -> {
          process.send(
            reply_to,
            Error(NetworkError(
              "Concurrent-session cap reached ("
              <> int.to_string(state.pool.max_concurrent_sessions)
              <> "). Try again when a slot frees.",
            )),
          )
          ManagerState(..state, hourly: hourly)
        }
        False -> {
          let #(container_state, container_name) = acquire_container(state)
          case container_name {
            Error(reason) -> {
              process.send(reply_to, Error(types.ContainerStartFailed(reason)))
              ManagerState(..container_state, hourly: hourly)
            }
            Ok(name) -> {
              spawn_driver(
                ManagerState(..container_state, hourly: hourly),
                name,
                brief,
                budget,
                reply_to,
              )
            }
          }
        }
      }
    }
  }
}

fn spawn_driver(
  state: ManagerState,
  container_name: String,
  brief: String,
  budget: TaskBudget,
  reply_to: Subject(Result(DispatchResult, CoderError)),
) -> ManagerState {
  let manager_self = state.self
  let cbr_dir = state.cbr_dir
  let sessions_dir = state.sessions_dir
  let model_id = state.config.model_id
  let project_root = state.config.project_root

  process.spawn(fn() {
    drive_session(
      manager_self,
      container_name,
      brief,
      budget,
      reply_to,
      cbr_dir,
      sessions_dir,
      model_id,
      project_root,
    )
  })

  state
}

// ---------------------------------------------------------------------------
// Driver process — owns one ACP session
// ---------------------------------------------------------------------------

fn drive_session(
  manager_self: Subject(CoderMessage),
  container_name: String,
  brief: String,
  budget: TaskBudget,
  reply_to: Subject(Result(DispatchResult, CoderError)),
  cbr_dir: String,
  sessions_dir: String,
  model_id: String,
  project_root: String,
) -> Nil {
  let started_at = now_ms()
  let _ = project_root

  // 1. Open ACP handle on the container.
  case acp.open(container_name) {
    Error(e) -> {
      process.send(reply_to, Error(map_acp_error(e)))
      process.send(
        manager_self,
        DriverFailed(session_id: "(no-session)", reason: acp.format_error(e)),
      )
      Nil
    }
    Ok(handle) -> {
      // 2. initialize handshake.
      case acp.initialize(handle) {
        Error(e) -> {
          acp.close(handle)
          process.send(reply_to, Error(map_acp_error(e)))
          process.send(
            manager_self,
            DriverFailed(
              session_id: "(no-session)",
              reason: acp.format_error(e),
            ),
          )
          Nil
        }
        Ok(_caps) -> {
          // 3. Create a session.
          case acp.session_new(handle, "/workspace/project", Some(model_id)) {
            Error(e) -> {
              acp.close(handle)
              process.send(reply_to, Error(map_acp_error(e)))
              process.send(
                manager_self,
                DriverFailed(
                  session_id: "(no-session)",
                  reason: acp.format_error(e),
                ),
              )
              Nil
            }
            Ok(session_id) -> {
              // Register with the manager so cancel can find us.
              let driver_subject: Subject(DriverMessage) = process.new_subject()
              process.send(
                manager_self,
                DriverStarted(
                  session_id: session_id,
                  container_id: container_name,
                  driver: driver_subject,
                ),
              )

              // 4. Run the prompt with budget enforcement.
              let outcome =
                run_prompt(
                  handle,
                  session_id,
                  brief,
                  budget,
                  driver_subject,
                  manager_self,
                )

              // 5. Tear down + ingest + reply.
              acp.close(handle)
              let duration = now_ms() - started_at

              case outcome {
                Ok(#(prompt_result, conversation, accumulated_cost, tool_titles)) -> {
                  ingest.ingest_session(
                    cbr_dir,
                    sessions_dir,
                    session_id,
                    conversation,
                    tool_titles,
                    model_id,
                    duration,
                  )
                  let result =
                    DispatchResult(
                      session_id: session_id,
                      stop_reason: stop_reason_to_string(
                        prompt_result.stop_reason,
                      ),
                      response_text: extract_response_text(conversation),
                      total_tokens: prompt_result.total_tokens,
                      input_tokens: prompt_result.input_tokens,
                      output_tokens: prompt_result.output_tokens,
                      cost_usd: accumulated_cost,
                      duration_ms: duration,
                      budget_clamps: [],
                    )
                  process.send(reply_to, Ok(result))
                  process.send(
                    manager_self,
                    DriverFinished(
                      session_id: session_id,
                      cost_usd: accumulated_cost,
                      total_tokens: prompt_result.total_tokens,
                    ),
                  )
                }
                Error(e) -> {
                  process.send(reply_to, Error(map_acp_error(e)))
                  process.send(
                    manager_self,
                    DriverFailed(
                      session_id: session_id,
                      reason: acp.format_error(e),
                    ),
                  )
                }
              }
              Nil
            }
          }
        }
      }
    }
  }
}

/// Run a session prompt, consuming events for budget enforcement and
/// conversation logging. Returns either the prompt result + final
/// conversation + accumulated cost + tool titles seen, or an AcpError.
///
/// `tool_titles` is the distinct list of OpenCode tool names the
/// in-container model invoked, in first-seen order. Springdrift uses
/// it to populate Solution.tools_used on the resulting CbrCase so
/// retrieval can match "previous session that used Read+Edit+Bash"
/// against new briefs.
fn run_prompt(
  handle: acp.AcpHandle,
  session_id: SessionId,
  brief: String,
  budget: TaskBudget,
  driver_subject: Subject(DriverMessage),
  _manager_self: Subject(CoderMessage),
) -> Result(
  #(acp.PromptResult, List(#(String, String)), Float, List(String)),
  acp.AcpError,
) {
  let event_sink: Subject(acp.AcpEvent) = process.new_subject()
  let reply = acp.session_prompt_async(handle, session_id, brief, event_sink)

  // Schedule wall-clock timer
  let timeout_ms = budget.max_minutes * 60_000

  drive_loop(
    handle,
    session_id,
    brief,
    reply,
    event_sink,
    driver_subject,
    budget,
    "",
    0.0,
    0,
    [],
    timeout_ms,
    now_ms(),
  )
}

fn drive_loop(
  handle: acp.AcpHandle,
  session_id: SessionId,
  brief: String,
  reply: Subject(Result(acp.PromptResult, acp.AcpError)),
  event_sink: Subject(acp.AcpEvent),
  driver_subject: Subject(DriverMessage),
  budget: TaskBudget,
  accumulated_text: String,
  accumulated_cost: Float,
  accumulated_tokens: Int,
  tool_titles: List(String),
  timeout_ms: Int,
  started_at_ms: Int,
) -> Result(
  #(acp.PromptResult, List(#(String, String)), Float, List(String)),
  acp.AcpError,
) {
  // Selector merging: prompt reply, event sink, driver controls.
  let elapsed = now_ms() - started_at_ms
  let remaining = case timeout_ms - elapsed {
    n if n > 0 -> n
    _ -> 1
  }

  let selector =
    process.new_selector()
    |> process.select_map(reply, fn(r) { ReplyArrived(result: r) })
    |> process.select_map(event_sink, fn(ev) { EventArrived(event: ev) })
    |> process.select_map(driver_subject, fn(ctl) {
      DriverCtrlArrived(ctrl: ctl)
    })

  case process.selector_receive(selector, remaining) {
    Error(_) -> {
      // Wall-clock timeout. Cancel and wait briefly for the cancelled
      // response to arrive.
      let _ = acp.session_cancel(handle, session_id)
      Error(acp.AcpTimeout(operation: "session/prompt", ms: timeout_ms))
    }
    Ok(item) -> {
      case item {
        ReplyArrived(result) ->
          case result {
            Error(e) -> Error(e)
            Ok(pr) -> {
              let conversation = [#(brief, accumulated_text)]
              Ok(#(pr, conversation, accumulated_cost, tool_titles))
            }
          }
        EventArrived(ev) -> {
          let #(new_text, new_cost, new_tokens, new_titles, breach) =
            apply_event(
              ev,
              accumulated_text,
              accumulated_cost,
              accumulated_tokens,
              tool_titles,
              budget,
            )
          case breach {
            Some(breach_reason) -> {
              let _ = acp.session_cancel(handle, session_id)
              // Continue draining until the prompt response arrives,
              // but record that we breached.
              drive_loop(
                handle,
                session_id,
                brief,
                reply,
                event_sink,
                driver_subject,
                budget,
                new_text,
                new_cost,
                new_tokens,
                new_titles,
                timeout_ms,
                started_at_ms,
              )
              |> result.map(fn(quad) {
                let _ = breach_reason
                quad
              })
            }
            None ->
              drive_loop(
                handle,
                session_id,
                brief,
                reply,
                event_sink,
                driver_subject,
                budget,
                new_text,
                new_cost,
                new_tokens,
                new_titles,
                timeout_ms,
                started_at_ms,
              )
          }
        }
        DriverCtrlArrived(ctrl) ->
          case ctrl {
            DrvCancel -> {
              let _ = acp.session_cancel(handle, session_id)
              drive_loop(
                handle,
                session_id,
                brief,
                reply,
                event_sink,
                driver_subject,
                budget,
                accumulated_text,
                accumulated_cost,
                accumulated_tokens,
                tool_titles,
                timeout_ms,
                started_at_ms,
              )
            }
            DrvHardStop -> Error(acp.AcpClosed)
          }
      }
    }
  }
}

type DriveItem {
  ReplyArrived(result: Result(acp.PromptResult, acp.AcpError))
  EventArrived(event: acp.AcpEvent)
  DriverCtrlArrived(ctrl: DriverMessage)
}

fn apply_event(
  ev: acp.AcpEvent,
  accumulated_text: String,
  accumulated_cost: Float,
  accumulated_tokens: Int,
  tool_titles: List(String),
  budget: TaskBudget,
) -> #(String, Float, Int, List(String), Option(String)) {
  case ev {
    acp.AcpMessageChunk(text: t, ..) -> {
      let new_text = accumulated_text <> t
      #(new_text, accumulated_cost, accumulated_tokens, tool_titles, None)
    }
    acp.AcpUsageUpdate(used_tokens: tk, cost_usd: c, ..) -> {
      let new_tokens = case tk > accumulated_tokens {
        True -> tk
        False -> accumulated_tokens
      }
      let new_cost = case c >. accumulated_cost {
        True -> c
        False -> accumulated_cost
      }
      let breach = check_budget_breach(new_tokens, new_cost, budget)
      #(accumulated_text, new_cost, new_tokens, tool_titles, breach)
    }
    acp.AcpToolCall(title: t, ..) -> {
      // Append distinct titles in first-seen order. The title is what
      // OpenCode shows the user (e.g. "Read", "Edit", "Bash"); kind is
      // a stable enum we don't need yet. CBR retrieval works fine off
      // the title.
      let new_titles = case list.contains(tool_titles, t) {
        True -> tool_titles
        False -> list.append(tool_titles, [t])
      }
      #(
        accumulated_text,
        accumulated_cost,
        accumulated_tokens,
        new_titles,
        None,
      )
    }
    _ -> #(
      accumulated_text,
      accumulated_cost,
      accumulated_tokens,
      tool_titles,
      None,
    )
  }
}

fn check_budget_breach(
  tokens: Int,
  cost: Float,
  budget: TaskBudget,
) -> Option(String) {
  case tokens > budget.max_tokens, cost >. budget.max_cost_usd {
    True, _ ->
      Some(
        "tokens "
        <> int.to_string(tokens)
        <> " > cap "
        <> int.to_string(budget.max_tokens),
      )
    _, True ->
      Some(
        "cost $"
        <> float_to_string(cost)
        <> " > cap $"
        <> float_to_string(budget.max_cost_usd),
      )
    _, _ -> None
  }
}

// ---------------------------------------------------------------------------
// Container pool helpers
// ---------------------------------------------------------------------------

fn acquire_container(
  state: ManagerState,
) -> #(ManagerState, Result(String, String)) {
  // Find an idle container.
  let idle =
    state.containers
    |> dict.to_list
    |> list.find_map(fn(kv) {
      let #(name, info) = kv
      case info.busy {
        True -> Error(Nil)
        False -> Ok(name)
      }
    })

  case idle {
    Ok(name) -> {
      // Mark busy.
      let info = case dict.get(state.containers, name) {
        Ok(i) -> ContainerInfo(..i, busy: True, last_used_at_ms: now_ms())
        Error(_) ->
          ContainerInfo(
            name: name,
            started_at_ms: now_ms(),
            last_used_at_ms: now_ms(),
            busy: True,
          )
      }
      let new_state =
        ManagerState(
          ..state,
          containers: dict.insert(state.containers, name, info),
        )
      #(new_state, Ok(name))
    }
    Error(_) -> {
      // No idle — spawn a new one.
      spawn_container(state)
    }
  }
}

fn spawn_container(
  state: ManagerState,
) -> #(ManagerState, Result(String, String)) {
  do_spawn_container(state, False)
}

/// `recovered_already` flips True after the first image-recovery
/// attempt to prevent infinite recursion when the registry itself is
/// the problem.
fn do_spawn_container(
  state: ManagerState,
  recovered_already: Bool,
) -> #(ManagerState, Result(String, String)) {
  let slot_id = state.next_slot_id
  let name = state.pool.container_name_prefix <> "-" <> int.to_string(slot_id)

  let args = build_run_args(state, name)
  case podman_ffi.run_cmd("podman", args, 30_000) {
    Error(e) -> #(state, Error("podman run failed: " <> e))
    Ok(r) ->
      case r.exit_code {
        0 -> {
          let now = now_ms()
          let info =
            ContainerInfo(
              name: name,
              started_at_ms: now,
              last_used_at_ms: now,
              busy: True,
            )
          let new_state =
            ManagerState(
              ..state,
              containers: dict.insert(state.containers, name, info),
              next_slot_id: slot_id + 1,
            )
          // Write auth.json into the new container before any caller
          // tries to open ACP on it.
          let _ = write_auth(name, state.api_key)
          #(new_state, Ok(name))
        }
        _ -> {
          // Image-corruption auto-recovery: if podman stderr looks
          // like an image problem and we haven't recovered yet this
          // call, re-pull the image and retry once. Same autonomous
          // recovery as the sandbox manager — without it a corrupted
          // coder image wedges every dispatch on a VPS.
          case
            !recovered_already
            && state.config.image_recovery_enabled
            && recovery.is_image_error(r.stderr)
          {
            False -> #(
              state,
              Error(
                "podman run exit "
                <> int.to_string(r.exit_code)
                <> ": "
                <> r.stderr,
              ),
            )
            True -> {
              slog.warn(
                "coder/manager",
                "spawn",
                "Image-related spawn failure; recovering image: "
                  <> state.config.image,
                None,
              )
              case
                recovery.recover_image(
                  state.config.image,
                  state.config.image_pull_timeout_ms,
                )
              {
                Error(msg) -> {
                  slog.log_error(
                    "coder/manager",
                    "spawn",
                    "Image recovery failed: " <> msg,
                    None,
                  )
                  #(
                    state,
                    Error("image recovery failed after spawn error: " <> msg),
                  )
                }
                Ok(_) -> do_spawn_container(state, True)
              }
            }
          }
        }
      }
  }
}

/// Health check pass: drop containers that podman reports as not
/// running. Idle dead containers are removed from the pool — the
/// next dispatch will spawn a fresh one. Busy dead containers cause
/// the owning driver to fail on its next ACP call (catching it here
/// would race with the driver's own teardown), so we just log and
/// leave them; the driver's existing failure path will release the
/// container via `release_session`.
fn run_health_check(state: ManagerState) -> ManagerState {
  let dead_idle =
    state.containers
    |> dict.to_list
    |> list.filter_map(fn(kv) {
      let #(name, info) = kv
      case info.busy {
        True -> Error(Nil)
        False ->
          case container_alive(name) {
            True -> Error(Nil)
            False -> Ok(name)
          }
      }
    })

  case dead_idle {
    [] -> state
    names -> {
      list.each(names, fn(name) {
        slog.warn(
          "coder/manager",
          "health_check",
          "Idle container " <> name <> " not running; removing from pool",
          None,
        )
        // Best-effort cleanup of any lingering podman state.
        let _ = podman_ffi.run_cmd("podman", ["rm", "-f", name], 5000)
        Nil
      })
      let surviving =
        list.filter(dict.to_list(state.containers), fn(kv) {
          let #(name, _) = kv
          !list.contains(names, name)
        })
      ManagerState(..state, containers: dict.from_list(surviving))
    }
  }
}

/// True when `podman inspect` reports the container is running.
/// Errors are treated as "alive" (fail-open) so a transient podman
/// hiccup doesn't trigger spurious removals.
fn container_alive(name: String) -> Bool {
  case
    podman_ffi.run_cmd(
      "podman",
      ["inspect", "--format", "{{.State.Running}}", name],
      5000,
    )
  {
    Ok(r) ->
      case r.exit_code {
        0 -> string.contains(r.stdout, "true")
        _ -> True
      }
    Error(_) -> True
  }
}

/// Remove leftover springdrift-coder-* containers from a prior run.
/// Returns the count removed. Pure best-effort — failures are
/// swallowed so a podman hiccup at startup never blocks the manager.
pub fn sweep_stale_coder_containers(prefix: String) -> Int {
  case
    podman_ffi.run_cmd(
      "podman",
      [
        "ps",
        "-a",
        "--filter",
        "name=" <> prefix <> "-",
        "--format",
        "{{.Names}}",
      ],
      10_000,
    )
  {
    Ok(result) ->
      case result.exit_code {
        0 -> {
          let names =
            result.stdout
            |> string.trim
            |> string.split("\n")
            |> list.filter(fn(n) { n != "" })
          list.each(names, fn(name) {
            let _ = podman_ffi.run_cmd("podman", ["rm", "-f", name], 10_000)
            Nil
          })
          list.length(names)
        }
        _ -> 0
      }
    Error(_) -> 0
  }
}

fn build_run_args(state: ManagerState, container_name: String) -> List(String) {
  list.flatten([
    [
      "run",
      "-d",
      // Persistent — no --rm. Janitor reaps idle containers on TTL.
      "--name",
      container_name,
      "--security-opt",
      "no-new-privileges",
      "--userns=keep-id",
      "--memory",
      int.to_string(state.pool.container_memory_mb) <> "m",
      "--cpus",
      state.pool.container_cpus,
      "--pids-limit",
      int.to_string(state.pool.container_pids_limit),
      "-v",
      state.config.project_root <> ":/workspace/project",
      "-e",
      "ANTHROPIC_API_KEY=" <> state.api_key,
    ],
    [state.config.image, "sleep", "infinity"],
  ])
}

fn write_auth(container_name: String, api_key: String) -> Result(Nil, String) {
  let payload =
    "{\"anthropic\":{\"type\":\"api\",\"key\":\"" <> api_key <> "\"}}"
  let temp_path = "/tmp/springdrift-coder-auth-" <> container_name <> ".json"
  let _ =
    podman_ffi.run_cmd(
      "sh",
      ["-c", "echo '" <> payload <> "' > " <> temp_path],
      5000,
    )
  let _ =
    podman_ffi.run_cmd(
      "podman",
      [
        "exec",
        container_name,
        "mkdir",
        "-p",
        "/root/.config/opencode",
      ],
      5000,
    )
  let _ =
    podman_ffi.run_cmd(
      "podman",
      [
        "cp",
        temp_path,
        container_name <> ":/root/.config/opencode/auth.json",
      ],
      5000,
    )
  let _ = podman_ffi.run_cmd("rm", ["-f", temp_path], 2000)
  Ok(Nil)
}

fn warm_pool_at_boot(state: ManagerState) -> ManagerState {
  case state.pool.warm_pool_size {
    n if n > 0 -> {
      let #(new_state, _) = spawn_container(state)
      // Mark the just-spawned container as Idle (not busy) — it's
      // warm but unused.
      mark_all_idle(new_state)
    }
    _ -> state
  }
}

fn mark_all_idle(state: ManagerState) -> ManagerState {
  let updated =
    dict.map_values(state.containers, fn(_, info) {
      ContainerInfo(..info, busy: False)
    })
  ManagerState(..state, containers: updated)
}

fn release_session(state: ManagerState, session_id: SessionId) -> ManagerState {
  case dict.get(state.sessions, session_id) {
    Error(_) -> state
    Ok(info) -> {
      let containers = case dict.get(state.containers, info.container_name) {
        Ok(c) ->
          dict.insert(
            state.containers,
            info.container_name,
            ContainerInfo(..c, busy: False, last_used_at_ms: now_ms()),
          )
        Error(_) -> state.containers
      }
      ManagerState(
        ..state,
        sessions: dict.delete(state.sessions, session_id),
        containers: containers,
      )
    }
  }
}

fn handle_driver_finished(
  state: ManagerState,
  session_id: SessionId,
  cost_usd: Float,
) -> ManagerState {
  let now = now_ms()
  let new_hourly = circuit.add_session_cost(state.hourly, cost_usd, now)
  release_session(ManagerState(..state, hourly: new_hourly), session_id)
}

fn handle_cancel(
  state: ManagerState,
  session_id: SessionId,
  reply_to: Subject(Result(Nil, CoderError)),
) -> Nil {
  case dict.get(state.sessions, session_id) {
    Error(_) ->
      process.send(
        reply_to,
        Error(types.SessionNotFound(session_id: session_id)),
      )
    Ok(info) -> {
      // Layer 1: send graceful cancel to driver.
      process.send(info.driver, DrvCancel)
      process.send(reply_to, Ok(Nil))
    }
  }
}

fn run_janitor(state: ManagerState) -> ManagerState {
  let now = now_ms()
  let ttl = state.pool.container_idle_ttl_ms

  let partitioned =
    state.containers
    |> dict.to_list
    |> list.partition(fn(kv) {
      let #(_, info) = kv
      info.busy || { now - info.last_used_at_ms } < ttl
    })
  let keep = partitioned.0
  let reap = partitioned.1

  list.each(reap, fn(kv) {
    let #(name, _) = kv
    let _ = podman_ffi.run_cmd("podman", ["rm", "-f", name], 5000)
    slog.info("coder/manager", "janitor", "Reaped idle " <> name, None)
  })

  ManagerState(..state, containers: dict.from_list(keep))
}

fn handle_shutdown(state: ManagerState) -> Nil {
  // Hard-stop all drivers, then tear down containers.
  dict.each(state.sessions, fn(_session_id, info) {
    process.send(info.driver, DrvHardStop)
  })
  dict.each(state.containers, fn(name, _) {
    let _ = podman_ffi.run_cmd("podman", ["rm", "-f", name], 5000)
    Nil
  })
  slog.info("coder/manager", "shutdown", "CoderManager stopped", None)
}

fn snapshot(state: ManagerState) -> ManagerSnapshot {
  let total = dict.size(state.containers)
  let idle =
    state.containers
    |> dict.values
    |> list.filter(fn(c) { !c.busy })
    |> list.length
  ManagerSnapshot(
    containers: total,
    idle_containers: idle,
    active_sessions: dict.size(state.sessions),
    hourly_cost_usd: state.hourly.accumulated_usd,
  )
}

fn snapshot_sessions(state: ManagerState) -> List(SessionSummary) {
  state.sessions
  |> dict.values
  |> list.map(fn(s) {
    SessionSummary(
      session_id: s.session_id,
      container_id: s.container_name,
      started_at_ms: s.started_at_ms,
      cost_usd_so_far: s.last_cost_usd,
      tokens_so_far: s.last_tokens,
    )
  })
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn extract_response_text(conversation: List(#(String, String))) -> String {
  conversation
  |> list.first
  |> result.map(fn(pair) { pair.1 })
  |> result.unwrap("")
}

fn map_acp_error(e: acp.AcpError) -> CoderError {
  NetworkError(acp.format_error(e))
}

fn stop_reason_to_string(s: acp.StopReason) -> String {
  case s {
    acp.StopEndTurn -> "end_turn"
    acp.StopMaxTokens -> "max_tokens"
    acp.StopMaxTurnRequests -> "max_turn_requests"
    acp.StopRefusal -> "refusal"
    acp.StopCancelled -> "cancelled"
    acp.StopUnknown(raw: r) -> r
  }
}

@external(erlang, "erlang", "float_to_binary")
fn float_to_binary(f: Float, opts: List(FloatFormatOpt)) -> String

type FloatFormatOpt {
  Decimals(Int)
  Compact
}

fn float_to_string(f: Float) -> String {
  float_to_binary(f, [Decimals(4), Compact])
}

@external(erlang, "springdrift_ffi", "monotonic_now_ms")
fn now_ms() -> Int
