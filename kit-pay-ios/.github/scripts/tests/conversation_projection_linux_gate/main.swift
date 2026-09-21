import XCTest

// Linux entry point for the conversation-projection memo gate. Apple platforms run the same
// `ConversationProjectionCacheTests` inside KitPayTests via xcodebuild; this runner exists so the
// contract suite can execute against the production source with swift-corelibs-XCTest, where
// tests are discovered through the explicit `allTests` table.
#if os(Linux)
    XCTMain([
        testCase(ConversationProjectionCacheTests.allTests),
    ])
#else
    fatalError("conversation_projection_linux_gate is the Linux runner; use xcodebuild elsewhere.")
#endif
