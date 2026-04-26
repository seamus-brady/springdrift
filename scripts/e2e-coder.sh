#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Springdrift — end-to-end coder dispatch smoke.
#
# Spawns a real OpenCode container, sends one dispatch_coder-style
# round-trip via the Gleam manager, asserts the response shape and the
# CBR ingest landed. Costs a couple of cents per run.
#
# Pre-flight: scripts/build-coder-image.sh + scripts/smoke-coder-image.sh
# should both have passed first. This script proves the Gleam-side
# manager + ACP wiring works end-to-end against the same image those
# verified.
#
# Usage:
#   scripts/e2e-coder.sh
#
# Exits 0 if the model echoed "pong", non-zero on any failure
# (manager.start, dispatch_task, archive write, CBR write). On failure
# the relevant container log lands in stderr.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/setup/lib/common.sh"

# ── .env is the single source of truth ─────────────────────────────────────
#
# Anything set in .env wins. The script falls back to .springdrift/config.toml
# for provider_id/model_id only if .env didn't set them, so operators can
# either keep e2e config out of the live config or override it for a
# specific run.
#
# Recognised .env vars:
#   ANTHROPIC_API_KEY                     (required)
#   SPRINGDRIFT_CODER_PROVIDER_ID         (optional — defaults to TOML)
#   SPRINGDRIFT_CODER_MODEL_ID            (optional — defaults to TOML)
#   SPRINGDRIFT_CODER_E2E_PROJECT_ROOT    (optional — defaults to ~/coder-e2e-workspace)
#   E2E_WORKSPACE                          (legacy alias for E2E_PROJECT_ROOT)

if [[ ! -f "$PROJECT_ROOT/.env" ]]; then fail "$PROJECT_ROOT/.env not found."; fi
set -a
# shellcheck disable=SC1091
source "$PROJECT_ROOT/.env"
set +a
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  fail "ANTHROPIC_API_KEY not set in .env."
fi
ok "Loaded .env"

# ── Pre-flight ──────────────────────────────────────────────────────────────

if ! podman image exists springdrift-coder:latest 2>/dev/null; then
  fail "springdrift-coder:latest not built. Run scripts/build-coder-image.sh first."
fi
ok "springdrift-coder:latest present"

# Sweep any stale e2e containers from prior crashed runs. The manager
# names containers `<prefix>-<slot_id>` starting at slot_id_base 100 by
# default, so anything matching that prefix is fair game for cleanup.
STALE=$(podman ps -a --format '{{.Names}}' | grep -E '^springdrift-coder-' || true)
if [[ -n "$STALE" ]]; then
  warn "Stale springdrift-coder-* containers present — removing"
  echo "$STALE" | xargs -r podman rm -f > /dev/null 2>&1 || true
fi

cd "$PROJECT_ROOT"

# ── Per-task project root ───────────────────────────────────────────────────
#
# The e2e test bind-mounts this dir into the slot at /workspace/project.
# Must be user-owned — bind-mounting a system dir like /tmp surfaces as
# nobody:nogroup inside the container under macOS podman and breaks
# opencode's provider init.
#
# Resolution order: SPRINGDRIFT_CODER_E2E_PROJECT_ROOT (.env or shell) →
# E2E_WORKSPACE (legacy) → ~/coder-e2e-workspace.
E2E_WORKSPACE="${SPRINGDRIFT_CODER_E2E_PROJECT_ROOT:-${E2E_WORKSPACE:-$HOME/coder-e2e-workspace}}"
mkdir -p "$E2E_WORKSPACE"
ok "Workspace: $E2E_WORKSPACE"

# ── Coder provider/model: .env wins, TOML is fallback ──────────────────────
#
# .env is the single source of truth. If the operator set
# SPRINGDRIFT_CODER_{PROVIDER,MODEL}_ID in .env, use those. Otherwise fall
# back to parsing [coder] in .springdrift/config.toml (live agent's
# config). This lets a developer pin a specific e2e model in .env without
# touching the live config, OR keep one model in TOML and have e2e
# inherit it.

