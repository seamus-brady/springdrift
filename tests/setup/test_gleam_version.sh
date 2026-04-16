#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Test 2: Gleam version comparison (#33)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/harness.sh"
source "$REPO_ROOT/scripts/lib/setup-common.sh"

echo -e "${BOLD}Gleam version checks${NC}"

# ── parse_gleam_version ──────────────────────────────────────────────────────

it "parses 'gleam 1.11.0' output"
assert_eq "$(parse_gleam_version "gleam 1.11.0")" "1.11.0"

it "parses 'gleam 1.6.1' output"
assert_eq "$(parse_gleam_version "gleam 1.6.1")" "1.6.1"

it "parses bare version string"
assert_eq "$(parse_gleam_version "2.0.0")" "2.0.0"

it "parses version with prefix text"
assert_eq "$(parse_gleam_version "gleam compiler version 1.12.3 (compiled with Erlang/OTP 27)")" "1.12.3"

it "returns empty for garbage input"
assert_eq "$(parse_gleam_version "not a version")" ""

# ── gleam_version_ok ─────────────────────────────────────────────────────────

it "accepts exact minimum version (1.11.0)"
assert_true 'gleam_version_ok "1.11.0"'

it "accepts newer minor version (1.12.0)"
assert_true 'gleam_version_ok "1.12.0"'

it "accepts newer patch version (1.11.5)"
assert_true 'gleam_version_ok "1.11.5"'

it "accepts newer major version (2.0.0)"
assert_true 'gleam_version_ok "2.0.0"'

it "rejects older minor version (1.10.0)"
assert_false 'gleam_version_ok "1.10.0"'

it "rejects older minor version (1.6.1)"
assert_false 'gleam_version_ok "1.6.1"'

it "rejects very old version (0.33.0)"
assert_false 'gleam_version_ok "0.33.0"'

it "rejects empty string"
assert_false 'gleam_version_ok ""'

it "accepts 1.11.0 boundary"
assert_true 'gleam_version_ok "1.11.0"'

it "rejects 1.10.99 (just below boundary)"
assert_false 'gleam_version_ok "1.10.99"'

report
