#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Test 4: Env file generation and verification (#32)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/harness.sh"
source "$REPO_ROOT/scripts/setup/lib/common.sh"

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

echo -e "${BOLD}Env file generation${NC}"

# ── .env file (sourceable, with 'export') ────────────────────────────────────

env1="$TMPDIR_BASE/env-anthropic"
generate_env_file "$env1" "sk-ant-test123" "" "" "" "" "" "tok_abc" "test.sh"
CONTENT=$(cat "$env1")

it "generates env file"
assert_file_exists "$env1"

it "includes export prefix"
assert_contains "$CONTENT" 'export ANTHROPIC_API_KEY='

it "includes the actual key value"
assert_contains "$CONTENT" 'sk-ant-test123'

it "includes web token"
assert_contains "$CONTENT" 'export SPRINGDRIFT_WEB_TOKEN='

it "includes source instructions"
assert_contains "$CONTENT" 'Source this file'

# ── Sourceable and verifiable ────────────────────────────────────────────────

it "is sourceable and sets ANTHROPIC_API_KEY"
val=$(source "$env1" && echo "$ANTHROPIC_API_KEY")
assert_eq "$val" "sk-ant-test123"

it "passes verify_env_file for anthropic"
assert_true 'verify_env_file "$env1" "anthropic"'

it "fails verify_env_file for mistral (key not present)"
assert_false 'verify_env_file "$env1" "mistral"'

# ── Mistral env ──────────────────────────────────────────────────────────────

env2="$TMPDIR_BASE/env-mistral"
generate_env_file "$env2" "" "mist-key-456" "" "" "" "" "tok_def" "test.sh"

it "passes verify_env_file for mistral provider"
assert_true 'verify_env_file "$env2" "mistral"'

it "fails verify_env_file for anthropic (wrong provider)"
assert_false 'verify_env_file "$env2" "anthropic"'

# ── Vertex env ───────────────────────────────────────────────────────────────

env3="$TMPDIR_BASE/env-vertex"
generate_env_file "$env3" "" "" "my-gcp-project" "" "" "" "tok_ghi" "test.sh"

it "passes verify_env_file for vertex"
assert_true 'verify_env_file "$env3" "vertex"'

# ── Mock/local always pass ───────────────────────────────────────────────────

env4="$TMPDIR_BASE/env-empty"
generate_env_file "$env4" "" "" "" "" "" "" "" "test.sh"

it "passes verify_env_file for mock (no keys needed)"
assert_true 'verify_env_file "$env4" "mock"'

it "passes verify_env_file for local (no keys needed)"
assert_true 'verify_env_file "$env4" "local"'

# ── Optional keys ────────────────────────────────────────────────────────────

env5="$TMPDIR_BASE/env-full"
generate_env_file "$env5" "sk-ant-key" "" "" "brave-key" "jina-key" "agentmail-key" "tok_full" "test.sh"
CONTENT5=$(cat "$env5")

it "includes brave key when provided"
assert_contains "$CONTENT5" 'BRAVE_API_KEY'

it "includes jina key when provided"
assert_contains "$CONTENT5" 'JINA_API_KEY'

it "includes agentmail key when provided"
assert_contains "$CONTENT5" 'AGENTMAIL_API_KEY'

# ── Omits empty keys ────────────────────────────────────────────────────────

env6="$TMPDIR_BASE/env-minimal"
generate_env_file "$env6" "sk-ant-key" "" "" "" "" "" "tok_min" "test.sh"
CONTENT6=$(cat "$env6")

it "omits MISTRAL_API_KEY when empty"
assert_not_contains "$CONTENT6" 'MISTRAL_API_KEY'

it "omits BRAVE_API_KEY when empty"
assert_not_contains "$CONTENT6" 'BRAVE_API_KEY'

it "omits JINA_API_KEY when empty"
assert_not_contains "$CONTENT6" 'JINA_API_KEY'

# ── Systemd env file (no 'export' prefix) ───────────────────────────────────

env7="$TMPDIR_BASE/env-systemd"
generate_systemd_env_file "$env7" "sk-ant-sys" "" "" "" "" "" "tok_sys"
CONTENT7=$(cat "$env7")

it "generates systemd env file without export prefix"
assert_not_contains "$CONTENT7" 'export '

it "has bare key=value format"
assert_contains "$CONTENT7" 'ANTHROPIC_API_KEY=sk-ant-sys'

it "has web token in systemd format"
assert_contains "$CONTENT7" 'SPRINGDRIFT_WEB_TOKEN=tok_sys'

# ── Nonexistent file ─────────────────────────────────────────────────────────

it "fails verify_env_file for nonexistent file"
assert_false 'verify_env_file "/tmp/does-not-exist-$(date +%s)" "anthropic"'

report
