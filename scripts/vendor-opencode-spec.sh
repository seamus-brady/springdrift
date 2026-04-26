#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Springdrift — vendor OpenCode's OpenAPI spec for the pinned version.
#
# OpenCode publishes its full HTTP schema at GET /doc. This script boots
# the coder image, fetches /doc, and saves it under docs/vendor/. The
# vendored spec is the source of truth for src/coder/client.gleam — we
# write code against the schema, not against guesses.
#
# Run after a version bump to refresh the vendored spec. The diff
# against the previous version tells us exactly what to update in the
# client.
#
# Usage:
#   scripts/vendor-opencode-spec.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/setup/lib/common.sh"

IMAGE="${SPRINGDRIFT_CODER_IMAGE:-springdrift-coder:latest}"
HOST_PORT="${VENDOR_HOST_PORT:-48702}"
CONTAINER_PORT=47200
CONTAINER_NAME="springdrift-coder-vendor-$$"
VENDOR_DIR="$PROJECT_ROOT/docs/vendor"

if ! command -v podman > /dev/null 2>&1; then fail "podman not installed."; fi
if ! command -v curl > /dev/null 2>&1; then fail "curl not installed."; fi
if ! command -v jq > /dev/null 2>&1; then
  warn "jq not installed — spec will be saved un-prettified."
fi

# ── .env for auth ───────────────────────────────────────────────────────────

if [[ ! -f "$PROJECT_ROOT/.env" ]]; then fail "$PROJECT_ROOT/.env not found."; fi
set -a
# shellcheck disable=SC1091
source "$PROJECT_ROOT/.env"
set +a
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  fail "ANTHROPIC_API_KEY not set in .env."
fi

if ! podman image exists "$IMAGE" 2>/dev/null; then
  fail "$IMAGE not found. Run scripts/build-coder-image.sh first."
fi

# ── Resolve OpenCode version from the image ─────────────────────────────────

VERSION=$(podman run --rm "$IMAGE" opencode --version 2>/dev/null | tr -d '[:space:]')
if [[ -z "$VERSION" ]]; then fail "Could not determine opencode version."; fi
ok "Vendoring spec for OpenCode $VERSION"

OUT="$VENDOR_DIR/opencode-$VERSION-openapi.json"
mkdir -p "$VENDOR_DIR"

# ── Cleanup ─────────────────────────────────────────────────────────────────

cleanup() {
  local exit_code=$?
  if podman container exists "$CONTAINER_NAME" 2>/dev/null; then
    podman rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

# ── Boot container ──────────────────────────────────────────────────────────

podman run -d --rm \
  --name "$CONTAINER_NAME" \
  -p "$HOST_PORT:$CONTAINER_PORT" \
  -e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" \
  "$IMAGE" sleep infinity > /dev/null

AUTH_JSON='{"anthropic":{"type":"api","key":"'$ANTHROPIC_API_KEY'"}}'
podman exec "$CONTAINER_NAME" bash -c \
  "mkdir -p /root/.config/opencode && cat > /root/.config/opencode/auth.json <<'EOF'
$AUTH_JSON
EOF" > /dev/null

podman exec -d "$CONTAINER_NAME" bash -c \
  "opencode serve --hostname 0.0.0.0 --port $CONTAINER_PORT > /tmp/opencode.log 2>&1"

# ── Wait for /app to answer ─────────────────────────────────────────────────

ELAPSED=0
READY=0
while [[ $ELAPSED -lt 30 ]]; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 \
    "http://localhost:$HOST_PORT/app" 2>/dev/null) || STATUS="000"
  if [[ "$STATUS" == "200" ]]; then
    READY=1
    break
  fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done

if [[ $READY -eq 0 ]]; then
  echo "Server didn't become ready. Log:"
  podman exec "$CONTAINER_NAME" tail -30 /tmp/opencode.log 2>&1
  fail "Aborted."
fi

# ── Fetch /doc ──────────────────────────────────────────────────────────────

if command -v jq > /dev/null 2>&1; then
  curl -sf "http://localhost:$HOST_PORT/doc" | jq . > "$OUT"
else
  curl -sf "http://localhost:$HOST_PORT/doc" > "$OUT"
fi

if [[ ! -s "$OUT" ]]; then fail "Spec fetch failed — output empty."; fi

ok "Vendored to $OUT"
echo ""
echo "Quick stats:"
echo "  paths:      $(jq '.paths | keys | length' "$OUT" 2>/dev/null || echo "?")"
echo "  components: $(jq '.components.schemas | keys | length' "$OUT" 2>/dev/null || echo "?")"
echo "  size:       $(wc -c < "$OUT" | tr -d ' ') bytes"
