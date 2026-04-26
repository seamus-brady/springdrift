#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Springdrift — discover OpenCode HTTP endpoints.
#
# The Phase 2 client (src/coder/client.gleam) needs to talk to a real API
# surface, not a guessed one. This script boots a coder container, probes
# a list of candidate paths, and reports status + a snippet of body for
# each. The output is the source of truth for the client's endpoint set
# until OpenCode publishes a stable OpenAPI spec we can vendor.
#
# Also serves as a contract-detector for version bumps: if the next
# pinned OpenCode version returns different statuses for these paths,
# the discovery output diff tells us exactly what broke.
#
# Usage:
#   scripts/discover-coder-endpoints.sh
#   scripts/discover-coder-endpoints.sh > endpoints.txt    # save for diff
#
# Reuses the same .env-driven auth path as smoke-coder-image.sh.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/setup/lib/common.sh"

IMAGE="${SPRINGDRIFT_CODER_IMAGE:-springdrift-coder:latest}"
HOST_PORT="${DISCOVER_HOST_PORT:-48701}"
CONTAINER_PORT=47200
CONTAINER_NAME="springdrift-coder-discover-$$"
READY_TIMEOUT_S=30

if ! command -v podman > /dev/null 2>&1; then fail "podman not installed."; fi
if ! command -v curl > /dev/null 2>&1; then fail "curl not installed."; fi

# ── Source .env ─────────────────────────────────────────────────────────────

if [[ ! -f "$PROJECT_ROOT/.env" ]]; then
  fail "$PROJECT_ROOT/.env not found."
fi
set -a
# shellcheck disable=SC1091
source "$PROJECT_ROOT/.env"
set +a
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  fail "ANTHROPIC_API_KEY not set in .env."
fi

# ── Image must exist ────────────────────────────────────────────────────────

if ! podman image exists "$IMAGE" 2>/dev/null; then
  fail "$IMAGE not found. Run scripts/build-coder-image.sh first."
fi

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

echo "Booting $IMAGE on host port $HOST_PORT..."
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
  "opencode serve --hostname 0.0.0.0 --port $CONTAINER_PORT --print-logs --log-level INFO > /tmp/opencode.log 2>&1"

# ── Wait for any HTTP response ──────────────────────────────────────────────

ELAPSED=0
READY=0
while [[ $ELAPSED -lt $READY_TIMEOUT_S ]]; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 \
    "http://localhost:$HOST_PORT/" 2>/dev/null) || STATUS="000"
  if [[ "$STATUS" =~ ^[1-5][0-9][0-9]$ ]]; then
    READY=1
    break
  fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done

if [[ $READY -eq 0 ]]; then
  echo "Server did not bind. Log tail:"
  podman exec "$CONTAINER_NAME" tail -40 /tmp/opencode.log 2>&1
  fail "Discovery aborted."
fi

# ── Probe endpoints ─────────────────────────────────────────────────────────

probe() {
  local method="$1"
  local path="$2"
  local body="${3:-}"

  local url="http://localhost:$HOST_PORT$path"
  local out

  if [[ "$method" == "GET" ]]; then
    out=$(curl -s -o /tmp/discover.body -w "%{http_code}|%{content_type}" \
      --max-time 3 "$url" 2>/dev/null) || out="000|"
  else
    out=$(curl -s -o /tmp/discover.body -w "%{http_code}|%{content_type}" \
      --max-time 3 -X "$method" \
      -H "Content-Type: application/json" \
      ${body:+-d "$body"} \
      "$url" 2>/dev/null) || out="000|"
  fi

  local status="${out%%|*}"
  local ctype="${out##*|}"
  local snippet
  snippet=$(head -c 200 /tmp/discover.body 2>/dev/null | tr -d '\n' | tr -d '\r' || echo "")
  printf "%-6s %-30s  %s  %-30s  %s\n" \
    "$method" "$path" "$status" "${ctype:-?}" "${snippet:0:120}"
}

# Cleanup body file in container after we read it from the host (host-side
# discovery uses /tmp/discover.body on the host; container's /tmp untouched).
rm -f /tmp/discover.body

echo ""
echo "─── ENDPOINT DISCOVERY: OpenCode $(podman exec "$CONTAINER_NAME" opencode --version 2>/dev/null) ───"
printf "%-6s %-30s  %s  %-30s  %s\n" "METHOD" "PATH" "STATUS" "CONTENT-TYPE" "BODY (first 120c)"
printf "%-6s %-30s  %s  %-30s  %s\n" "------" "----" "------" "------------" "-------"

# OpenAPI / docs
probe GET /
probe GET /doc
probe GET /docs
probe GET /openapi
probe GET /openapi.json
probe GET /api
probe GET /api/v1
probe GET /api/openapi.json
probe GET /swagger
probe GET /spec

# Health-style
probe GET /health
probe GET /healthz
probe GET /ready
probe GET /status
probe GET /version

# OpenCode-likely (per the spec the user shared)
probe GET /session
probe GET /sessions
probe GET /config
probe GET /config/providers
probe GET /provider
probe GET /providers
probe GET /agent
probe GET /agents
probe GET /mode
probe GET /event
probe GET /events
probe GET /todo
probe GET /file
probe GET /files
probe GET /find
probe GET /log
probe GET /app

# POST candidates (empty body — server should reject with 400/422 if the
# endpoint exists, 404 if it doesn't)
probe POST /session
probe POST /sessions

echo "──────────────────────────────────────────────────────────────────────"
echo ""
echo "Tail of opencode log (first 30 lines, for context):"
podman exec "$CONTAINER_NAME" head -30 /tmp/opencode.log 2>&1 || true
