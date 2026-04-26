//// Pure image-corruption detection and recovery actions for the
//// Podman sandbox.
////
//// Springdrift runs unattended on a VPS. When a container image
//// becomes corrupted (incomplete pull, registry transient that left
//// junk on disk, layer cache poison) every container creation fails
//// with the same image-related stderr. The manager would otherwise
//// loop forever or give up and ask a human — neither acceptable in
//// the unattended case.
////
//// `is_image_error` detects the symptom from podman stderr.
//// `recover_image` runs the fix: force-remove the local image and
//// re-pull. Both are deliberately small and pure-ish — the manager
//// owns the policy of when to apply them.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleam/string
import sandbox/podman_ffi

/// Substrings that podman emits to stderr when the image itself is
/// the problem (vs a transient runtime / config / resource issue).
/// Lower-cased; matched by substring against lower-cased stderr.
const image_error_markers = [
  "manifest unknown", "manifest invalid", "no such image", "image not known",
  "no such manifest", "blob unknown", "is corrupt", "corrupted",
  "layer not known", "layer not found", "unable to pull", "error pulling image",
  "error initializing image", "image store has been corrupted", "unknown image",
  "no such file or directory in storage", "could not find image",
]

/// Returns True when `stderr` looks like an image-corruption or
/// image-not-available problem rather than a runtime issue. Pure;
/// intended to be unit-tested directly.
pub fn is_image_error(stderr: String) -> Bool {
  let lower = string.lowercase(stderr)
  list.any(image_error_markers, fn(marker) { string.contains(lower, marker) })
}

/// Force-remove the local image then re-pull it. Used to recover from
/// a corrupted or partially-pulled local image.
///
/// `rmi` failure is intentionally ignored: the image may not exist on
/// disk yet. Pull failure is the real signal — propagated to the
/// caller so the manager can decide whether to retry or surface to
/// the operator.
pub fn recover_image(name: String, pull_timeout_ms: Int) -> Result(Nil, String) {
  let _ = podman_ffi.run_cmd("podman", ["rmi", "-f", name], 30_000)
  case podman_ffi.run_cmd("podman", ["pull", name], pull_timeout_ms) {
    Ok(result) ->
      case result.exit_code {
        0 -> Ok(Nil)
        _ -> Error("re-pull failed: " <> string.trim(result.stderr))
      }
    Error(msg) -> Error("re-pull failed: " <> msg)
  }
}
