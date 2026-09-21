#!/usr/bin/env bash
# Conversation-projection memo gate: compiles the Foundation-only projection cache together with
# its XCTest contract suite using a stock Linux Swift toolchain and runs every test. No Xcode
# required; the suite itself also runs on Apple platforms inside KitPayTests.
#
# Usage: .github/scripts/tests/run_conversation_projection_linux_gate.sh [swiftc]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SWIFTC="${1:-${SWIFTC:-swiftc}}"

if ! command -v "$SWIFTC" >/dev/null 2>&1; then
    echo "run_conversation_projection_linux_gate: swiftc not found ($SWIFTC); skipping" >&2
    exit 0
fi
if [ "$(uname -s)" != "Linux" ]; then
    echo "run_conversation_projection_linux_gate: Linux-only runner (XCTMain); skipping" >&2
    exit 0
fi

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

"$SWIFTC" -o "$BUILD_DIR/conversation_projection_gate" \
    "$ROOT/KitPay/Core/ConversationProjectionCache.swift" \
    "$ROOT/KitPayTests/ConversationProjectionCacheTests.swift" \
    "$ROOT/.github/scripts/tests/conversation_projection_linux_gate/main.swift"

"$BUILD_DIR/conversation_projection_gate"
