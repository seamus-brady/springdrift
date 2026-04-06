//// Pure startup diagnostic functions for the Podman sandbox.
////
//// These check prerequisites before attempting to create containers.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/int
import gleam/string
import sandbox/podman_ffi

/// Check that podman is installed and return its version string.
pub fn check_podman() -> Result(String, String) {
  case podman_ffi.which("podman") {
    Error(_) ->
      Error(
        "podman not found on PATH. Install podman: https://podman.io/getting-started/installation",
      )
    Ok(_path) ->
      case podman_ffi.run_cmd("podman", ["--version"], 10_000) {
        Ok(result) ->
          case result.exit_code {
            0 -> Ok(string.trim(result.stdout))
            _ -> Error("podman --version failed: " <> result.stderr)
          }
        Error(msg) -> Error("Failed to run podman: " <> msg)
      }
  }
}

/// Check podman machine status (macOS only). Returns Ok if running or not needed.
pub fn check_machine_status() -> Result(String, String) {
  case is_macos() {
    False -> Ok("not macOS — no machine needed")
    True ->
      case podman_ffi.run_cmd("podman", ["machine", "info"], 10_000) {
        Ok(result) ->
          case result.exit_code {
            0 -> Ok("machine available")
            _ -> Error("podman machine not available: " <> result.stderr)
          }
        Error(msg) -> Error("Failed to check podman machine: " <> msg)
      }
  }
}

/// Start podman machine if not running (macOS only).
pub fn start_machine() -> Result(Nil, String) {
  case is_macos() {
    False -> Ok(Nil)
    True ->
      case podman_ffi.run_cmd("podman", ["machine", "start"], 120_000) {
        Ok(result) ->
          case result.exit_code {
            0 -> Ok(Nil)
            _ -> Error("podman machine start failed: " <> result.stderr)
          }
        Error(msg) -> Error("Failed to start podman machine: " <> msg)
      }
  }
}

/// Check if a container image exists locally.
pub fn check_image(name: String) -> Result(Nil, String) {
  case podman_ffi.run_cmd("podman", ["image", "exists", name], 10_000) {
    Ok(result) ->
      case result.exit_code {
        0 -> Ok(Nil)
        _ -> Error("Image not found: " <> name)
      }
    Error(msg) -> Error("Failed to check image: " <> msg)
  }
}

/// Pull a container image.
pub fn pull_image(name: String, timeout_ms: Int) -> Result(Nil, String) {
  case podman_ffi.run_cmd("podman", ["pull", name], timeout_ms) {
    Ok(result) ->
      case result.exit_code {
        0 -> Ok(Nil)
        _ -> Error("Failed to pull image " <> name <> ": " <> result.stderr)
      }
    Error(msg) -> Error("Failed to pull image: " <> msg)
  }
}

/// Remove stale springdrift sandbox containers.
pub fn sweep_stale_containers() -> Int {
  case
    podman_ffi.run_cmd(
      "podman",
      [
        "ps", "-a", "--filter", "name=springdrift-sandbox-", "--format",
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

import gleam/list

/// Check if running on macOS by looking at uname.
fn is_macos() -> Bool {
  case podman_ffi.run_cmd("uname", [], 5000) {
    Ok(result) -> string.contains(result.stdout, "Darwin")
    Error(_) -> False
  }
}

/// Build the port mapping arguments for podman run.
pub fn port_mapping_args(
  port_base: Int,
  port_stride: Int,
  ports_per_slot: Int,
  slot: Int,
  internal_port_base: Int,
) -> List(String) {
  do_port_args(
    port_base,
    port_stride,
    slot,
    internal_port_base,
    0,
    ports_per_slot,
    [],
  )
}

fn do_port_args(
  port_base: Int,
  port_stride: Int,
  slot: Int,
  internal_base: Int,
  index: Int,
  count: Int,
  acc: List(String),
) -> List(String) {
  case index >= count {
    True -> list.reverse(acc)
    False -> {
      let host = port_base + slot * port_stride + index
      let container = internal_base + index
      let mapping = int.to_string(host) <> ":" <> int.to_string(container)
      do_port_args(
        port_base,
        port_stride,
        slot,
        internal_base,
        index + 1,
        count,
        [mapping, "-p", ..acc],
      )
    }
  }
}
