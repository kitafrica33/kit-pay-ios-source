import XCTest
@testable import KitPay

final class MessageDeliveryInfoTests: XCTestCase {
    private let conversation = "30000000-0000-0000-0000-000000000001"
    private let message = "40000000-0000-0000-0000-000000000001"
    private let userA = "10000000-0000-0000-0000-00000000000a"
    private let userB = "10000000-0000-0000-0000-00000000000b"

    private let sentAt = "2026-08-26T09:00:00Z"

    // MARK: - A response that says what it should

    func testAGroupResponseKeepsEveryPersonAndTheirOwnMoments() throws {
        let info = try XCTUnwrap(map(response(recipients: [
            recipient(
                userA,
                name: "Amara",
                deliveredAt: "2026-08-26T09:00:04Z",
                readAt: "2026-08-26T09:11:00Z"
            ),
            recipient(userB, name: "Ben", deliveredAt: "2026-08-26T09:00:09Z", readAt: nil),
        ])))

        XCTAssertEqual(info.messageID, message)
        XCTAssertEqual(info.conversationID, conversation)
        XCTAssertEqual(info.sentAt, try XCTUnwrap(moment("2026-08-26T09:00:00Z")))
        XCTAssertEqual(info.recipients.map(\.userID), [userA, userB])
        XCTAssertEqual(info.recipients.map(\.serverName), ["Amara", "Ben"])
        XCTAssertEqual(info.recipients[0].readAt, moment("2026-08-26T09:11:00Z"))
        XCTAssertNil(info.recipients[1].readAt)
        XCTAssertEqual(info.receivedCount, 2)
        XCTAssertEqual(info.readCount, 1)
        XCTAssertTrue(info.everyoneReceived)
        XCTAssertFalse(info.everyoneRead)
    }

    /// A moment the server has not witnessed is not a broken response. Whether the key is absent
    /// or explicitly null, the answer is the same: not yet.
    func testAnUnwitnessedMomentIsCarriedRatherThanRefused() throws {
        let absent = try XCTUnwrap(map(response(recipients: [
            ["user_id": userA, "name": "Amara"],
        ])))
        XCTAssertNil(absent.recipients[0].deliveredAt)
        XCTAssertNil(absent.recipients[0].readAt)
        XCTAssertEqual(absent.receivedCount, 0)
        XCTAssertFalse(absent.everyoneReceived)

        let explicitNull = try XCTUnwrap(map(response(recipients: [
            recipient(userA, name: "Amara", deliveredAt: nil, readAt: nil),
        ])))
        XCTAssertEqual(explicitNull.recipients, absent.recipients)
    }

    /// The server sends microseconds to devices that can read them and whole seconds to the rest.
    func testBothTimestampSpellingsParse() throws {
        let info = try XCTUnwrap(map(response(recipients: [
            recipient(userA, name: "Amara", deliveredAt: "2026-08-26T09:00:04.512345Z", readAt: nil),
        ])))
        let delivered = try XCTUnwrap(info.recipients[0].deliveredAt)
        XCTAssertEqual(delivered.timeIntervalSince(info.sentAt), 4.512345, accuracy: 0.0005)
    }

    /// A thread nobody else is in reports neither delivered nor read, rather than a hopeful pair
    /// of ticks about an audience of no one.
    // MARK: - A response that should not be read at all

    /// A message this account sent went to somebody. An empty list is the server declining to say
    /// rather than reporting that nobody was addressed, and a screen headed "Read by 0 of 0"
    /// states that absence as though it were a finding.
    func testAResponseThatNamesNobodyIsRefused() {
        XCTAssertNil(map(response(recipients: [])))
    }

    func testAResponseAboutAnotherMessageIsRefused() {
        XCTAssertNil(map(response(messageID: "40000000-0000-0000-0000-000000000002")))
        XCTAssertNil(map(response(conversationID: "30000000-0000-0000-0000-000000000002")))
    }

    func testNonCanonicalIdentifiersAreRefused() {
        XCTAssertNil(
            map(
                response(messageID: "40000000-0000-0000-0000-00000000000A"),
                expectedMessageID: "40000000-0000-0000-0000-00000000000A"
            )
        )
        XCTAssertNil(map(response(recipients: [
            recipient("not-a-uuid", name: "Amara", deliveredAt: nil, readAt: nil),
        ])))
    }

