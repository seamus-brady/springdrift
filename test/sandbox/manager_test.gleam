// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleeunit/should
import sandbox/diagnostics
import sandbox/podman_ffi
import sandbox/types

pub fn host_port_test() {
  // Slot 0, port index 0
  types.host_port(10_000, 100, 0, 0)
  |> should.equal(10_000)

  // Slot 0, port index 4
  types.host_port(10_000, 100, 0, 4)
  |> should.equal(10_004)

  // Slot 1, port index 0
  types.host_port(10_000, 100, 1, 0)
  |> should.equal(10_100)

  // Slot 2, port index 3
  types.host_port(10_000, 100, 2, 3)
  |> should.equal(10_203)
}

pub fn host_ports_for_slot_test() {
  let ports = types.host_ports_for_slot(10_000, 100, 5, 0)
  ports
  |> should.equal([10_000, 10_001, 10_002, 10_003, 10_004])

  let ports1 = types.host_ports_for_slot(10_000, 100, 5, 1)
  ports1
  |> should.equal([10_100, 10_101, 10_102, 10_103, 10_104])
}

pub fn host_ports_for_slot_custom_base_test() {
  let ports = types.host_ports_for_slot(20_000, 50, 3, 0)
  ports
  |> should.equal([20_000, 20_001, 20_002])
}

pub fn port_mapping_args_test() {
  let args =
    diagnostics.port_mapping_args(10_000, 100, 2, 0, types.internal_port_base)
  // Should produce ["-p", "10000:47200", "-p", "10001:47201"]
  args
  |> list.length
  |> should.equal(4)
}

pub fn which_ls_test() {
  // ls should exist on any UNIX system
  podman_ffi.which("ls")
  |> should.be_ok
}

pub fn which_nonexistent_test() {
  podman_ffi.which("nonexistent_binary_xyz_123")
  |> should.be_error
}

pub fn run_cmd_echo_test() {
  case podman_ffi.run_cmd("/bin/echo", ["hello"], 5000) {
    Ok(result) -> {
      result.exit_code
      |> should.equal(0)

      result.stdout
      |> should.equal("hello\n")
    }
    Error(_) -> {
      // This should not happen on any UNIX system
      should.fail()
    }
  }
}

pub fn run_cmd_false_test() {
  case podman_ffi.run_cmd("/usr/bin/false", [], 5000) {
    Ok(result) -> {
      result.exit_code
      |> should.not_equal(0)
    }
    Error(_) -> {
      // May error on some systems, that's ok
      Nil
    }
  }
}

pub fn sandbox_config_construction_test() {
  let config =
    types.SandboxConfig(
      pool_size: 2,
      memory_mb: 512,
      cpus: "1",
      image: "python:3.12-slim",
      exec_timeout_ms: 60_000,
      port_base: 10_000,
      port_stride: 100,
      ports_per_slot: 5,
      auto_machine: True,
      workspace_dir: "/tmp/test-workspaces",
    )
  config.pool_size
  |> should.equal(2)
  config.port_base
  |> should.equal(10_000)
}

pub fn slot_status_test() {
  let slot =
    types.SandboxSlot(
      slot_id: 0,
      container_id: "abc123",
      status: types.Ready,
      workspace: "/tmp/ws/0",
      host_ports: [10_000, 10_001],
    )
  slot.slot_id
  |> should.equal(0)

  let busy_slot = types.SandboxSlot(..slot, status: types.Busy)
  case busy_slot.status {
    types.Busy -> Nil
    _ -> should.fail()
  }
}

pub fn exec_result_construction_test() {
  let result = types.ExecResult(exit_code: 0, stdout: "hello", stderr: "")
  result.exit_code
  |> should.equal(0)
  result.stdout
  |> should.equal("hello")
}

pub fn serve_result_construction_test() {
  let result =
    types.ServeResult(
      host_port: 10_000,
      container_port: 47_200,
      slot_id: 0,
      verification: "VERIFIED status=200 preview=hello",
    )
  result.host_port
  |> should.equal(10_000)
  result.verification
  |> should.equal("VERIFIED status=200 preview=hello")
}
