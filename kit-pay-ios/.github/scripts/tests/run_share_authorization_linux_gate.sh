#!/usr/bin/env bash
# Share-authorization gate: compiles the Foundation-only share decision together with its XCTest
# contract suite using a stock Linux Swift toolchain and runs every test. No Xcode required; the
# same suite runs on Apple platforms inside KitPayTests.
#
# It exists because the defect it guards — build 1.0.17 (105) refusing every share on a
# signed-in handset with "Sharing is locked or your account changed" — was a decision, not a
# UIKit or Keychain behaviour, and a decision can be proved anywhere.
#
# Usage: .github/scripts/tests/run_share_authorization_linux_gate.sh [swiftc]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SWIFTC="${1:-${SWIFTC:-swiftc}}"

if ! command -v "$SWIFTC" >/dev/null 2>&1; then
    echo "run_share_authorization_linux_gate: swiftc not found ($SWIFTC); skipping" >&2
    exit 0
fi
if [ "$(uname -s)" != "Linux" ]; then
    echo "run_share_authorization_linux_gate: Linux-only runner (XCTMain); skipping" >&2
    exit 0
fi

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

"$SWIFTC" -o "$BUILD_DIR/share_authorization_gate" \
    "$ROOT/KitPay/Core/ShareAuthorizationPolicy.swift" \
    "$ROOT/KitPayTests/ShareAuthorizationPolicyTests.swift" \
    "$ROOT/.github/scripts/tests/share_authorization_linux_gate/main.swift"

"$BUILD_DIR/share_authorization_gate"
