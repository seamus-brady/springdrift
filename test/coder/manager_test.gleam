// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import coder/manager
import gleeunit/should

// ── sweep_stale_coder_containers: zero-match safety ────────────────────────
//
// In CI / dev environments podman may not be present, or no
// springdrift-coder-* containers exist. The sweep helper must return
// 0 (not crash) so manager startup doesn't depend on host state.
// This is the load-bearing safety property — without it, every
// startup on a fresh machine would fail.

pub fn sweep_no_match_returns_zero_test() {
  manager.sweep_stale_coder_containers("springdrift-coder-nomatch-xyz")
  |> should.equal(0)
}

pub fn sweep_empty_prefix_safe_test() {
  // Even with a weird prefix the helper must not panic.
  let _ = manager.sweep_stale_coder_containers("definitely-not-a-real-prefix")
  Nil
}