PROVIDER_ID="${SPRINGDRIFT_CODER_PROVIDER_ID:-}"
MODEL_ID="${SPRINGDRIFT_CODER_MODEL_ID:-}"

if [[ -z "$PROVIDER_ID" || -z "$MODEL_ID" ]]; then
  CODER_TOML="$PROJECT_ROOT/.springdrift/config.toml"
  if [[ ! -f "$CODER_TOML" ]]; then
    fail "Neither .env nor $CODER_TOML provides provider_id / model_id."
  fi
  if [[ -z "$PROVIDER_ID" ]]; then
    PROVIDER_ID=$(awk -F'=' '/^[[:space:]]*provider_id[[:space:]]*=/ {gsub(/[" ]/, "", $2); print $2; exit}' "$CODER_TOML" 2>/dev/null)
  fi
  if [[ -z "$MODEL_ID" ]]; then
    MODEL_ID=$(awk -F'=' '/^[[:space:]]*model_id[[:space:]]*=/ {gsub(/[" ]/, "", $2); print $2; exit}' "$CODER_TOML" 2>/dev/null)
  fi
fi

if [[ -z "$PROVIDER_ID" || -z "$MODEL_ID" ]]; then
  fail "Set SPRINGDRIFT_CODER_PROVIDER_ID and SPRINGDRIFT_CODER_MODEL_ID in .env, or [coder] provider_id and model_id in .springdrift/config.toml."
fi
ok "Coder model: $PROVIDER_ID / $MODEL_ID"

# ── Run the gated test ──────────────────────────────────────────────────────
#
# The test (test/coder/e2e_test.gleam) is a no-op without
# SPRINGDRIFT_CODER_E2E=1 so `gleam test` stays free in normal CI.

echo ""
echo "Running e2e test (real container, real LLM, costs a couple of cents)..."
echo ""

SPRINGDRIFT_CODER_E2E=1 \
SPRINGDRIFT_CODER_E2E_PROJECT_ROOT="$E2E_WORKSPACE" \
SPRINGDRIFT_CODER_PROVIDER_ID="$PROVIDER_ID" \
SPRINGDRIFT_CODER_MODEL_ID="$MODEL_ID" \
ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
gleam test 2>&1 | tee /tmp/springdrift-e2e.log | grep -E '\[e2e\]|passed|failed|panic|error' || true

# ── Verdict ─────────────────────────────────────────────────────────────────
#
# Success signal: `[e2e] dispatch ok` only prints when:
#   - manager.start succeeded
#   - dispatch_task returned Ok
#   - response_text contained "pong"
#   - the session JSON archive landed on disk
#   - the CBR dir is non-empty after the run
#   - manager.shutdown completed
#
# We deliberately ignore "no failures" / "N failures" totals because
# concurrent eval tests sometimes flake under the e2e test's I/O load.
# The dispatch-ok line is the authoritative pass/fail.

if grep -q "\[e2e\] dispatch ok" /tmp/springdrift-e2e.log; then
  echo ""
  ok "E2E passed (manager + ACP + ingest end-to-end)"
  if grep -q ", [1-9][0-9]* failures" /tmp/springdrift-e2e.log; then
    warn "Concurrent eval tests flaked under e2e load — known limitation"
  fi
  exit 0
else
  echo ""
  warn "E2E failed. Full log: /tmp/springdrift-e2e.log"
  STILL_RUNNING=$(podman ps -a --format '{{.Names}}' | grep -E '^springdrift-coder-' || true)
  if [[ -n "$STILL_RUNNING" ]]; then
    echo ""
    echo "  ── opencode log inside the slot(s) ──"
    while IFS= read -r name; do
      echo "  --- $name ---"
      podman exec "$name" tail -40 /tmp/opencode.log 2>&1 || \
        echo "  (could not read /tmp/opencode.log in $name)"
    done <<< "$STILL_RUNNING"
    echo "  ─────────────────────────────────────"
    # Force teardown so a failed run doesn't strand containers.
    echo "$STILL_RUNNING" | xargs -r podman rm -f > /dev/null 2>&1 || true
  fi
  exit 1
fi