    func testARepeatedPersonIsRefused() {
        XCTAssertNil(map(response(recipients: [
            recipient(userA, name: "Amara", deliveredAt: nil, readAt: nil),
            recipient(userA, name: "Amara on a laptop", deliveredAt: nil, readAt: nil),
        ])))
    }

    /// Nothing can be delivered or read before it was sent.
    func testAMomentThatPredatesTheMessageIsRefused() {
        XCTAssertNil(map(response(recipients: [
            recipient(userA, name: "Amara", deliveredAt: "2026-08-26T08:59:59Z", readAt: nil),
        ])))
        XCTAssertNil(map(response(recipients: [
            recipient(userA, name: "Amara", deliveredAt: nil, readAt: "2026-08-26T08:00:00Z"),
        ])))
    }

    func testAnUnreadableMomentIsRefusedRatherThanTreatedAsNotYet() {
        XCTAssertNil(map(response(recipients: [
            recipient(userA, name: "Amara", deliveredAt: "yesterday", readAt: nil),
        ])))
        // Carries a valid recipient, so the refusal can only be the unreadable sent moment.
        XCTAssertNil(map(response(
            sentAt: "26 August 2026",
            recipients: [recipient(userA, name: "Amara", deliveredAt: nil, readAt: nil)]
        )))
    }

    func testANamelessOrOversizedNameIsRefused() {
        XCTAssertNil(map(response(recipients: [["user_id": userA]])))
        XCTAssertNil(map(response(recipients: [
            recipient(userA, name: "   ", deliveredAt: nil, readAt: nil),
        ])))
        XCTAssertNil(map(response(recipients: [
            recipient(userA, name: String(repeating: "n", count: 257), deliveredAt: nil, readAt: nil),
        ])))
    }

    /// Nobody opens a message that never arrived. A read moment without a delivery, or one that
    /// precedes it, describes a sequence of events that cannot have happened, and the sensible
    /// reading of an impossible record is that it is not a record.
    func testAMessageReadBeforeItArrivedIsRefused() {
        XCTAssertNil(map(response(recipients: [
            recipient(
                userA,
                name: "Amara",
                deliveredAt: nil,
                readAt: "2026-08-26T09:04:00Z"
            ),
        ])))
        XCTAssertNil(map(response(recipients: [
            recipient(
                userA,
                name: "Amara",
                deliveredAt: "2026-08-26T09:04:00Z",
                readAt: "2026-08-26T09:01:00Z"
            ),
        ])))
    }

    /// A direct chat has exactly one counterpart, and membership of one cannot change, so anybody
    /// else named in the reply is somebody the server invented.
    func testADirectResponseIsPinnedToItsOnlyPossibleRecipient() throws {
        let onlyA = [recipient(userA, name: "Amara", deliveredAt: nil, readAt: nil)]
        let info = try XCTUnwrap(
            map(response(recipients: onlyA), expectedRecipientIDs: [userA])
        )
        XCTAssertEqual(info.recipients.map(\.userID), [userA])

        // Somebody this thread never had, and the right person plus an invented one.
        XCTAssertNil(map(
            response(recipients: [recipient(userB, name: "Ben", deliveredAt: nil, readAt: nil)]),
            expectedRecipientIDs: [userA]
        ))
        XCTAssertNil(map(
            response(
                recipients: onlyA + [recipient(userB, name: "Ben", deliveredAt: nil, readAt: nil)]
            ),
            expectedRecipientIDs: [userA]
        ))
    }

    /// Deliberately unpinned. A group's record is historical to the message: somebody who has
    /// since left is rightly still named, and somebody who joined afterwards is rightly absent.
    /// Measuring a group against the roster as it stands now would reject both truths.
    func testAGroupResponseIsNotMeasuredAgainstTodaysRoster() throws {
        let info = try XCTUnwrap(map(
            response(recipients: [
                recipient(userA, name: "Amara", deliveredAt: nil, readAt: nil),
                recipient(userB, name: "Ben", deliveredAt: nil, readAt: nil),
            ]),
            expectedRecipientIDs: nil
        ))

        XCTAssertEqual(info.recipients.count, 2)
    }

