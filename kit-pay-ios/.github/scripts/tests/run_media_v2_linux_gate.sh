#!/usr/bin/env bash
# KITMEDIA2 contract gate (contract v0.4, SHA-256 449925d9…): compiles the Foundation-only
# media-message-v2 core together with its XCTest contract suite using a stock Linux Swift
# toolchain and runs every test. No Xcode required; the suite itself also runs on Apple
# platforms inside KitPayTests.
#
# Usage: .github/scripts/tests/run_media_v2_linux_gate.sh [swiftc]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SWIFTC="${1:-${SWIFTC:-swiftc}}"

if ! command -v "$SWIFTC" >/dev/null 2>&1; then
    echo "run_media_v2_linux_gate: swiftc not found ($SWIFTC); skipping" >&2
    exit 0
fi
if [ "$(uname -s)" != "Linux" ]; then
    echo "run_media_v2_linux_gate: Linux-only runner (XCTMain); skipping" >&2
    exit 0
fi

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

"$SWIFTC" -o "$BUILD_DIR/media_v2_contract_gate" \
    "$ROOT/KitPay/Core/MediaMessageV2Models.swift" \
    "$ROOT/KitPayTests/MediaMessageV2ContractTests.swift" \
    "$ROOT/.github/scripts/tests/media_v2_linux_gate/main.swift"

"$BUILD_DIR/media_v2_contract_gate"
