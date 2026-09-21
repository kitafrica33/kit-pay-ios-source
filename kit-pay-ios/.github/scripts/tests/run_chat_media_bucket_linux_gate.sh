#!/usr/bin/env bash
# Chat-media render-cost gate: compiles the Foundation-only decode-size policy, the voice-note
# waveform shape and the conversation layout memo together with their XCTest contracts using a
# stock Linux Swift toolchain, and runs every test. No Xcode required; the same suites also run
# on Apple platforms inside KitPayTests.
#
# These are the contracts behind the owner's 1.0.17 build 105 report that "scrolling through chat
# messages lags": what a bubble may ask ImageIO for, that the waveform kept its shape when it
# stopped allocating per frame, and that a render of an unchanged thread folds it zero times.
#
# Usage: .github/scripts/tests/run_chat_media_bucket_linux_gate.sh [swiftc]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SWIFTC="${1:-${SWIFTC:-swiftc}}"

if ! command -v "$SWIFTC" >/dev/null 2>&1; then
    echo "run_chat_media_bucket_linux_gate: swiftc not found ($SWIFTC); skipping" >&2
    exit 0
fi
if [ "$(uname -s)" != "Linux" ]; then
    echo "run_chat_media_bucket_linux_gate: Linux-only runner (XCTMain); skipping" >&2
    exit 0
fi

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

"$SWIFTC" -o "$BUILD_DIR/chat_media_bucket_gate" \
    "$ROOT/KitPay/Core/ChatMediaDisplayBucket.swift" \
    "$ROOT/KitPay/Core/ChatWaveformShape.swift" \
    "$ROOT/KitPay/Core/ConversationProjectionCache.swift" \
    "$ROOT/KitPayTests/ChatMediaDisplayBucketTests.swift" \
    "$ROOT/KitPayTests/ChatWaveformShapeTests.swift" \
    "$ROOT/KitPayTests/ConversationLayoutCacheTests.swift" \
    "$ROOT/.github/scripts/tests/chat_media_bucket_linux_gate/main.swift"

"$BUILD_DIR/chat_media_bucket_gate"
