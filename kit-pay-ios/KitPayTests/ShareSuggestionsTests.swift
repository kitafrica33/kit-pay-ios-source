import Foundation
import XCTest
@testable import KitPay

final class ShareSuggestionsTests: XCTestCase {
    private let accountID = "11111111-1111-4111-8111-111111111111"
    private let otherAccountID = "22222222-2222-4222-8222-222222222222"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func destination(_ index: Int = 1, name: String = "Recipient") -> SharedInboxDestination {
        SharedInboxDestination(
            conversationID: String(format: "33333333-3333-4333-8333-%012d", index),
            recipientUserID: String(format: "44444444-4444-4444-8444-%012d", index),
            displayName: name, kind: .direct, memberCount: nil
        )
    }

    private func message(
        _ destination: SharedInboxDestination, index: Int = 1,
        state: String = "sent", outgoing: Bool = true, sentAt: Date? = nil
    ) -> ShareSuggestionMessage {
        ShareSuggestionMessage(
            id: UUID(uuidString: String(format: "55555555-5555-4555-8555-%012d", index))!,
            conversationID: destination.conversationID!, sentAt: sentAt ?? now,
            state: state, isOutgoing: outgoing
        )
    }

    func testOnlyRecentSuccessfullySentConversationsQualify() throws {
        let rows = (1...9).map { destination($0) }
        let messages = [
            message(rows[0], state: "sent"),
            message(rows[1], state: "delivered"),
            message(rows[2], state: "read"),
            message(rows[3], state: "queued"),
            message(rows[4], state: "failed"),
            message(rows[5], state: "received", outgoing: false),
            message(rows[6], sentAt: now.addingTimeInterval(1)),
            message(rows[7], sentAt: now.addingTimeInterval(-ShareSuggestionPolicy.retention)),
            ShareSuggestionMessage(id: UUID(), conversationID: rows[8].conversationID!,
                                   sentAt: nil, state: "sent", isOutgoing: true),
        ]
        let records = try XCTUnwrap(ShareSuggestionPolicy.records(
            accountID: accountID, destinations: rows, messages: messages, now: now
        ))
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(Set(records.map(\.conversationIdentifier)), Set(rows.prefix(3).map {
            ShareSuggestionPolicy.conversationIdentifier(accountID: accountID, conversationID: $0.conversationID!)
        }))
        XCTAssertEqual(Set(records.map(\.interactionIdentifier)).count, 3)
        XCTAssertFalse(records.contains { $0.recipientIdentifier.contains("44444444") })
    }

    func testLatestSendPerDestinationAndMaximumTwelve() throws {
        let rows = (1...15).map { destination($0) }
        var messages = rows.enumerated().map { offset, row in
            message(row, index: offset + 1, sentAt: now.addingTimeInterval(-Double(offset)))
        }
        messages.append(message(rows[0], index: 100, sentAt: now.addingTimeInterval(-100)))
        let records = try XCTUnwrap(ShareSuggestionPolicy.records(
            accountID: accountID, destinations: rows, messages: messages, now: now
        ))
        XCTAssertEqual(records.count, 12)
        XCTAssertEqual(records.first?.sentAt, now)
        XCTAssertEqual(records.last?.sentAt, now.addingTimeInterval(-11))
    }

    func testResolverRequiresCurrentAccountAndValidUniqueDirectory() {
        let row = destination()
        let identifier = ShareSuggestionPolicy.conversationIdentifier(
            accountID: accountID, conversationID: row.conversationID!
        )
        XCTAssertEqual(ShareSuggestions.destination(conversationIdentifier: identifier,
                         accountID: accountID, destinations: [row]), row)
        XCTAssertNil(ShareSuggestions.destination(conversationIdentifier: identifier,
                         accountID: otherAccountID, destinations: [row]))
        XCTAssertNil(ShareSuggestions.destination(conversationIdentifier: identifier,
                         accountID: accountID, destinations: []))
        XCTAssertNil(ShareSuggestions.destination(conversationIdentifier: identifier,
                         accountID: accountID, destinations: [row, row]))
        XCTAssertNil(ShareSuggestions.destination(conversationIdentifier: row.conversationID,
                         accountID: accountID, destinations: [row]))
        XCTAssertNil(ShareSuggestions.destination(conversationIdentifier: identifier,
                         accountID: accountID, destinations: [destination(name: "bad\nname")]))
    }

