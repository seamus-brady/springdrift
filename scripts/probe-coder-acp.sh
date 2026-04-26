#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Springdrift — probe OpenCode ACP (Agent Client Protocol) end-to-end.
#
# Boots the coder image, runs `opencode acp` over stdio, exchanges the
# protocol's three core messages — initialize, session/new (or
# whatever the agent's session-creation method is), session/prompt —
# and captures every JSON-RPC line to /tmp/acp-probe-<ts>.jsonl.
#
# Output drives the architectural decision: if ACP works cleanly here,
# we replace the REST/SSE coder client with an ACP client. If it
# doesn't, we know to stay on REST.
#
# Usage:
#   scripts/probe-coder-acp.sh
#
# Costs the same as one e2e run (~$0.001 at Anthropic prices) since
# the prompt does an actual model call.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/setup/lib/common.sh"

IMAGE="${SPRINGDRIFT_CODER_IMAGE:-springdrift-coder:latest}"
CONTAINER="springdrift-coder-acp-probe-$$"
TS=$(date +%Y%m%d-%H%M%S)
TRANSCRIPT="/tmp/acp-probe-$TS.jsonl"
STDERR_LOG="/tmp/acp-probe-$TS.stderr"

if ! command -v podman > /dev/null 2>&1; then fail "podman not installed."; fi
if ! command -v python3 > /dev/null 2>&1; then fail "python3 not installed."; fi
if ! command -v jq > /dev/null 2>&1; then warn "jq not installed; transcript will be ugly."; fi

# ── .env ────────────────────────────────────────────────────────────────────

if [[ ! -f "$PROJECT_ROOT/.env" ]]; then fail "$PROJECT_ROOT/.env not found."; fi
set -a
# shellcheck disable=SC1091
source "$PROJECT_ROOT/.env"
set +a
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  fail "ANTHROPIC_API_KEY not set in .env."
fi

# ── Pull config from .springdrift/config.toml ──────────────────────────────

CODER_TOML="$PROJECT_ROOT/.springdrift/config.toml"
PROVIDER_ID=$(awk -F'=' '/^[[:space:]]*provider_id[[:space:]]*=/ {gsub(/[" ]/, "", $2); print $2; exit}' "$CODER_TOML" 2>/dev/null)
MODEL_ID=$(awk -F'=' '/^[[:space:]]*model_id[[:space:]]*=/ {gsub(/[" ]/, "", $2); print $2; exit}' "$CODER_TOML" 2>/dev/null)
PROVIDER_ID="${PROVIDER_ID:-anthropic}"
MODEL_ID="${MODEL_ID:-claude-sonnet-4-20250514}"
ok "Coder model: $PROVIDER_ID / $MODEL_ID"

# ── Pre-flight ──────────────────────────────────────────────────────────────

if ! podman image exists "$IMAGE" 2>/dev/null; then
  fail "$IMAGE not found. Run scripts/build-coder-image.sh first."
fi
ok "Image $IMAGE present"

# ── Cleanup ─────────────────────────────────────────────────────────────────

cleanup() {
  if podman container exists "$CONTAINER" 2>/dev/null; then
    podman rm -f "$CONTAINER" > /dev/null 2>&1 || true
  fi
  rm -f "/tmp/acp-probe-auth-$$.json"
}
trap cleanup EXIT INT TERM

# ── Boot container ──────────────────────────────────────────────────────────

ok "Booting container..."
podman run -d --rm \
  --name "$CONTAINER" \
  --security-opt no-new-privileges \
  --userns=keep-id \
  -e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" \
  "$IMAGE" sleep infinity > /dev/null

# Auth setup (matches the smoke + e2e pattern)
echo '{"anthropic":{"type":"api","key":"'"$ANTHROPIC_API_KEY"'"}}' \
  > "/tmp/acp-probe-auth-$$.json"
podman exec "$CONTAINER" mkdir -p /root/.config/opencode
podman cp "/tmp/acp-probe-auth-$$.json" \
  "$CONTAINER":/root/.config/opencode/auth.json
ok "Auth installed"

# ── Hand off to Python helper ───────────────────────────────────────────────

ok "Starting opencode acp probe..."
echo ""

python3 "$SCRIPT_DIR/probe-coder-acp.py" \
  "$CONTAINER" "$PROVIDER_ID" "$MODEL_ID" "$TRANSCRIPT" "$STDERR_LOG"
EXIT=$?

echo ""
echo "Transcript: $TRANSCRIPT"
echo "Stderr:     $STDERR_LOG"
exit $EXIT
