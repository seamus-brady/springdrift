#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# macOS integration test — fresh install in /tmp, boot, verify HTTP
#
# Run standalone:
#   bash tests/setup/test_integration_macos.sh
#
# Or from the test runner:
#   bash tests/setup/run_tests.sh --integration
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/harness.sh"

WORK_DIR=$(mktemp -d /tmp/springdrift-test-XXXXXX)

cleanup_workdir() {
  local exit_code=$?
  rm -rf "$WORK_DIR"
  if [[ $exit_code -ne 0 ]]; then
    echo "  (cleaned up $WORK_DIR)"
  fi
}
trap cleanup_workdir EXIT

echo -e "${BOLD}macOS Integration: fresh install in $WORK_DIR${NC}"

# ── Copy repo to temp dir ────────────────────────────────────────────────────

echo "  Copying repo..."
rsync -a --exclude '.springdrift' --exclude '.env' --exclude '.sandbox-workspaces' \
  --exclude '.git' --exclude '_impl_docs' "$REPO_ROOT/" "$WORK_DIR/"
cd "$WORK_DIR"

it "repo copied to temp dir"
assert_file_exists "gleam.toml"

# ── Run setup ────────────────────────────────────────────────────────────────

echo "  Running setup-macos.sh..."

# Build canned input dynamically based on what's already installed.
# If Podman/Ollama are present, the script skips the ask_yn prompts.
INPUT_FILE=$(mktemp)
{
  command -v podman &>/dev/null || echo "n"   # Install Podman? [y/N]
  command -v ollama &>/dev/null || echo "n"   # Install Ollama? [y/N]
  echo "TestBot"                              # Agent name [Springdrift]
  echo "mock"                                 # Provider [anthropic]
  echo ""                                     # Brave Search API key
  echo ""                                     # Jina Reader API key
  echo "n"                                    # Enable email? [y/N]
  echo ""                                     # Git remote URL
} > "$INPUT_FILE"

bash scripts/setup-macos.sh < "$INPUT_FILE" 2>&1 || true
rm -f "$INPUT_FILE"

# ── Verify setup output ─────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Post-setup verification${NC}"

it ".springdrift/ directory was created"
assert_true '[[ -d ".springdrift" ]]'

it "config.toml was generated"
assert_file_exists ".springdrift/config.toml"

CONFIG=$(cat .springdrift/config.toml)

it "config has correct provider"
assert_contains "$CONFIG" 'provider = "mock"'

it "config has correct agent name"
assert_contains "$CONFIG" 'name = "TestBot"'

it "config uses port 12001 (not 8080)"
assert_not_contains "$CONFIG" '8080'

it ".env file was generated"
assert_file_exists ".env"

it ".env is sourceable"
(source .env) 2>/dev/null
assert_eq "$?" "0"

it ".springdrift/.git was initialised"
assert_true '[[ -d ".springdrift/.git" ]]'

it "gleam build succeeds"
gleam build 2>&1 | tail -1
assert_eq "$?" "0"

# ── Boot and verify HTTP ─────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Boot verification${NC}"

source .env 2>/dev/null || true
unset SPRINGDRIFT_WEB_TOKEN
it "gleam run --selftest passes"
SELFTEST_OUT=$(gleam run -- --selftest --provider mock 2>&1)
SELFTEST_EXIT=$?
if echo "$SELFTEST_OUT" | grep -q "PASS"; then
  _PASS=$((_PASS + 1))
  echo -e "  ${GREEN}✓${NC} $_TEST_NAME"
else
  _FAIL=$((_FAIL + 1))
  echo -e "  ${RED}✗${NC} $_TEST_NAME"
  echo "    exit code: $SELFTEST_EXIT"
  echo "    output: $(echo "$SELFTEST_OUT" | tail -5)"
fi

report