    func testOpaqueCleanupGroupMustBeExactLowercaseHash() {
        XCTAssertTrue(ShareSuggestionPolicy.isKnownGroupIdentifier(ShareSuggestionPolicy.accountGroup(accountID)))
        XCTAssertFalse(ShareSuggestionPolicy.isKnownGroupIdentifier(
            ShareSuggestionPolicy.groupPrefix + String(repeating: "G", count: 64)))
        XCTAssertFalse(ShareSuggestionPolicy.isKnownGroupIdentifier(
            ShareSuggestionPolicy.groupPrefix + String(repeating: "a", count: 65)))
    }

    func testStaleRefreshCannotDonateAfterSynchronousInvalidation() async throws {
        let donor = SuggestionTestDonor()
        let suggestions = ShareSuggestions(donor: donor, store: SuggestionTestGroups(), now: { [now] in now })
        let row = destination()
        let token = try XCTUnwrap(suggestions.beginRefresh(accountID: accountID))
        suggestions.invalidate()
        let refreshed = await suggestions.refresh(accountID: accountID, destinations: [row],
                                                  messages: [message(row)], requestToken: token)
        XCTAssertFalse(refreshed)
        let records = await donor.records
        XCTAssertTrue(records.isEmpty)
    }

    func testHeldDonationFinishesBeforeRevocationDeletesNames() async throws {
        let donor = SuggestionTestDonor()
        await donor.holdNextDonation()
        let groups = SuggestionTestGroups()
        let suggestions = ShareSuggestions(donor: donor, store: groups, now: { [now] in now })
        let row = destination()
        let token = try XCTUnwrap(suggestions.beginRefresh(accountID: accountID))
        let refresh = Task {
            await suggestions.refresh(accountID: accountID, destinations: [row],
                                      messages: [message(row)], requestToken: token)
        }
        await donor.waitUntilDonationStarted()
        XCTAssertEqual(groups.load(), [ShareSuggestionPolicy.accountGroup(accountID)])
        suggestions.invalidate()
        let revoke = Task { await suggestions.revoke() }
        await donor.releaseDonation()
        let refreshed = await refresh.value
        let revoked = await revoke.value
        XCTAssertFalse(refreshed)
        XCTAssertTrue(revoked)
        let events = await donor.events
        XCTAssertEqual(events, ["donate-start", "donate-finish", "delete-group"])
        let records = await donor.records
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(groups.load().isEmpty)
        let stale = await suggestions.refresh(accountID: accountID, destinations: [row],
                                              messages: [message(row)], requestToken: token)
        XCTAssertFalse(stale)
    }

    func testSwitchAccountRemovesOldNamesBeforeNewDonation() async throws {
        let donor = SuggestionTestDonor()
        let suggestions = ShareSuggestions(donor: donor, store: SuggestionTestGroups(), now: { [now] in now })
        let row = destination()
        let first = try XCTUnwrap(suggestions.beginRefresh(accountID: accountID))
        let firstResult = await suggestions.refresh(accountID: accountID, destinations: [row],
                                                    messages: [message(row)], requestToken: first)
        XCTAssertTrue(firstResult)
        let second = try XCTUnwrap(suggestions.beginRefresh(accountID: otherAccountID))
        let secondResult = await suggestions.refresh(accountID: otherAccountID, destinations: [row],
                                                     messages: [message(row)], requestToken: second)
        XCTAssertTrue(secondResult)
        let events = await donor.events
        XCTAssertEqual(events, ["donate-start", "donate-finish", "delete-group", "donate-start", "donate-finish"])
        let records = await donor.records
        XCTAssertEqual(records.values.map(\.groupIdentifier), [ShareSuggestionPolicy.accountGroup(otherAccountID)])
    }

