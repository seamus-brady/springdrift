#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Minimal bash test harness
# ─────────────────────────────────────────────────────────────────────────────

_PASS=0
_FAIL=0
_TEST_NAME=""

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

it() {
  _TEST_NAME="$1"
}

assert_eq() {
  if [[ "$1" == "$2" ]]; then
    echo -e "  ${GREEN}✓${NC} $_TEST_NAME"
    _PASS=$((_PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $_TEST_NAME"
    echo "    expected: $2"
    echo "    got:      $1"
    _FAIL=$((_FAIL + 1))
  fi
}

assert_true() {
  if eval "$1"; then
    echo -e "  ${GREEN}✓${NC} $_TEST_NAME"
    _PASS=$((_PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $_TEST_NAME"
    echo "    expression was false: $1"
    _FAIL=$((_FAIL + 1))
  fi
}

assert_false() {
  if ! eval "$1"; then
    echo -e "  ${GREEN}✓${NC} $_TEST_NAME"
    _PASS=$((_PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $_TEST_NAME"
    echo "    expression was true (expected false): $1"
    _FAIL=$((_FAIL + 1))
  fi
}

assert_contains() {
  if echo "$1" | grep -q "$2"; then
    echo -e "  ${GREEN}✓${NC} $_TEST_NAME"
    _PASS=$((_PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $_TEST_NAME"
    echo "    string does not contain: $2"
    _FAIL=$((_FAIL + 1))
  fi
}

assert_not_contains() {
  if ! echo "$1" | grep -q "$2"; then
    echo -e "  ${GREEN}✓${NC} $_TEST_NAME"
    _PASS=$((_PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $_TEST_NAME"
    echo "    string unexpectedly contains: $2"
    _FAIL=$((_FAIL + 1))
  fi
}

assert_file_exists() {
  if [[ -f "$1" ]]; then
    echo -e "  ${GREEN}✓${NC} $_TEST_NAME"
    _PASS=$((_PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $_TEST_NAME"
    echo "    file not found: $1"
    _FAIL=$((_FAIL + 1))
  fi
}

boot_and_verify_http() {
  local port="${1:-12099}"
  local timeout="${2:-30}"
  local log_file="/tmp/springdrift-boot-test-$$.log"

  source .env 2>/dev/null || true
  unset SPRINGDRIFT_WEB_TOKEN

  # Disable CBR embeddings if Ollama isn't running (prevents startup panic)
  if ! curl -sf --max-time 2 "http://localhost:11434" > /dev/null 2>&1; then
    local cfg=".springdrift/config.toml"
    if grep -q "embedding_enabled" "$cfg" 2>/dev/null; then
      if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' 's/^.*embedding_enabled.*/embedding_enabled = false/' "$cfg"
      else
        sed -i 's/^.*embedding_enabled.*/embedding_enabled = false/' "$cfg"
      fi
    elif ! grep -q "embedding_enabled" "$cfg" 2>/dev/null; then
      if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' '/^\[cbr\]/a\
embedding_enabled = false' "$cfg"
      else
        sed -i '/^\[cbr\]/a\embedding_enabled = false' "$cfg"
      fi
    fi
  fi

  gleam run -- --gui web > "$log_file" 2>&1 &
  local app_pid=$!

  local ready=false
  local http_code=""
  for i in $(seq 1 "$timeout"); do
    if ! kill -0 "$app_pid" 2>/dev/null; then
      echo "  App exited prematurely. Log:"
      tail -20 "$log_file" 2>/dev/null || true
      rm -f "$log_file"
      it "app boots on port $port"
      assert_true 'false'
      return 1
    fi
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://localhost:${port}/chat" 2>/dev/null) || true
    if [[ "$http_code" =~ ^[0-9]+$ ]] && [[ "$http_code" -gt 0 ]]; then
      ready=true
      break
    fi
    sleep 1
  done

  if ! $ready; then
    echo "  App did not become ready within ${timeout}s. Log:"
    tail -20 "$log_file" 2>/dev/null || true
    kill "$app_pid" 2>/dev/null; wait "$app_pid" 2>/dev/null || true
    rm -f "$log_file"
    it "app serves HTTP on port $port"
    assert_true 'false'
    return 1
  fi

  it "app serves HTTP on port $port (status=$http_code)"
  assert_true '[[ "$http_code" == "200" || "$http_code" == "401" ]]'

  kill "$app_pid" 2>/dev/null
  wait "$app_pid" 2>/dev/null || true
  rm -f "$log_file"
  return 0
}

set_test_port() {
  local config_file="$1"
  local port="$2"
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "s/^# port = 12001/port = $port/" "$config_file"
  else
    sed -i "s/^# port = 12001/port = $port/" "$config_file"
  fi
}

report() {
  echo ""
  local total=$((_PASS + _FAIL))
  if [[ $_FAIL -eq 0 ]]; then
    echo -e "${GREEN}${total} passed, no failures${NC}"
  else
    echo -e "${RED}${_PASS} passed, ${_FAIL} failed${NC}"
  fi
  return $_FAIL
}