    /// The server's own ceiling on a group, so a response cannot ask the screen to render an
    /// unbounded list of strangers.
    func testMoreRecipientsThanAGroupCanHoldIsRefused() {
        let full = (0..<SecureMessagingWire.maximumGroupMembers).map { index in
            recipient(userID(index), name: "Member \(index)", deliveredAt: nil, readAt: nil)
        }
        XCTAssertNotNil(map(response(recipients: full)))
        XCTAssertNil(
            map(
                response(
                    recipients: full + [
                        recipient(
                            userID(SecureMessagingWire.maximumGroupMembers),
                            name: "One too many",
                            deliveredAt: nil,
                            readAt: nil
                        ),
                    ]
                )
            )
        )
    }

    // MARK: - How a moment is written

    func testTodayAndYesterdayAreNamedRatherThanDated() throws {
        let now = try XCTUnwrap(reference(day: 26, hour: 18))
        let earlierToday = try XCTUnwrap(reference(day: 26, hour: 9))
        let yesterday = try XCTUnwrap(reference(day: 25, hour: 23))

        XCTAssertTrue(label(earlierToday, now: now).hasPrefix("Today at "))
        XCTAssertTrue(label(yesterday, now: now).hasPrefix("Yesterday at "))
    }

    func testAnOlderMomentIsDatedAndOnlyCarriesTheYearWhenItDiffers() throws {
        let now = try XCTUnwrap(reference(day: 26, hour: 18))
        let lastWeek = try XCTUnwrap(reference(day: 19, hour: 10))
        let lastYear = try XCTUnwrap(reference(year: 2025, day: 19, hour: 10))

        let recent = label(lastWeek, now: now)
        XCTAssertFalse(recent.hasPrefix("Today"))
        XCTAssertFalse(recent.hasPrefix("Yesterday"))
        XCTAssertTrue(recent.contains("19"))
        XCTAssertTrue(recent.contains(" at "))
        XCTAssertFalse(recent.contains("2026"))

        XCTAssertTrue(label(lastYear, now: now).contains("2025"))
    }

    // MARK: - Helpers

    private func map(
        _ payload: [String: Any],
        expectedConversationID: String? = nil,
        expectedMessageID: String? = nil,
        expectedRecipientIDs: Set<String>? = nil
    ) -> MessageDeliveryInfo? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let response = try? JSONDecoder().decode(MessagingMessageInfoDTO.self, from: data)
        else { return nil }
        return MessageDeliveryInfoMapper.make(
            response,
            expectedConversationID: expectedConversationID ?? conversation,
            expectedMessageID: expectedMessageID ?? message,
            expectedRecipientIDs: expectedRecipientIDs
        )
    }

    private func response(
        messageID: String? = nil,
        conversationID: String? = nil,
        sentAt: String? = nil,
        recipients: [[String: Any]] = []
    ) -> [String: Any] {
        [
            "message_id": messageID ?? message,
            "conversation_id": conversationID ?? conversation,
            "sent_at": sentAt ?? self.sentAt,
            "recipients": recipients,
        ]
    }

    private func recipient(
        _ userID: String,
        name: String,
        deliveredAt: String?,
        readAt: String?
    ) -> [String: Any] {
        [
            "user_id": userID,
            "name": name,
            "delivered_at": deliveredAt ?? NSNull(),
            "read_at": readAt ?? NSNull(),
        ]
    }

    private func userID(_ index: Int) -> String {
        String(format: "10000000-0000-0000-0000-%012x", index)
    }

    private func moment(_ rawValue: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: rawValue)
    }

    private var fixedCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private func reference(year: Int = 2026, day: Int, hour: Int) -> Date? {
        fixedCalendar.date(
            from: DateComponents(year: year, month: 8, day: day, hour: hour, minute: 32)
        )
    }

    private func label(_ moment: Date, now: Date) -> String {
        MessageDeliveryMomentFormatter.label(
            for: moment,
            now: now,
            calendar: fixedCalendar,
            locale: Locale(identifier: "en_GB")
        )
    }
}
