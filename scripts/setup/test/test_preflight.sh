#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Test 1: Preflight checks (#29, #31)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/harness.sh"
source "$REPO_ROOT/scripts/setup/lib/common.sh"

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

echo -e "${BOLD}Preflight checks${NC}"

# ── check_repo_root ──────────────────────────────────────────────────────────

it "detects valid repo root"
assert_true 'check_repo_root "$REPO_ROOT"'

it "rejects directory without gleam.toml"
assert_false 'check_repo_root "$TMPDIR_BASE"'

it "rejects empty path"
d="$TMPDIR_BASE/nonexistent"
assert_false 'check_repo_root "$d"'

# ── check_springdrift_writable ───────────────────────────────────────────────

it "passes when .springdrift does not exist"
assert_true 'check_springdrift_writable "$TMPDIR_BASE/nope"'

it "passes when .springdrift is writable"
writable_dir="$TMPDIR_BASE/writable"
mkdir -p "$writable_dir"
assert_true 'check_springdrift_writable "$writable_dir"'

it "fails when .springdrift is not writable"
readonly_dir="$TMPDIR_BASE/readonly"
mkdir -p "$readonly_dir"
chmod 444 "$readonly_dir"
assert_false 'check_springdrift_writable "$readonly_dir"'
chmod 755 "$readonly_dir"

# ── check_not_root ───────────────────────────────────────────────────────────

it "passes when not running as root"
if [[ "$(id -u)" -ne 0 ]]; then
  assert_true 'check_not_root'
else
  # If somehow running as root, this should fail
  assert_false 'check_not_root'
fi

report
