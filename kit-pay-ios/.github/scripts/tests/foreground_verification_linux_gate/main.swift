import XCTest

// Linux entry point for the one-verification-per-foreground-session gate. Apple platforms run the
// same suite inside KitPayTests via xcodebuild; this runner exists so the rule behind the owner's
// 1.0.17 build 105 report can execute against the production source with swift-corelibs-XCTest,
// where tests are discovered through the explicit `allTests` table.
#if os(Linux)
    XCTMain([
        testCase(ForegroundVerificationPolicyTests.allTests),
    ])
#else
    fatalError("foreground_verification_linux_gate is the Linux runner; use xcodebuild elsewhere.")
#endif
