import XCTest

// Linux entry point for the share-authorization gate. Apple platforms run the same
// `ShareAuthorizationPolicyTests` inside KitPayTests via xcodebuild; this runner exists so the
// owner's 1.0.17 (105) share-sheet regression is provable against the production decision
// without a Mac, where swift-corelibs-XCTest discovers tests through `allTests`.
#if os(Linux)
    XCTMain([
        testCase(ShareAuthorizationPolicyTests.allTests),
    ])
#else
    fatalError("share_authorization_linux_gate is the Linux runner; use xcodebuild elsewhere.")
#endif
