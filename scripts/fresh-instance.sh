#!/usr/bin/env bash
# Launch a completely fresh Springdrift instance from /tmp.
#
# - Seeds a brand-new .springdrift/ data directory from
#   .springdrift_example/ (the in-repo template) under a timestamped
#   /tmp path.
# - Loads API keys from the repo's .env file so the instance can call
#   real providers.
# - Points Springdrift at the temp data dir via SPRINGDRIFT_DATA_DIR.
# - Does NOT touch the live .springdrift/ or the .springdrift_example/
#   reference. A fresh agent UUID is generated on first run.
#
# Usage:
#   scripts/fresh-instance.sh [--provider NAME] [--isolate-home] [--web]
#                             [--diagnostic] [-- extra gleam args]
#
# Flags:
#   --provider NAME Provider to use (anthropic, openai, mistral, vertex,
#                   openrouter, local, mock). Default: anthropic. The
#                   shipped .springdrift_example/config.toml uses the
#                   mock provider, which is why a stock copy answers
#                   with canned text — this flag rewrites the provider
#                   line in the copied config before launch.
#   --isolate-home  Also redirect HOME so ~/.config/springdrift cannot
#                   leak user-level config into the fresh instance.
#                   Triggers a one-time Gleam cache rebuild. Off by
#                   default.
#   --web           Launch the web GUI instead of the TUI (passes
#                   `--gui web` through to gleam run).
#   --diagnostic    Launch in web mode, wait for /health, fetch
#                   /diagnostic, pretty-print, then shut the instance
#                   down. Exit 0 if status=ok, 1 if degraded, 2 on
#                   timeout or fetch failure. Intended for offline
#                   validation — does not block waiting for operator
#                   input.
#
# Anything after `--` is forwarded to `gleam run --`.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$PROJECT_ROOT/.env" ]]; then
  echo "Error: $PROJECT_ROOT/.env not found." >&2
  exit 1
fi
if [[ ! -d "$PROJECT_ROOT/.springdrift_example" ]]; then
  echo "Error: $PROJECT_ROOT/.springdrift_example not found." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------

PROVIDER="anthropic"
ISOLATE_HOME=0
WEB_GUI=0
DIAGNOSTIC=0
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)     PROVIDER="$2"; shift 2 ;;
    --isolate-home) ISOLATE_HOME=1; shift ;;
    --web)          WEB_GUI=1; shift ;;
    --diagnostic)   DIAGNOSTIC=1; WEB_GUI=1; shift ;;
    --)             shift; EXTRA_ARGS=("$@"); break ;;
    -h|--help)
      awk 'NR==1 {next} /^[^#]/ && !/^$/ {exit} {sub(/^# ?/, ""); print}' "$0"
      exit 0
      ;;
    *)
      echo "Unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Seed the temp instance
# ---------------------------------------------------------------------------

TS=$(date +%Y%m%d-%H%M%S)
FRESH_ROOT="/tmp/springdrift-fresh-$TS"
DATA_DIR="$FRESH_ROOT/.springdrift"
FAKE_HOME="$FRESH_ROOT/home"

mkdir -p "$FRESH_ROOT"
cp -R "$PROJECT_ROOT/.springdrift_example" "$DATA_DIR"

# Anything that could tie the fresh instance to the live agent gets
# scrubbed. identity.json is regenerated on first run; session.json
# and logs are ephemeral by definition.
rm -f "$DATA_DIR/identity.json" "$DATA_DIR/session.json"
rm -rf "$DATA_DIR/logs"
find "$DATA_DIR/memory" -type f -name '*.jsonl' -delete 2>/dev/null || true

# The shipped example config uses provider="mock" — rewrite to the
# requested provider in the temp copy so the instance calls real LLMs.
# (Only the copy under $DATA_DIR is touched; .springdrift_example is
# read-only.)
if grep -q '^provider = ' "$DATA_DIR/config.toml"; then
  # BSD sed (macOS) and GNU sed both accept -i'' with an empty suffix.
  sed -i.bak -E "s|^provider = .*|provider = \"$PROVIDER\"|" \
    "$DATA_DIR/config.toml"
  rm -f "$DATA_DIR/config.toml.bak"
fi

if [[ "$ISOLATE_HOME" -eq 1 ]]; then
  mkdir -p "$FAKE_HOME/.config"
fi

# ---------------------------------------------------------------------------
# Load .env (API keys) into the current shell
# ---------------------------------------------------------------------------

set -a
# shellcheck disable=SC1091
source "$PROJECT_ROOT/.env"
set +a

# Warn early if the provider the user picked has no key in .env. The
# agent would otherwise launch fine and fail on the first cycle.
case "$PROVIDER" in
  anthropic)  REQUIRED_KEY="ANTHROPIC_API_KEY" ;;
  openai)     REQUIRED_KEY="OPENAI_API_KEY" ;;
  openrouter) REQUIRED_KEY="OPENROUTER_API_KEY" ;;
  mistral)    REQUIRED_KEY="MISTRAL_API_KEY" ;;
  vertex)     REQUIRED_KEY="VERTEX_AI_TOKEN" ;;
  mock|local) REQUIRED_KEY="" ;;
  *)          REQUIRED_KEY="" ;;
