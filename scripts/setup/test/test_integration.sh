#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Test 6+7: Full integration test (runs in Docker container)
# Simulates a real setup with canned answers piped to stdin.
#
# Run standalone:
#   docker build -f scripts/setup/test/Dockerfile.integration -t springdrift-setup-test .
#   docker run --rm springdrift-setup-test
#
# Or from the test runner:
#   bash scripts/setup/test/run_tests.sh --integration
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/harness.sh"

cd "$REPO_ROOT"

echo -e "${BOLD}Integration: setup-linux.sh dry run${NC}"

# Remove any existing .springdrift so we test fresh creation
rm -rf .springdrift .env .springdrift-setup.log

# Create an input file with canned answers for the interactive prompts:
#   Agent name [Springdrift]: TestBot
#   Provider [anthropic]: mock
#   (no API key needed for mock)
#   Brave Search API key: (empty)
#   Jina Reader API key: (empty)
#   Enable email? [y/N]: n
#   Git remote URL: (empty)
#   Start Springdrift now? [y/N]: n
# The interactive prompts in order:
#   1. Install Podman? [y/N]: n
#   2. Install Ollama? [y/N]: n
#   3. Agent name [Springdrift]: TestBot
#   4. Provider [anthropic]: mock
#   5. (no API key needed for mock)
#   6. Brave Search API key: (empty)
#   7. Jina Reader API key: (empty)
#   8. Enable email? [y/N]: n
#   9. Git remote URL: (empty)
#   10. Start Springdrift now? [y/N]: n
INPUT_FILE=$(mktemp)
cat > "$INPUT_FILE" << 'ANSWERS'
n
n
TestBot
mock


n

n
ANSWERS

# SPRINGDRIFT_SKIP_SYSTEMD skips systemd commands that won't work in a container
SPRINGDRIFT_SKIP_SYSTEMD=1 bash scripts/setup/linux.sh < "$INPUT_FILE" 2>&1 || true
rm -f "$INPUT_FILE"

echo ""
echo -e "${BOLD}Post-setup verification${NC}"

# ── .springdrift/ created ────────────────────────────────────────────────────

it ".springdrift/ directory was created"
assert_true '[[ -d ".springdrift" ]]'

# ── config.toml exists and is valid ──────────────────────────────────────────

it "config.toml was generated"
assert_file_exists ".springdrift/config.toml"

CONFIG=$(cat .springdrift/config.toml)

it "config has correct provider"
assert_contains "$CONFIG" 'provider = "mock"'

it "config has correct agent name"
assert_contains "$CONFIG" 'name = "TestBot"'

it "config uses port 12001 (not 8080)"
assert_not_contains "$CONFIG" '8080'

it "config has dprime_config path"
assert_contains "$CONFIG" 'dprime_config = ".springdrift/dprime.json"'

it "config has [web] section"
assert_contains "$CONFIG" '[web]'

it "config has [sandbox] section"
assert_contains "$CONFIG" '[sandbox]'

it "config has [comms] section"
assert_contains "$CONFIG" '[comms]'

it "comms is disabled"
assert_contains "$CONFIG" 'enabled = false'

# ── .env file ────────────────────────────────────────────────────────────────

it ".env file was generated"
assert_file_exists ".env"

ENV_CONTENT=$(cat .env)

it ".env has export prefix"
assert_contains "$ENV_CONTENT" 'export SPRINGDRIFT_WEB_TOKEN='

it ".env does not contain ANTHROPIC_API_KEY (mock provider)"
assert_not_contains "$ENV_CONTENT" 'ANTHROPIC_API_KEY'

it ".env is sourceable without error"
(source .env) 2>/dev/null
assert_eq "$?" "0"

# ── Systemd env file ────────────────────────────────────────────────────────

it "/etc/springdrift/env was created"
assert_file_exists "/etc/springdrift/env"

SYSENV=$(sudo cat /etc/springdrift/env)

it "systemd env has no export prefix"
assert_not_contains "$SYSENV" 'export '

it "systemd env has web token"
assert_contains "$SYSENV" 'SPRINGDRIFT_WEB_TOKEN='

# ── Git backup repo ──────────────────────────────────────────────────────────

it ".springdrift/.git was initialised"
assert_true '[[ -d ".springdrift/.git" ]]'

# ── Setup log ────────────────────────────────────────────────────────────────
# Note: setup log is only created when stdin is a TTY (tee is skipped in pipe mode)
# We skip these assertions in non-interactive Docker runs

if [[ -f ".springdrift-setup.log" ]]; then
  LOG=$(cat .springdrift-setup.log)
  it "setup log contains preflight section"
  assert_contains "$LOG" "Preflight"
  it "setup log contains completion message"
  assert_contains "$LOG" "Setup complete"
fi

# ── Build still works ────────────────────────────────────────────────────────

it "gleam build succeeds after setup"
gleam build 2>&1 | tail -1
assert_eq "$?" "0"

# ── Gleam version is acceptable ──────────────────────────────────────────────

source "$REPO_ROOT/scripts/setup/lib/common.sh"
GLEAM_VER=$(parse_gleam_version "$(gleam --version 2>/dev/null)")

it "installed Gleam version meets minimum requirement"
assert_true 'gleam_version_ok "$GLEAM_VER"'

# ── Systemd service file (skipped when SPRINGDRIFT_SKIP_SYSTEMD=1) ──────────

if [[ -f "/etc/systemd/system/springdrift.service" ]]; then
  SVC=$(cat /etc/systemd/system/springdrift.service)
  it "service uses EnvironmentFile"
  assert_contains "$SVC" 'EnvironmentFile=/etc/springdrift/env'
  it "service has security hardening"
  assert_contains "$SVC" 'NoNewPrivileges=true'
  it "service has ReadWritePaths for .springdrift"
  assert_contains "$SVC" 'ReadWritePaths='
fi

# ── Boot and verify HTTP via --selftest ──────────────────────────────────────

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

echo ""
echo -e "${BOLD}Permission tests${NC}"

# ── Re-run with existing .springdrift ────────────────────────────────────────

it ".springdrift preserved on re-run (no clobber)"
BEFORE_HASH=$(md5sum .springdrift/config.toml | cut -d' ' -f1)
INPUT_FILE2=$(mktemp)
cat > "$INPUT_FILE2" << 'ANSWERS'
n
n
TestBot2
mock


n

n
ANSWERS
SPRINGDRIFT_SKIP_SYSTEMD=1 bash scripts/setup/linux.sh < "$INPUT_FILE2" 2>&1 || true
rm -f "$INPUT_FILE2"
AFTER_HASH=$(md5sum .springdrift/config.toml | cut -d' ' -f1)
assert_eq "$BEFORE_HASH" "$AFTER_HASH"

report
