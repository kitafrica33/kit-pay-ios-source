import Foundation
import XCTest
@testable import KitPay

final class PushRegistrationTests: XCTestCase {
    func testConcurrentReplaysUseOneBackendOperation() async {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let operation = ControlledPushOperation()
        let manager = PushRegistrationManager(defaults: defaults, jitter: { 0 })

        let first = Task {
            await manager.register(accountID: "user-a", provider: "apns", token: "token-a") {
                await operation.perform()
            }
        }
        await operation.waitUntilStarted()
        let second = Task {
            await manager.register(accountID: "user-a", provider: "apns", token: "token-a") {
                await operation.perform()
            }
        }
        await Task.yield()
        await operation.release()

        let outcomes = [await first.value, await second.value]
        let callCount = await operation.callCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(Set(outcomes), Set([.registered, .alreadyRegistered]))
    }

    func testSuccessPersistsAcrossManagerRecreationAndIsScopedToTuple() async {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let counter = PushAttemptCounter()
        let firstManager = PushRegistrationManager(defaults: defaults, jitter: { 0 })

        let initialOutcome = await firstManager.register(
            accountID: "user-a",
            provider: "apns",
            token: "token-a"
        ) { await counter.succeed() }
        XCTAssertEqual(initialOutcome, .registered)

        let recreatedManager = PushRegistrationManager(defaults: defaults, jitter: { 0 })
        let duplicateOutcome = await recreatedManager.register(
            accountID: "user-a",
            provider: "apns",
            token: "token-a"
        ) { await counter.succeed() }
        let accountScopedOutcome = await recreatedManager.register(
            accountID: "user-b",
            provider: "apns",
            token: "token-a"
        ) { await counter.succeed() }
        let providerScopedOutcome = await recreatedManager.register(
            accountID: "user-a",
            provider: "apns_voip",
            token: "token-a"
        ) { await counter.succeed() }
        let tokenScopedOutcome = await recreatedManager.register(
            accountID: "user-a",
            provider: "apns",
            token: "token-b"
        ) { await counter.succeed() }
        let callCount = await counter.callCount()
        XCTAssertEqual(duplicateOutcome, .alreadyRegistered)
        XCTAssertEqual(accountScopedOutcome, .registered)
        XCTAssertEqual(providerScopedOutcome, .registered)
        XCTAssertEqual(tokenScopedOutcome, .registered)
        XCTAssertEqual(callCount, 4)
    }

    func testReceiptExpiresSoBackendLossCanSelfHeal() async {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let counter = PushAttemptCounter()
        let registeredAt = Date(timeIntervalSince1970: 1_000)
        let firstManager = PushRegistrationManager(
            defaults: defaults,
            receiptLifetime: 60,
            now: { registeredAt },
            jitter: { 0 }
        )
        let initialOutcome = await firstManager.register(
            accountID: "user-a",
            provider: "apns",
            token: "token-a"
        ) { await counter.succeed() }
        XCTAssertEqual(initialOutcome, .registered)

        let laterManager = PushRegistrationManager(
            defaults: defaults,
            receiptLifetime: 60,
            now: { registeredAt.addingTimeInterval(61) },
            jitter: { 0 }
        )
        let expiredOutcome = await laterManager.register(
            accountID: "user-a",
            provider: "apns",
            token: "token-a"
        ) { await counter.succeed() }
        let callCount = await counter.callCount()
        XCTAssertEqual(expiredOutcome, .registered)
        XCTAssertEqual(callCount, 2)
    }

    func testResetCancelsRetryAndClearsOnlyRequestedProviderReceipt() async {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let counter = PushAttemptCounter()
        let manager = PushRegistrationManager(defaults: defaults, jitter: { 0 })

        for tuple in [
            ("user-a", "apns", "token-a"),
            ("user-a", "apns_voip", "token-v"),
            ("user-b", "apns", "token-b"),
        ] {
            let outcome = await manager.register(
                accountID: tuple.0,
                provider: tuple.1,
                token: tuple.2
            ) { await counter.succeed() }
            XCTAssertEqual(outcome, .registered)
        }

        let retryProbe = PushRetryProbe()
        let retrying = Task {
            await manager.register(
                accountID: "user-a",
                provider: "apns",
                token: "token-new"
            ) {
                try await retryProbe.rateLimited(retryAfter: 30)
            }
        }
        await retryProbe.waitUntilAttempted()
        await manager.reset(accountID: "user-a", provider: "apns")
        let cancelledOutcome = await retrying.value
        XCTAssertEqual(cancelledOutcome, .cancelled)

        let recreatedManager = PushRegistrationManager(defaults: defaults, jitter: { 0 })
        let clearedOutcome = await recreatedManager.register(
            accountID: "user-a",
            provider: "apns",
            token: "token-a"
        ) { await counter.succeed() }
        let preservedProviderOutcome = await recreatedManager.register(
            accountID: "user-a",
            provider: "apns_voip",
            token: "token-v"
        ) { await counter.succeed() }
        let preservedAccountOutcome = await recreatedManager.register(
            accountID: "user-b",
            provider: "apns",
            token: "token-b"
        ) { await counter.succeed() }
        XCTAssertEqual(clearedOutcome, .registered)
        XCTAssertEqual(preservedProviderOutcome, .alreadyRegistered)
        XCTAssertEqual(preservedAccountOutcome, .alreadyRegistered)
    }