    func testOrdinaryAppLockKeepsHeldDonationButStopsStaleRefreshWork() async throws {
        let donor = SuggestionTestDonor()
        await donor.holdNextDonation()
        let suggestions = ShareSuggestions(donor: donor, store: SuggestionTestGroups(), now: { [now] in now })
        let row = destination()
        let token = try XCTUnwrap(suggestions.beginRefresh(accountID: accountID))
        let refresh = Task {
            await suggestions.refresh(accountID: accountID, destinations: [row],
                                      messages: [message(row)], requestToken: token)
        }
        await donor.waitUntilDonationStarted()
        suggestions.suspendRefresh()
        await donor.releaseDonation()
        let paused = await refresh.value
        XCTAssertFalse(paused)
        let retained = await donor.records
        XCTAssertEqual(retained.count, 1)
        let stale = await suggestions.refresh(accountID: accountID, destinations: [row],
                                              messages: [message(row)], requestToken: token)
        XCTAssertFalse(stale)
        let resumedToken = try XCTUnwrap(suggestions.beginRefresh(accountID: accountID))
        let resumed = await suggestions.refresh(accountID: accountID, destinations: [row],
                                                messages: [message(row)], requestToken: resumedToken)
        XCTAssertTrue(resumed)
        let events = await donor.events
        XCTAssertEqual(events, ["donate-start", "donate-finish"])
    }

    func testOrdinarySuspensionCannotCancelAnAlreadyRequestedPrivacyRevocation() async throws {
        let donor = SuggestionTestDonor()
        await donor.holdNextDonation()
        let deleted = expectation(description: "Privacy revoke deletes the held donation")
        await donor.observeGroupDeletion { deleted.fulfill() }
        let suggestions = ShareSuggestions(donor: donor, store: SuggestionTestGroups(), now: { [now] in now })
        let row = destination()
        let token = try XCTUnwrap(suggestions.beginRefresh(accountID: accountID))
        let refresh = Task {
            await suggestions.refresh(accountID: accountID, destinations: [row],
                                      messages: [message(row)], requestToken: token)
        }
        await donor.waitUntilDonationStarted()
        suggestions.invalidate()
        suggestions.suspendRefresh()
        await donor.releaseDonation()
        let refreshed = await refresh.value
        XCTAssertFalse(refreshed)
        await fulfillment(of: [deleted], timeout: 1)
        let records = await donor.records
        XCTAssertTrue(records.isEmpty)
    }

    func testIdenticalSnapshotsDoNotRepeatPlatformDonations() async throws {
        let donor = SuggestionTestDonor()
        let suggestions = ShareSuggestions(donor: donor, store: SuggestionTestGroups(), now: { [now] in now })
        let row = destination()
        for _ in 0..<5 {
            let token = try XCTUnwrap(suggestions.beginRefresh(accountID: accountID))
            let result = await suggestions.refresh(accountID: accountID, destinations: [row],
                                                   messages: [message(row)], requestToken: token)
            XCTAssertTrue(result)
        }
        let events = await donor.events
        XCTAssertEqual(events, ["donate-start", "donate-finish"])
    }

