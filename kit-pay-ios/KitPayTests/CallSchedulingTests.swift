import Foundation
import XCTest
@testable import KitPay

final class CallSchedulingTests: XCTestCase {
    private let organizerID = "11111111-1111-4111-8111-111111111111"
    private let recipientID = "22222222-2222-4222-8222-222222222222"
    private let callID = "33333333-3333-4333-8333-333333333333"
    private let token = String(repeating: "Ab09", count: 16)

    func testInvitationURLAcceptsOnlyTheCanonicalAudienceTokenRoute() throws {
        XCTAssertEqual(CallInvitationLink.token(from: try XCTUnwrap(URL(string: "kitpay://call-invites/\(token)"))), token)
        for invalid in [
            "kitwallet://call-invites/\(token)",
            "https://call-invites/\(token)",
            "kitpay://other/\(token)",
            "kitpay://call-invites/\(token)/",
            "kitpay://call-invites/\(token)?join=true",
            "kitpay://call-invites/\(token)#join",
            "kitpay://user@call-invites/\(token)",
            "kitpay://call-invites:443/\(token)",
            "kitpay://call-invites/%41\(token.dropFirst())",
            "kitpay://call-invites/\(token.dropFirst())",
            "kitpay://call-invites/\(token)A",
        ] {
            XCTAssertNil(CallInvitationLink.token(from: try XCTUnwrap(URL(string: invalid))), invalid)
        }
        XCTAssertFalse(CallInvitationLink.validToken(String(repeating: "é", count: 64)))
        XCTAssertFalse(CallInvitationLink.validToken(String(repeating: "_", count: 64)))
        XCTAssertFalse(CallInvitationLink.validToken(token + "\n"))
    }

    func testFirstSignedOutInvitationSurvivesLaterLinksUntilAccountBinding() {
        var inbox = CallInvitationInbox()
        inbox.receive(token: token, accountID: nil)
        let firstID = inbox.pending?.id
        inbox.receive(token: String(repeating: "B", count: 64), accountID: nil)
        XCTAssertEqual(inbox.pending?.id, firstID)
        XCTAssertEqual(inbox.pending?.token, token)

        inbox.bind(to: organizerID.uppercased())
        XCTAssertEqual(inbox.pending?.accountID, organizerID)
        inbox.bind(to: recipientID)
        XCTAssertNil(inbox.pending)
    }

    func testClearedInvitationCannotReappearAfterAccountChangeOrUnlock() {
        var inbox = CallInvitationInbox()
        inbox.receive(token: token, accountID: organizerID)
        inbox.clear()
        inbox.bind(to: recipientID)
        XCTAssertNil(inbox.pending)
        inbox.receive(token: "invalid", accountID: recipientID)
        XCTAssertNil(inbox.pending)
    }

    func testShareURLMustContainExactlyTheReturnedToken() throws {
        let fixture: [String: Any] = ["id": callID, "token": token,
            "share_url": "kitpay://call-invites/\(token)", "expires_at": "2026-09-08T10:00:00Z"]
        let valid = try decode(CallInviteLinkDTO.self, fixture)
        XCTAssertNotNil(valid.validatedShareURL)
        var changed = fixture
        changed["share_url"] = "kitpay://call-invites/\(String(repeating: "X", count: 64))"
        XCTAssertNil(try decode(CallInviteLinkDTO.self, changed).validatedShareURL)
        changed["share_url"] = "https://example.test/\(token)"
        XCTAssertNil(try decode(CallInviteLinkDTO.self, changed).validatedShareURL)
    }

    func testCreateRequestKeepsItsCommandUUIDAndUTCInstantForRetries() throws {
        let instant = try XCTUnwrap(CallSchedulingPolicy.date("2026-11-01T01:30:00-04:00"))
        let request = CreateScheduledCallRequest(clientScheduleId: callID, recipientUserIds: [recipientID],
            type: .video, startsAt: CallSchedulingPolicy.timestamp(instant), title: "Planning", conversationId: nil)
        let first = try body(request)
        let retried = try body(request)
        XCTAssertEqual(first as NSDictionary, retried as NSDictionary)
        XCTAssertEqual(first["client_schedule_id"] as? String, callID)
        XCTAssertEqual(first["starts_at"] as? String, "2026-11-01T05:30:00Z")
        XCTAssertEqual(first["recipient_user_ids"] as? [String], [recipientID])
        XCTAssertEqual(first["type"] as? String, "video")
        XCTAssertNil(first["clientScheduleId"])
        XCTAssertFalse(CallSchedulingPolicy.validNewStart(instant, now: instant.addingTimeInterval(60)))
        XCTAssertEqual(request.startsAt, "2026-11-01T05:30:00Z")
    }

    func testScheduleEditCarriesRevisionAndExplicitNullToClearTitle() throws {
        let request = UpdateScheduledCallRequest(revision: 7, recipientUserIds: [recipientID],
            startsAt: "2026-09-08T10:00:00Z", title: nil)
        let encoded = try body(request)
        XCTAssertEqual(encoded["revision"] as? Int, 7)
        XCTAssertTrue(encoded["title"] is NSNull)
        XCTAssertEqual(encoded["recipient_user_ids"] as? [String], [recipientID])
        XCTAssertNil(encoded["type"])
    }

