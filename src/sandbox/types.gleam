//// Core types for the local Podman sandbox.
////
//// The sandbox provides two execution modes:
//// - run_code: execute a script, return stdout/stderr
//// - serve: start a long-lived process with port forwarding

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import agent/types as agent_types
import gleam/erlang/process.{type Subject}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

pub type SandboxConfig {
  SandboxConfig(
    pool_size: Int,
    memory_mb: Int,
    cpus: String,
    image: String,
    exec_timeout_ms: Int,
    port_base: Int,
    port_stride: Int,
    ports_per_slot: Int,
    auto_machine: Bool,
    workspace_dir: String,
  )
}

// ---------------------------------------------------------------------------
// Slot — one container in the pool
// ---------------------------------------------------------------------------

pub type SandboxSlot {
  SandboxSlot(
    slot_id: Int,
    container_id: String,
    status: SlotStatus,
    workspace: String,
    host_ports: List(Int),
  )
}

pub type SlotStatus {
  Ready
  Busy
  Failed(reason: String)
  Serving(port: Int)
}

// ---------------------------------------------------------------------------
// Execution results
// ---------------------------------------------------------------------------

pub type ExecResult {
  ExecResult(exit_code: Int, stdout: String, stderr: String)
}

pub type ServeResult {
  ServeResult(host_port: Int, container_port: Int, slot_id: Int)
}

// ---------------------------------------------------------------------------
// Manager messages
// ---------------------------------------------------------------------------

pub type SandboxMessage {
  Acquire(reply_to: Subject(Result(Int, String)))
  Release(slot_id: Int)
  Execute(
    slot_id: Int,
    code: String,
    language: String,
    timeout_ms: Int,
    reply_to: Subject(Result(ExecResult, String)),
  )
  Serve(
    slot_id: Int,
    code: String,
    language: String,
    port_index: Int,
    reply_to: Subject(Result(ServeResult, String)),
  )
  StopServe(slot_id: Int, reply_to: Subject(Result(Nil, String)))
  ShellExec(
    slot_id: Int,
    command: String,
    timeout_ms: Int,
    reply_to: Subject(Result(ExecResult, String)),
  )
  HealthCheck
  GetStatus(reply_to: Subject(List(SandboxSlot)))
  SetCognitive(cognitive: Subject(agent_types.CognitiveMessage))
  Shutdown
}

/// Opaque manager handle — wraps the subject + config for tool access.
pub type SandboxManager {
  SandboxManager(
    subject: Subject(SandboxMessage),
    exec_timeout_ms: Int,
    port_base: Int,
    port_stride: Int,
    ports_per_slot: Int,
    internal_port_base: Int,
  )
}

// ---------------------------------------------------------------------------
// Port allocation helpers (pure functions)
// ---------------------------------------------------------------------------

/// Calculate the host port for a given slot and port index.
/// Formula: port_base + (slot * port_stride) + index
pub fn host_port(port_base: Int, port_stride: Int, slot: Int, index: Int) -> Int {
  port_base + slot * port_stride + index
}

/// Generate the list of host ports for a given slot.
pub fn host_ports_for_slot(
  port_base: Int,
  port_stride: Int,
  ports_per_slot: Int,
  slot: Int,
) -> List(Int) {
  do_host_ports(port_base, port_stride, slot, 0, ports_per_slot, [])
}

fn do_host_ports(
  port_base: Int,
  port_stride: Int,
  slot: Int,
  index: Int,
  count: Int,
  acc: List(Int),
) -> List(Int) {
  case index >= count {
    True -> list.reverse(acc)
    False ->
      do_host_ports(port_base, port_stride, slot, index + 1, count, [
        host_port(port_base, port_stride, slot, index),
        ..acc
      ])
  }
}

import gleam/list

/// The fixed internal container port base.
pub const internal_port_base = 47_200
