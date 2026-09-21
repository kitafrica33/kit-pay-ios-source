#!/usr/bin/env bash
# One-verification-per-foreground-session gate: compiles the Foundation-only verification policy
# together with its XCTest contract using a stock Linux Swift toolchain and runs every test. No
# Xcode required; the same suite also runs on Apple platforms inside KitPayTests.
#
# The rule behind the owner's 1.0.17 build 105 report: Home and the pay screen verify once per
# foreground session, and the content behind an unverified gate is blurred, redacted and inert
# with no frame of a legible balance on the way down.
#
# Usage: .github/scripts/tests/run_foreground_verification_linux_gate.sh [swiftc]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SWIFTC="${1:-${SWIFTC:-swiftc}}"

if ! command -v "$SWIFTC" >/dev/null 2>&1; then
    echo "run_foreground_verification_linux_gate: swiftc not found ($SWIFTC); skipping" >&2
    exit 0
fi
if [ "$(uname -s)" != "Linux" ]; then
    echo "run_foreground_verification_linux_gate: Linux-only runner (XCTMain); skipping" >&2
    exit 0
fi

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

"$SWIFTC" -o "$BUILD_DIR/foreground_verification_gate" \
    "$ROOT/KitPay/Core/ForegroundVerificationPolicy.swift" \
    "$ROOT/KitPayTests/ForegroundVerificationPolicyTests.swift" \
    "$ROOT/.github/scripts/tests/foreground_verification_linux_gate/main.swift"

"$BUILD_DIR/foreground_verification_gate"
