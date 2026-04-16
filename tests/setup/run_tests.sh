#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Springdrift setup test runner
#
# Usage:
#   bash tests/setup/run_tests.sh               # Unit tests only (fast, no Docker)
#   bash tests/setup/run_tests.sh --integration  # Include Docker integration test
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_SUITES=()

run_suite() {
  local name="$1"
  local script="$2"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${BOLD}$name${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if bash "$script"; then
    return 0
  else
    FAILED_SUITES+=("$name")
    return 1
  fi
}

cd "$REPO_ROOT"

echo ""
echo -e "${BOLD}Springdrift Setup Tests${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Unit tests (always run)
run_suite "1. Preflight checks"     "tests/setup/test_preflight.sh"     || true
run_suite "2. Gleam version"        "tests/setup/test_gleam_version.sh" || true
run_suite "3. Config generation"    "tests/setup/test_config_gen.sh"    || true
run_suite "4. Env file generation"  "tests/setup/test_env_gen.sh"       || true
run_suite "5. Port check"           "tests/setup/test_port_check.sh"    || true

# Integration tests (opt-in)
if [[ "${1:-}" == "--integration" ]]; then

  # macOS integration test (native, runs in /tmp)
  if [[ "$(uname)" == "Darwin" ]]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${BOLD}6. macOS integration test (native)${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    run_suite "macOS Integration" "tests/setup/test_integration_macos.sh" || true
  fi

  # Linux integration test (Docker)
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${BOLD}7. Linux integration test (Docker)${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if command -v docker &>/dev/null && docker info &>/dev/null; then
    echo "  Building test container..."
    if docker build -f tests/setup/Dockerfile.integration -t springdrift-setup-test . -q; then
      echo "  Running integration test..."
      if docker run --rm springdrift-setup-test; then
        echo ""
      else
        FAILED_SUITES+=("Linux Integration")
      fi
    else
      echo -e "  ${RED}Docker build failed${NC}"
      FAILED_SUITES+=("Linux Integration (build)")
    fi
  else
    echo "  Docker not available — skipping Linux integration test"
    echo "  Start colima or Docker Desktop, then: bash tests/setup/run_tests.sh --integration"
  fi
fi

# Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ ${#FAILED_SUITES[@]} -eq 0 ]]; then
  echo -e "${GREEN}All test suites passed${NC}"
else
  echo -e "${RED}Failed suites: ${FAILED_SUITES[*]}${NC}"
  exit 1
fi