    func testSelectionRejectsSelfDuplicatesInvalidUUIDAndMoreThanTwentyPeople() {
        let one = CallRecipientChoice(id: recipientID, name: "One")
        XCTAssertEqual(CallSchedulingPolicy.recipientIDs([one], excluding: organizerID), [recipientID])
        XCTAssertNil(CallSchedulingPolicy.recipientIDs([], excluding: organizerID))
        XCTAssertNil(CallSchedulingPolicy.recipientIDs([one], excluding: recipientID))
        XCTAssertNil(CallSchedulingPolicy.recipientIDs([one, CallRecipientChoice(id: recipientID.uppercased(), name: "Duplicate")], excluding: organizerID))
        XCTAssertNil(CallSchedulingPolicy.recipientIDs([CallRecipientChoice(id: "../calls", name: "Invalid")], excluding: organizerID))
        let choices = (0 ..< 21).map { CallRecipientChoice(id: UUID().uuidString, name: "Person \($0)") }
        XCTAssertNotNil(CallSchedulingPolicy.recipientIDs(Array(choices.prefix(20)), excluding: organizerID))
        XCTAssertNil(CallSchedulingPolicy.recipientIDs(choices, excluding: organizerID))
    }

    func testNewStartMustBeFutureAndWithinOneYear() throws {
        let now = try XCTUnwrap(CallSchedulingPolicy.date("2026-09-07T12:00:00Z"))
        XCTAssertFalse(CallSchedulingPolicy.validNewStart(now, now: now))
        XCTAssertFalse(CallSchedulingPolicy.validNewStart(now.addingTimeInterval(-1), now: now))
        XCTAssertTrue(CallSchedulingPolicy.validNewStart(now.addingTimeInterval(3600), now: now))
        XCTAssertFalse(CallSchedulingPolicy.validNewStart(now.addingTimeInterval(367 * 86_400), now: now))
    }

    func testScheduleDecodesUTCParticipantResponsesAndOrganizer() throws {
        let schedule = try decode(ScheduledCallDTO.self, scheduleFixture())
        XCTAssertEqual(schedule.type, .voice)
        XCTAssertEqual(schedule.myResponse, .invited)
        XCTAssertEqual(schedule.participants.map(\.response), [.accepted, .invited])
        XCTAssertTrue(schedule.isOrganizer(organizerID.uppercased()))
        XCTAssertFalse(schedule.isOrganizer(recipientID))
        XCTAssertNotNil(schedule.startDate)
        XCTAssertTrue(schedule.status.isPending)
    }

    func testMalformedScheduleCannotOfferActionsWithMissingRevisionOrLiveCallID() throws {
        var missingRevision = scheduleFixture()
        missingRevision.removeValue(forKey: "revision")
        XCTAssertThrowsError(try decode(ScheduledCallDTO.self, missingRevision))
        var zeroRevision = scheduleFixture()
        zeroRevision["revision"] = 0
        XCTAssertThrowsError(try decode(ScheduledCallDTO.self, zeroRevision))
        var started = scheduleFixture()
        started["status"] = "started"
        XCTAssertThrowsError(try decode(ScheduledCallDTO.self, started))
        started["call_id"] = callID
        XCTAssertEqual(try decode(ScheduledCallDTO.self, started).callId, callID)
        var unknown = scheduleFixture()
        unknown["status"] = "unknown"
        XCTAssertThrowsError(try decode(ScheduledCallDTO.self, unknown))
        var badTime = scheduleFixture()
        badTime["starts_at"] = "next week"
        XCTAssertThrowsError(try decode(ScheduledCallDTO.self, badTime))
    }

    func testFutureInvitationHasNoLiveJoinTargetButStartedScheduleDoes() throws {
        var fixture: [String: Any] = ["kind": "scheduled_call", "scheduled_call": scheduleFixture(),
            "expires_at": "2026-09-08T10:05:45Z", "server_time": "2026-09-07T12:00:00Z"]
        XCTAssertNil(try decode(CallInviteInspectionDTO.self, fixture).liveCallID)
        var started = scheduleFixture()
        started["status"] = "started"
        started["call_id"] = callID
        fixture["scheduled_call"] = started
        XCTAssertEqual(try decode(CallInviteInspectionDTO.self, fixture).liveCallID, callID)
    }

    private func scheduleFixture() -> [String: Any] {
        ["id": "44444444-4444-4444-8444-444444444444", "client_schedule_id": callID,
         "organizer_user_id": organizerID, "title": "Planning", "type": "voice",
         "starts_at": "2026-09-08T10:00:00Z", "status": "scheduled", "revision": 1,
         "my_response": "invited", "server_time": "2026-09-07T12:00:00Z",
         "participants": [["user_id": organizerID, "name": "Organizer", "response": "accepted"],
                          ["user_id": recipientID, "name": "Recipient", "response": "invited"]]]
    }

    private func decode<T: Decodable>(_ type: T.Type, _ fixture: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: fixture))
    }
    private func body<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
}
