import XCTest

// Linux entry point for the chat-media render-cost gate. Apple platforms run the same suites
// inside KitPayTests via xcodebuild; this runner exists so the contracts behind the owner's
// 1.0.17 build 105 scrolling report can execute against the production source with
// swift-corelibs-XCTest, where tests are discovered through the explicit `allTests` table.
#if os(Linux)
    XCTMain([
        testCase(ChatMediaDisplayBucketTests.allTests),
        testCase(ChatWaveformShapeTests.allTests),
        testCase(ConversationLayoutCacheTests.allTests),
    ])
#else
    fatalError("chat_media_bucket_linux_gate is the Linux runner; use xcodebuild elsewhere.")
#endif