    func testRateLimitHonorsRetryAfterAndCapsAttempts() async {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let probe = PushRetryProbe()
        let manager = PushRegistrationManager(
            defaults: defaults,
            sleeper: { delay in await probe.record(delay: delay) },
            jitter: { 0 }
        )

        let outcome = await manager.register(
            accountID: "user-a",
            provider: "apns",
            token: "token-a"
        ) {
            try await probe.rateLimited(retryAfter: 30)
        }

        XCTAssertEqual(outcome, .failed)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.attempts, 4)
        XCTAssertEqual(snapshot.delays, [30, 30, 30])
        XCTAssertEqual(
            PushRegistrationRetryPolicy.decision(
                for: APIErrorPayload(
                    code: "TOO_MANY_REQUESTS",
                    message: "Retry later.",
                    httpStatus: 429,
                    retryAfter: 600
                ),
                automaticRetryCount: 0,
                jitterUnitInterval: 0
            ),
            .retry(after: 300)
        )
    }

    func testOfflineFailureCanRetryImmediatelyWhenConnectivityReturns() async {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let operation = OfflineThenSuccessfulPushOperation()
        let manager = PushRegistrationManager(defaults: defaults, jitter: { 0 })

        let offlineOutcome = await manager.register(
            accountID: "user-a",
            provider: "apns",
            token: "token-a"
        ) { try await operation.perform() }
        let recoveredOutcome = await manager.register(
            accountID: "user-a",
            provider: "apns",
            token: "token-a"
        ) { try await operation.perform() }
        let callCount = await operation.callCount()
        XCTAssertEqual(offlineOutcome, .failed)
        XCTAssertEqual(recoveredOutcome, .registered)
        XCTAssertEqual(callCount, 2)
    }

    func testRetryAfterParserAcceptsSeconds() {
        let response = HTTPURLResponse(
            url: URL(string: "https://pay.kit.africa/")!,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: ["Retry-After": "45"]
        )!
        XCTAssertEqual(HTTPRetryAfterParser.delay(from: response), 45)
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "PushRegistrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

private actor ControlledPushOperation {
    private var calls = 0
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func perform() async -> Bool {
        calls += 1
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return true }
        await withCheckedContinuation { releaseWaiters.append($0) }
        return true
    }

    func waitUntilStarted() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func callCount() -> Int { calls }
}

private actor PushAttemptCounter {
    private var calls = 0

    func succeed() -> Bool {
        calls += 1
        return true
    }

    func callCount() -> Int { calls }
}

private actor PushRetryProbe {
    private var attempts = 0
    private var delays: [TimeInterval] = []
    private var attemptWaiters: [CheckedContinuation<Void, Never>] = []

    func rateLimited(retryAfter: TimeInterval) throws -> Bool {
        attempts += 1
        let waiters = attemptWaiters
        attemptWaiters.removeAll()
        waiters.forEach { $0.resume() }
        throw APIErrorPayload(
            code: "TOO_MANY_REQUESTS",
            message: "Retry later.",
            httpStatus: 429,
            retryAfter: retryAfter
        )
    }

    func waitUntilAttempted() async {
        guard attempts == 0 else { return }
        await withCheckedContinuation { attemptWaiters.append($0) }
    }

    func record(delay: TimeInterval) {
        delays.append(delay)
    }

    func snapshot() -> (attempts: Int, delays: [TimeInterval]) {
        (attempts, delays)
    }
}

private actor OfflineThenSuccessfulPushOperation {
    private var calls = 0

    func perform() throws -> Bool {
        calls += 1
        if calls == 1 { throw URLError(.notConnectedToInternet) }
        return true
    }

    func callCount() -> Int { calls }
}
