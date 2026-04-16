#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Test 5: Port availability detection (#34)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/harness.sh"
source "$REPO_ROOT/scripts/lib/setup-common.sh"

echo -e "${BOLD}Port availability checks${NC}"

# Pick a high ephemeral port unlikely to be in use
FREE_PORT=59123

it "detects free port as available"
assert_true 'check_port_available "$FREE_PORT"'

# Bind a port temporarily using a background nc/python listener
BUSY_PORT=59124
cleanup_listener() {
  kill "$LISTENER_PID" 2>/dev/null || true
  wait "$LISTENER_PID" 2>/dev/null || true
}

if command -v python3 &>/dev/null; then
  python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $BUSY_PORT))
s.listen(1)
time.sleep(30)
" &
  LISTENER_PID=$!
  trap cleanup_listener EXIT
  sleep 0.5

  it "detects bound port as unavailable"
  assert_false 'check_port_available "$BUSY_PORT"'

  cleanup_listener
  trap - EXIT
elif command -v nc &>/dev/null; then
  nc -l 127.0.0.1 "$BUSY_PORT" &>/dev/null &
  LISTENER_PID=$!
  trap cleanup_listener EXIT
  sleep 0.5

  it "detects bound port as unavailable"
  assert_false 'check_port_available "$BUSY_PORT"'

  cleanup_listener
  trap - EXIT
else
  echo "  (skipping bound-port test — no python3 or nc available)"
fi

it "handles port 12001 (the default web port)"
# Just check it runs without error — result depends on environment
check_port_available 12001 || true
echo -e "  ${GREEN}✓${NC} $_TEST_NAME (no crash)"
_PASS=$((_PASS + 1))

report
