#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Springdrift — build the coder sandbox image (springdrift-coder:<version>).
#
# The image embeds OpenCode (https://github.com/sst/opencode) for the coder
# agent to drive headlessly. See docs/roadmap/planned/real-coder-opencode.md
# for the architecture and the pin-and-lag policy.
#
# Usage:
#   scripts/build-coder-image.sh            # uses default pin from Containerfile.coder
#   OPENCODE_VERSION=0.5.0 scripts/build-coder-image.sh
#
# Honours OPENCODE_VERSION as a build arg. The image is tagged
# springdrift-coder:<version> AND springdrift-coder:latest. The `latest` tag
# is convenience for ad-hoc operator commands; production wiring should
# reference the explicit version tag.
#
# After a successful build, run scripts/smoke-coder-image.sh to verify the
# pinned version actually works headless before relying on it.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/setup/lib/common.sh"

CONTAINERFILE="$PROJECT_ROOT/Containerfile.coder"

if [[ ! -f "$CONTAINERFILE" ]]; then
  fail "$CONTAINERFILE not found"
fi

if ! command -v podman > /dev/null 2>&1; then
  fail "podman not installed. See docs/operators-manual.md §Install."
fi

# Resolve the version: explicit env var wins, else read default from
# Containerfile.coder so the script and the file can never disagree.
if [[ -n "${OPENCODE_VERSION:-}" ]]; then
  VERSION="$OPENCODE_VERSION"
  echo "Using OPENCODE_VERSION from env: $VERSION"
else
  VERSION=$(awk -F= '/^ARG OPENCODE_VERSION=/ {print $2; exit}' "$CONTAINERFILE")
  if [[ -z "$VERSION" ]]; then
    fail "Could not parse OPENCODE_VERSION default from $CONTAINERFILE"
  fi
  echo "Using default OPENCODE_VERSION from Containerfile.coder: $VERSION"
fi

IMAGE_TAG="springdrift-coder:$VERSION"
LATEST_TAG="springdrift-coder:latest"

echo ""
echo "Building $IMAGE_TAG (this can take a few minutes on first build)..."
echo ""

if ! podman build \
    --build-arg "OPENCODE_VERSION=$VERSION" \
    -t "$IMAGE_TAG" \
    -t "$LATEST_TAG" \
    -f "$CONTAINERFILE" \
    "$PROJECT_ROOT"; then
  fail "Image build failed. See output above."
fi

echo ""
ok "Built $IMAGE_TAG"
ok "Tagged also as $LATEST_TAG"
echo ""
echo "Next: run scripts/smoke-coder-image.sh to verify OpenCode $VERSION"
echo "      starts headless and answers /health. The smoke test is the"
echo "      contract — a successful build does not by itself prove the"
echo "      pinned version is usable."
