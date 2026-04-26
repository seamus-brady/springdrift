#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Springdrift — smoke-test the coder sandbox image.
#
# This is the hard gate that proves the pinned OpenCode version actually
# works headless inside the container. Per the pin-and-lag policy
# (docs/roadmap/planned/real-coder-opencode.md §Risk Mitigations), no
# version is "usable" until this script passes against it.
#
# OpenCode refuses to serve when no provider is configured, so we wire
# auth in from .env (ANTHROPIC_API_KEY at minimum). Operator does not
# need to run `opencode auth login` — the keys are sourced from the same
# .env that the rest of Springdrift reads.
#
# What it does:
#   1. Sources .env from project root; requires ANTHROPIC_API_KEY.
#   2. Confirms springdrift-coder:latest exists.
#   3. Starts a throwaway container running `sleep infinity` with the
#      provider keys passed in as env vars and a writable opencode auth
#      dir backed by an anonymous volume.
#   4. Writes /root/.config/opencode/auth.json from the env keys.
#   5. `podman exec`s `opencode serve` headless on a high port.
#   6. Probes a few candidate endpoints — accepts any HTTP response as
#      "server is alive" since 0.4.7's exact /health shape is upstream-
#      version-dependent.
#   7. Tears down the container regardless of outcome.
#
# Usage:
#   scripts/smoke-coder-image.sh
#
# Exits 0 on healthy, 1 on failure. No state left behind.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/setup/lib/common.sh"

IMAGE="${SPRINGDRIFT_CODER_IMAGE:-springdrift-coder:latest}"
# Use a port well outside Springdrift's allocated range (47200-47999) so
# we don't collide with a running instance. 48700 is unassigned in the
# IANA registry and clear of common dev ports.
HOST_PORT="${SMOKE_HOST_PORT:-48700}"
CONTAINER_PORT=47200
CONTAINER_NAME="springdrift-coder-smoke-$$"
HEALTH_TIMEOUT_S=30

if ! command -v podman > /dev/null 2>&1; then
  fail "podman not installed."
fi

if ! command -v curl > /dev/null 2>&1; then
  fail "curl not installed (needed to probe /health)."
fi

# ── Source .env for provider keys ───────────────────────────────────────────
#
# OpenCode 0.4.7's `serve` exits ~123ms after start if no provider is
# configured. We source the same .env that fresh-instance.sh and the
# rest of Springdrift use, then pass keys through. This keeps the smoke
# test consistent with what Phase 2's actual coder supervisor will do.

