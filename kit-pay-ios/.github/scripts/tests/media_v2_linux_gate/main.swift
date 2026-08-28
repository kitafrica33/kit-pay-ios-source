import XCTest

// Linux entry point for the KITMEDIA2 contract gate. Apple platforms run the same
// `MediaMessageV2ContractTests` inside KitPayTests via xcodebuild; this runner exists so the
// contract suite can execute against the production source with swift-corelibs-XCTest, where
// tests are discovered through the explicit `allTests` table.
#if os(Linux)
    XCTMain([
        testCase(MediaMessageV2ContractTests.allTests),
    ])
#else
    fatalError("media_v2_linux_gate is the Linux contract runner; use xcodebuild elsewhere.")
#endif
