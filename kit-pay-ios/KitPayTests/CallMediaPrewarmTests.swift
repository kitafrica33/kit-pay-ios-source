import XCTest

@testable import KitPay

final class CallMediaPrewarmTests: XCTestCase {
    func testStorableOriginKeepsOnlyTheMediaHost() throws {
        let url = try XCTUnwrap(URL(string: "wss://sfu.kit.africa:7881/rtc?access_token=secret"))
        let origin = try XCTUnwrap(CallMediaPrewarmPolicy.storableOrigin(for: url))
        XCTAssertEqual(origin.absoluteString, "wss://sfu.kit.africa:7881")
        XCTAssertNil(origin.query)
        XCTAssertTrue(origin.path.isEmpty)
    }

    func testStorableOriginKeepsTheDefaultPortURLIntact() throws {
        let url = try XCTUnwrap(URL(string: "wss://sfu.kit.africa/rtc"))
        let origin = try XCTUnwrap(CallMediaPrewarmPolicy.storableOrigin(for: url))
        XCTAssertEqual(origin.absoluteString, "wss://sfu.kit.africa")
    }

    func testStorableOriginRejectsAnythingThatIsNotAPlainMediaHost() {
        for candidate in [
            "https://sfu.kit.africa/rtc",
            "wss://user:password@sfu.kit.africa/rtc",
            "wss:///rtc",
            "not a url at all",
        ] {
            guard let url = URL(string: candidate) else { continue }
            XCTAssertNil(
                CallMediaPrewarmPolicy.storableOrigin(for: url),
                "expected \(candidate) to be rejected")
        }
    }

    func testPrewarmCooldownAllowsTheFirstAttemptAndThrottlesRepeats() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(CallMediaPrewarmPolicy.shouldPrewarm(lastAttempt: nil, now: now))
        XCTAssertFalse(CallMediaPrewarmPolicy.shouldPrewarm(lastAttempt: now, now: now))
        XCTAssertFalse(
            CallMediaPrewarmPolicy.shouldPrewarm(
                lastAttempt: now, now: now.addingTimeInterval(CallMediaPrewarmPolicy.cooldown - 1)))
        XCTAssertTrue(
            CallMediaPrewarmPolicy.shouldPrewarm(
                lastAttempt: now, now: now.addingTimeInterval(CallMediaPrewarmPolicy.cooldown)))
        // A clock that moved backwards must warm rather than latch until it catches up.
        XCTAssertTrue(
            CallMediaPrewarmPolicy.shouldPrewarm(
                lastAttempt: now, now: now.addingTimeInterval(-3600)))
    }

    @MainActor
    func testPrewarmOnlyWarmsAHostThatAlreadyCarriedACall() async throws {
        let defaults = try Self.scratchDefaults()
        let warmed = WarmRecorder()
        let prewarmer = CallMediaPrewarmer(defaults: defaults) { url in warmed.record(url) }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        prewarmer.prewarm(now: start)
        await Self.settle()
        XCTAssertTrue(warmed.urls.isEmpty, "nothing is known yet, so nothing may be dialled")

        let connected = try XCTUnwrap(URL(string: "wss://sfu.kit.africa/rtc?access_token=secret"))
        prewarmer.rememberConnectedMediaURL(connected)
        XCTAssertEqual(prewarmer.knownMediaOrigin?.absoluteString, "wss://sfu.kit.africa")

        prewarmer.prewarm(now: start)
        await Self.settle()
        XCTAssertEqual(warmed.urls.map(\.absoluteString), ["wss://sfu.kit.africa"])

        // A second ring inside the cooldown reuses the pooled connection instead of dialling again.
        prewarmer.prewarm(now: start.addingTimeInterval(1))
        await Self.settle()
        XCTAssertEqual(warmed.urls.count, 1)

        prewarmer.prewarm(now: start.addingTimeInterval(CallMediaPrewarmPolicy.cooldown))
        await Self.settle()
        XCTAssertEqual(warmed.urls.count, 2)
    }

    @MainActor
    func testForgettingClearsTheStoredHost() async throws {
        let defaults = try Self.scratchDefaults()
        let warmed = WarmRecorder()
        let prewarmer = CallMediaPrewarmer(defaults: defaults) { url in warmed.record(url) }
        prewarmer.rememberConnectedMediaURL(try XCTUnwrap(URL(string: "wss://sfu.kit.africa/rtc")))

        prewarmer.forget()
        XCTAssertNil(prewarmer.knownMediaOrigin)

        prewarmer.prewarm(now: Date(timeIntervalSince1970: 1_700_000_000))
        await Self.settle()
        XCTAssertTrue(warmed.urls.isEmpty)
    }

    @MainActor
    func testAHostileStoredValueIsNeverDialled() throws {
        let defaults = try Self.scratchDefaults()
        defaults.set("https://evil.example.com/steal", forKey: "kit.calls.media-origin")
        let prewarmer = CallMediaPrewarmer(defaults: defaults) { _ in
            XCTFail("a non-media origin must never be warmed")
        }
        XCTAssertNil(prewarmer.knownMediaOrigin)
        prewarmer.prewarm(now: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private static func scratchDefaults(function: String = #function) throws -> UserDefaults {
        let name = "kit.tests.prewarm." + function.replacingOccurrences(of: "()", with: "")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// The prewarm is fire-and-forget, so the test has to let its task run.
    private static func settle() async {
        for _ in 0..<4 { await Task.yield() }
    }
}

/// Only ever touched from the main actor inside these tests; the annotation exists so the recorder
/// can be captured by the prewarmer's `@Sendable` warming closure.
private final class WarmRecorder: @unchecked Sendable {
    private(set) var urls: [URL] = []

    func record(_ url: URL) { urls.append(url) }
}