if [[ -f "$PROJECT_ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$PROJECT_ROOT/.env"
  set +a
  ok "Loaded provider keys from .env"
else
  fail "$PROJECT_ROOT/.env not found. Add ANTHROPIC_API_KEY to it before running this smoke test."
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  fail "ANTHROPIC_API_KEY not set in .env. OpenCode needs at least one provider to serve."
fi

# ── Pre-flight: image must exist ────────────────────────────────────────────

if ! podman image exists "$IMAGE" 2>/dev/null; then
  fail "$IMAGE not found. Run scripts/build-coder-image.sh first."
fi
ok "Image $IMAGE present"

# ── Cleanup hook fires regardless of how we exit ────────────────────────────

cleanup() {
  local exit_code=$?
  if podman container exists "$CONTAINER_NAME" 2>/dev/null; then
    podman rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

# ── Start container ─────────────────────────────────────────────────────────
#
# Provider env vars: OpenCode reads ANTHROPIC_API_KEY (and the other
# provider-specific names) directly from env in addition to auth.json.
# We pass them in via -e and ALSO write an auth.json from inside the
# container — belt and suspenders. If only the env path works, the
# auth.json is harmless. If only the auth.json path works, the env vars
# are harmless.

echo "Starting container $CONTAINER_NAME on host port $HOST_PORT..."

PODMAN_RUN_ARGS=(
  -d --rm
  --name "$CONTAINER_NAME"
  -p "$HOST_PORT:$CONTAINER_PORT"
  -e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY"
)

# Optional secondary providers, only injected when present in .env.
for var in OPENAI_API_KEY OPENROUTER_API_KEY MISTRAL_API_KEY; do
  if [[ -n "${!var:-}" ]]; then
    PODMAN_RUN_ARGS+=(-e "$var=${!var}")
  fi
done

if ! podman run "${PODMAN_RUN_ARGS[@]}" "$IMAGE" sleep infinity > /dev/null; then
  fail "Failed to start container."
fi
ok "Container started"

# ── Write minimal auth.json from env keys ───────────────────────────────────
#
# Schema follows the format `opencode auth login` produces — provider
# keyed at the top level with {type: "api", key: "..."}. If 0.4.7 expects
# a different shape we'll see provider-init errors in the log.

echo "Writing opencode auth.json from env keys..."
AUTH_JSON='{"anthropic":{"type":"api","key":"'$ANTHROPIC_API_KEY'"}'
for var in OPENAI_API_KEY:openai OPENROUTER_API_KEY:openrouter MISTRAL_API_KEY:mistral; do
  env_var="${var%%:*}"
  provider="${var##*:}"
  if [[ -n "${!env_var:-}" ]]; then
    AUTH_JSON+=',"'$provider'":{"type":"api","key":"'${!env_var}'"}'
  fi
done
AUTH_JSON+='}'

if ! podman exec "$CONTAINER_NAME" bash -c \
      "mkdir -p /root/.config/opencode && cat > /root/.config/opencode/auth.json <<'EOF'
$AUTH_JSON
EOF"; then
  fail "Failed to write auth.json into the container."
fi
ok "auth.json written"

# ── Launch opencode serve inside the container ──────────────────────────────
#
# `opencode serve` runs in the foreground; we background it via podman
# exec -d so the smoke script returns to the polling loop. Logs go to
# /tmp/opencode.log inside the container so we can grab them on failure.
# --print-logs ensures startup events land in the log even if the daemon
# would otherwise silence them.

echo "Launching: opencode serve --hostname 0.0.0.0 --port $CONTAINER_PORT"
if ! podman exec -d "$CONTAINER_NAME" \
      bash -c "opencode serve --hostname 0.0.0.0 --port $CONTAINER_PORT --print-logs --log-level INFO > /tmp/opencode.log 2>&1"; then
  fail "Failed to launch opencode serve."
fi

# ── Probe several candidate endpoints ───────────────────────────────────────
#
# 0.4.7 may or may not expose /health specifically. Any 2xx/4xx response
# from any path proves the HTTP server is alive. Connection refused on
# all paths means the daemon is not listening.

CANDIDATES=("/health" "/" "/event" "/doc")

echo "Probing http://localhost:$HOST_PORT for up to ${HEALTH_TIMEOUT_S}s..."
ELAPSED=0
ALIVE_PATH=""
while [[ $ELAPSED -lt $HEALTH_TIMEOUT_S ]]; do
  for path in "${CANDIDATES[@]}"; do
    # -w "%{http_code}" always prints something (curl outputs "000" on
    # connection failure or timeout), so we don't add a shell fallback —
    # that would concatenate. We accept any valid HTTP status (1xx-5xx)
    # as "server is alive". 000 means the daemon isn't listening yet.
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 \
      "http://localhost:$HOST_PORT$path" 2>/dev/null) || STATUS="000"
    if [[ "$STATUS" =~ ^[1-5][0-9][0-9]$ ]]; then
      ALIVE_PATH="$path (HTTP $STATUS)"
      break 2
    fi
  done
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done

if [[ -z "$ALIVE_PATH" ]]; then
  echo ""
  warn "OpenCode did not respond on any candidate path within ${HEALTH_TIMEOUT_S}s."
  echo ""
  echo "  ── opencode log (last 60 lines) ──"
  podman exec "$CONTAINER_NAME" tail -60 /tmp/opencode.log 2>&1 || \
    echo "  (could not read /tmp/opencode.log)"
  echo "  ─────────────────────────────────"
  fail "Smoke test failed. Either the pinned version's serve mode crashed (see log) or the endpoint shape changed beyond the candidates probed."
fi

ok "OpenCode answered on $ALIVE_PATH (after $((ELAPSED + 1))s)"

echo ""
ok "Smoke test passed. $IMAGE is usable."
echo ""
echo "Pin this version in Containerfile.coder if you bumped it."
