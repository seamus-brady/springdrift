// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleeunit/should
import sandbox/recovery

// ── is_image_error: positive cases ─────────────────────────────────────────
//
// These are real fragments of podman stderr. The detector has to recognise
// them so the manager triggers image recovery instead of leaving slots
// stuck Failed forever — the original VPS scenario the recovery exists for.

pub fn is_image_error_manifest_unknown_test() {
  recovery.is_image_error("Error: writing manifest: manifest unknown")
  |> should.be_true
}

pub fn is_image_error_no_such_image_test() {
  recovery.is_image_error("Error: no such image: python:3.12-slim")
  |> should.be_true
}

pub fn is_image_error_image_not_known_test() {
  recovery.is_image_error("Error: image not known: nonexistent")
  |> should.be_true
}

pub fn is_image_error_blob_unknown_test() {
  recovery.is_image_error("error pulling image: blob unknown")
  |> should.be_true
}

pub fn is_image_error_layer_corrupt_test() {
  recovery.is_image_error("layer xyz is corrupt")
  |> should.be_true
}

pub fn is_image_error_image_store_corrupted_test() {
  recovery.is_image_error("Error: image store has been corrupted")
  |> should.be_true
}

pub fn is_image_error_unable_to_pull_test() {
  recovery.is_image_error("unable to pull springdrift-coder:latest")
  |> should.be_true
}

pub fn is_image_error_case_insensitive_test() {
  // podman varies case across error paths; lower-cased match should
  // still fire.
  recovery.is_image_error("FATAL: Manifest Unknown")
  |> should.be_true
}

// ── is_image_error: negative cases ─────────────────────────────────────────
//
// These are real but unrelated podman failures — image recovery would be
// the wrong response. The detector must not match them.

pub fn is_image_error_runtime_oom_test() {
  recovery.is_image_error("Error: container exited with OOMKilled")
  |> should.be_false
}

pub fn is_image_error_port_in_use_test() {
  recovery.is_image_error(
    "Error: rootlessport listen tcp 0.0.0.0:10000: bind: address already in use",
  )
  |> should.be_false
}

pub fn is_image_error_network_test() {
  recovery.is_image_error(
    "Error: Unable to allocate IP address: ipam configuration error",
  )
  |> should.be_false
}

pub fn is_image_error_empty_test() {
  recovery.is_image_error("")
  |> should.be_false
}

pub fn is_image_error_permission_denied_test() {
  recovery.is_image_error("Error: open /etc/foo: permission denied")
  |> should.be_false
}