    func testChangedNameRedonatesAndRemovedDestinationDeletesInteraction() async throws {
        let donor = SuggestionTestDonor()
        let suggestions = ShareSuggestions(donor: donor, store: SuggestionTestGroups(), now: { [now] in now })
        let first = destination(1)
        let second = destination(2)
        let token = try XCTUnwrap(suggestions.beginRefresh(accountID: accountID))
        let initial = await suggestions.refresh(accountID: accountID, destinations: [first, second],
                                                messages: [message(first), message(second, index: 2)], requestToken: token)
        XCTAssertTrue(initial)
        let renamed = destination(1, name: "New name")
        let updatedToken = try XCTUnwrap(suggestions.beginRefresh(accountID: accountID))
        let updated = await suggestions.refresh(accountID: accountID, destinations: [renamed],
                                                messages: [message(first)], requestToken: updatedToken)
        XCTAssertTrue(updated)
        let records = await donor.records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.values.first?.displayName, "New name")
        let events = await donor.events
        XCTAssertEqual(Array(events.suffix(3)), ["delete-identifiers", "donate-start", "donate-finish"])
    }

    func testRestartCleansPersistedGroupsBeforeDonating() async throws {
        let oldGroup = ShareSuggestionPolicy.accountGroup(otherAccountID)
        let groups = SuggestionTestGroups([oldGroup])
        let donor = SuggestionTestDonor()
        let suggestions = ShareSuggestions(donor: donor, store: groups, now: { [now] in now })
        let row = destination()
        let token = try XCTUnwrap(suggestions.beginRefresh(accountID: accountID))
        let result = await suggestions.refresh(accountID: accountID, destinations: [row],
                                               messages: [message(row)], requestToken: token)
        XCTAssertTrue(result)
        let events = await donor.events
        XCTAssertEqual(events, ["delete-group", "donate-start", "donate-finish"])
        XCTAssertEqual(groups.load(), [ShareSuggestionPolicy.accountGroup(accountID)])
    }

    func testDeletionFailurePreservesCleanupIdentityAndBlocksNewDonation() async throws {
        let oldGroup = ShareSuggestionPolicy.accountGroup(otherAccountID)
        let groups = SuggestionTestGroups([oldGroup])
        let donor = SuggestionTestDonor()
        await donor.setFailDeletion(true)
        let suggestions = ShareSuggestions(donor: donor, store: groups, now: { [now] in now })
        let row = destination()
        let token = try XCTUnwrap(suggestions.beginRefresh(accountID: accountID))
        let result = await suggestions.refresh(accountID: accountID, destinations: [row],
                                               messages: [message(row)], requestToken: token)
        XCTAssertFalse(result)
        XCTAssertEqual(groups.load(), [oldGroup])
        let records = await donor.records
        XCTAssertTrue(records.isEmpty)
        await donor.setFailDeletion(false)
        let revoked = await suggestions.revoke()
        XCTAssertTrue(revoked)
        XCTAssertTrue(groups.load().isEmpty)
    }

    func testCacheExpiresAtRetentionBoundary() async throws {
        let clock = SuggestionTestClock(now)
        let donor = SuggestionTestDonor()
        let suggestions = ShareSuggestions(donor: donor, store: SuggestionTestGroups(), now: { clock.date })
        let row = destination()
        let old = message(row, sentAt: now.addingTimeInterval(-ShareSuggestionPolicy.retention + 1))
        let first = try XCTUnwrap(suggestions.beginRefresh(accountID: accountID))
        let firstResult = await suggestions.refresh(accountID: accountID, destinations: [row],
                                                    messages: [old], requestToken: first)
        XCTAssertTrue(firstResult)
        clock.date = now.addingTimeInterval(1)
        let second = try XCTUnwrap(suggestions.beginRefresh(accountID: accountID))
        let secondResult = await suggestions.refresh(accountID: accountID, destinations: [row],
                                                     messages: [old], requestToken: second)
        XCTAssertTrue(secondResult)
        let records = await donor.records
        XCTAssertTrue(records.isEmpty)
    }
}

private actor SuggestionTestDonor: ShareSuggestionDonating {
    private(set) var records: [String: ShareSuggestionRecord] = [:]
    private(set) var events: [String] = []
    private var shouldHoldDonation = false
    private var donationStarted = false
    private var donationContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var failDeletion = false
    private var groupDeletionObserver: (@Sendable () -> Void)?

    func holdNextDonation() { shouldHoldDonation = true }
    func setFailDeletion(_ value: Bool) { failDeletion = value }
    func observeGroupDeletion(_ observer: @escaping @Sendable () -> Void) { groupDeletionObserver = observer }
    func waitUntilDonationStarted() async {
        if donationStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func releaseDonation() { donationContinuation?.resume(); donationContinuation = nil }

    func donate(_ record: ShareSuggestionRecord) async throws {
        events.append("donate-start")
        if shouldHoldDonation {
            shouldHoldDonation = false
            await withCheckedContinuation { continuation in
                donationContinuation = continuation
                donationStarted = true
                let waiters = startWaiters
                startWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        records[record.interactionIdentifier] = record
        events.append("donate-finish")
    }
    func delete(groupIdentifier: String) async throws {
        if failDeletion { throw CocoaError(.fileWriteUnknown) }
        events.append("delete-group")
        records = records.filter { $0.value.groupIdentifier != groupIdentifier }
        groupDeletionObserver?()
    }
    func delete(identifiers: [String]) async throws {
        if failDeletion { throw CocoaError(.fileWriteUnknown) }
        events.append("delete-identifiers")
        for identifier in identifiers { records.removeValue(forKey: identifier) }
    }
}

private final class SuggestionTestGroups: ShareSuggestionGroupStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var groups: Set<String>
    init(_ groups: Set<String> = []) { self.groups = groups }
    func load() -> Set<String> { lock.withLock { groups } }
    func save(_ groups: Set<String>) { lock.withLock { self.groups = groups } }
}

private final class SuggestionTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var date: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