esac
if [[ -n "$REQUIRED_KEY" && -z "${!REQUIRED_KEY:-}" ]]; then
  echo "Error: provider '$PROVIDER' needs $REQUIRED_KEY, not set in $PROJECT_ROOT/.env" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Export runtime overrides
# ---------------------------------------------------------------------------

export SPRINGDRIFT_DATA_DIR="$DATA_DIR"
if [[ "$ISOLATE_HOME" -eq 1 ]]; then
  export HOME="$FAKE_HOME"
fi

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------

GLEAM_ARGS=()
if [[ "$WEB_GUI" -eq 1 ]]; then
  GLEAM_ARGS+=("--gui" "web")
fi
GLEAM_ARGS+=("${EXTRA_ARGS[@]:-}")

cat <<EOF
Fresh Springdrift instance
  data dir  : $SPRINGDRIFT_DATA_DIR
  HOME      : $HOME
  provider  : $PROVIDER
  gleam args: ${GLEAM_ARGS[*]:-<none>}

Nothing under $PROJECT_ROOT/.springdrift or $PROJECT_ROOT/.springdrift_example
has been modified. Delete $FRESH_ROOT when you're done with it.

EOF

cd "$PROJECT_ROOT"

# ---------------------------------------------------------------------------
# Diagnostic path: launch in background, probe, tear down
# ---------------------------------------------------------------------------

if [[ "$DIAGNOSTIC" -eq 1 ]]; then
  # Find the configured web port. The example config doesn't uncomment
  # [web].port, so the default is what matters — keep in sync with
  # src/config.gleam's default of 12001.
  PORT=$(awk -F'= ' '/^port = [0-9]+/ {print $2; exit}' \
    "$DATA_DIR/config.toml" 2>/dev/null || echo "")
  PORT=${PORT:-12001}

  TOKEN_QS=""
  if [[ -n "${SPRINGDRIFT_WEB_TOKEN:-}" ]]; then
    TOKEN_QS="?token=$SPRINGDRIFT_WEB_TOKEN"
  fi

  DIAG_LOG="$FRESH_ROOT/diagnostic.log"
  # Job control so the background gleam run gets its own process group —
  # the `gleam` CLI spawns erl/beam.smp as children, and without a group
  # we end up orphaning beam.smp when we kill the wrapper on cleanup.
  set -m
  gleam run -- "${GLEAM_ARGS[@]}" > "$DIAG_LOG" 2>&1 &
  GLEAM_PID=$!
  GLEAM_PGID=$(ps -o pgid= "$GLEAM_PID" | tr -d ' ' || echo "$GLEAM_PID")
  cleanup_diagnostic() {
    # TERM the whole group, give it a second, then SIGKILL any
    # stragglers. beam.smp ignores SIGHUP; SIGTERM is cleaner.
    kill -TERM -"$GLEAM_PGID" 2>/dev/null || true
    sleep 1
    kill -KILL -"$GLEAM_PGID" 2>/dev/null || true
  }
  trap cleanup_diagnostic EXIT INT TERM

  echo "Diagnostic: waiting for http://localhost:$PORT/health (up to 60s)..."
  READY=0
  for _ in $(seq 1 60); do
    if curl -s -f "http://localhost:$PORT/health" > /dev/null 2>&1; then
      READY=1
      break
    fi
    sleep 1
  done

  if [[ "$READY" -eq 0 ]]; then
    echo "Diagnostic: instance did not become healthy within 60s" >&2
    echo "Last 30 lines of log:" >&2
    tail -30 "$DIAG_LOG" >&2
    exit 2
  fi

  echo "Diagnostic: instance ready, fetching /diagnostic"
  DIAG_BODY=$(curl -s -f "http://localhost:$PORT/diagnostic$TOKEN_QS" 2>/dev/null || echo "")

  if [[ -z "$DIAG_BODY" ]]; then
    echo "Diagnostic: /diagnostic fetch failed" >&2
    tail -20 "$DIAG_LOG" >&2
    exit 2
  fi

  if command -v jq > /dev/null 2>&1; then
    echo "$DIAG_BODY" | jq .
  else
    echo "$DIAG_BODY"
  fi

  # Overall status: ok | degraded
  STATUS=$(echo "$DIAG_BODY" | sed -nE 's/.*"status":"([^"]+)".*/\1/p' | head -1)
  case "$STATUS" in
    ok)       echo "Diagnostic: overall status = ok"; exit 0 ;;
    degraded) echo "Diagnostic: overall status = degraded" >&2; exit 1 ;;
    *)        echo "Diagnostic: could not parse status" >&2; exit 2 ;;
  esac
fi

exec gleam run -- "${GLEAM_ARGS[@]}"
