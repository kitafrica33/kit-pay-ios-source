import XCTest
@testable import KitPay

final class ConversationInteractionPolicyTests: XCTestCase {
    private func message(
        _ body: String,
        pendingCaption: String? = nil,
        hasPendingAttachment: Bool = false
    ) -> LocalMessage {
        LocalMessage(
            id: UUID(),
            conversationId: "30000000-0000-0000-0000-000000000001",
            senderId: "10000000-0000-0000-0000-000000000001",
            body: body,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sentAt: nil,
            state: .sent,
            failureReason: nil,
            isOutgoing: true,
            attachmentData: nil,
            pendingAttachment: hasPendingAttachment
                ? LocalPendingAttachment(mediaType: "image/jpeg", caption: pendingCaption)
                : nil
        )
    }

    func testSearchMatchesPlainTextCaseAndDiacriticInsensitively() {
        let hit = message("Chapati funds for Kampala")
        let miss = message("Completely unrelated")
        let ids = ConversationMessageSearchPolicy.matchingMessageIDs(
            query: "  KAMPALÁ ",
            messages: [hit, miss]
        )
        XCTAssertEqual(ids, [hit.id])
    }

    func testSearchIgnoresBlankQueriesAndPaymentDescriptors() {
        guard let descriptor = KitPaymentMessage(
            action: .request,
            paymentRequestId: "9c14e2c6-1f6a-4a6a-9f7e-6a1e2b3c4d5e",
            amountMinor: 1_000,
            currencyCode: "UGX",
            currencyScale: 2,
            note: "lunch"
        ) else {
            XCTFail("Canonical payment descriptor must construct")
            return
        }
        let payment = message(descriptor.encoded)
        XCTAssertEqual(
            ConversationMessageSearchPolicy.matchingMessageIDs(
                query: "   ",
                messages: [payment]
            ),
            []
        )
        XCTAssertNil(ConversationMessageSearchPolicy.searchableText(for: payment))
    }

    func testSearchReadsPendingAttachmentCaptions() {
        let pending = message("Photo", pendingCaption: "Quarterly report.pdf", hasPendingAttachment: true)
        let ids = ConversationMessageSearchPolicy.matchingMessageIDs(
            query: "quarterly",
            messages: [pending]
        )
        XCTAssertEqual(ids, [pending.id])
    }

    func testSearchResultsStayChronological() {
        let first = message("alpha budget")
        let second = message("beta budget")
        let ids = ConversationMessageSearchPolicy.matchingMessageIDs(
            query: "budget",
            messages: [first, second]
        )
        XCTAssertEqual(ids, [first.id, second.id])
    }

    func testCameraPullThresholdsAreOrdered() {
        XCTAssertGreaterThan(
            ConversationCameraPullPolicy.triggerDistance,
            ConversationCameraPullPolicy.nearLatestDistance
        )
        XCTAssertGreaterThan(
            ConversationCameraPullPolicy.nearLatestDistance,
            ConversationCameraPullPolicy.rearmDistance
        )
    }

    func testCameraPullEligibilityRequiresScrollableIdleTimeline() {
        XCTAssertTrue(ConversationCameraPullPolicy.isEligible(
            contentHeight: 700,
            viewportHeight: 600,
            isSelectingMessages: false,
            isSearchingMessages: false,
            isRecordingVoiceNote: false,
            isComposerFocused: false
        ))

        XCTAssertFalse(ConversationCameraPullPolicy.isEligible(
            contentHeight: 500,
            viewportHeight: 600,
            isSelectingMessages: false,
            isSearchingMessages: false,
            isRecordingVoiceNote: false,
            isComposerFocused: false
        ), "A short timeline must not offer the camera pull gesture")
        XCTAssertFalse(ConversationCameraPullPolicy.isEligible(
            contentHeight: 700,
            viewportHeight: 600,
            isSelectingMessages: true,
            isSearchingMessages: false,
            isRecordingVoiceNote: false,
            isComposerFocused: false
        ), "Message selection must own the conversation gesture")
        XCTAssertFalse(ConversationCameraPullPolicy.isEligible(
            contentHeight: 700,
            viewportHeight: 600,
            isSelectingMessages: false,
            isSearchingMessages: true,
            isRecordingVoiceNote: false,
            isComposerFocused: false
        ), "Search must not advertise or open the camera")
        XCTAssertFalse(ConversationCameraPullPolicy.isEligible(
            contentHeight: 700,
            viewportHeight: 600,
            isSelectingMessages: false,
            isSearchingMessages: false,
            isRecordingVoiceNote: true,
            isComposerFocused: false
        ), "Voice recording must not be interrupted by the camera")
        XCTAssertFalse(ConversationCameraPullPolicy.isEligible(
            contentHeight: 700,
            viewportHeight: 600,
            isSelectingMessages: false,
            isSearchingMessages: false,
            isRecordingVoiceNote: false,
            isComposerFocused: true
        ), "Composer and keyboard focus must suppress the camera pull gesture")
    }

    func testCameraOpensOnTheReleaseTheIndicatorPromisesAndNotMidDrag() {
        var gesture = ConversationCameraPullGesture()
        let trigger = ConversationCameraPullPolicy.triggerDistance

        XCTAssertFalse(gesture.overscrolled(to: trigger - 1))
        XCTAssertFalse(gesture.isArmed, "Short of the threshold nothing is promised")

        XCTAssertTrue(
            gesture.overscrolled(to: trigger),
            "Crossing the threshold is the one moment the haptic fires"
        )
        XCTAssertTrue(gesture.isArmed, "The indicator now reads Release for camera")
        XCTAssertFalse(
            gesture.overscrolled(to: trigger + 40),
            "Pulling further must not fire the haptic again"
        )
        XCTAssertTrue(gesture.isArmed, "Still only armed — the finger has not come up")

        XCTAssertTrue(gesture.released(), "The release is what opens the camera")
        XCTAssertFalse(gesture.isArmed)
    }

    func testAPullTakenBackBeforeReleasingDoesNotOpenTheCamera() {
        var gesture = ConversationCameraPullGesture()
        _ = gesture.overscrolled(to: ConversationCameraPullPolicy.triggerDistance)
        XCTAssertTrue(gesture.isArmed)

        gesture.dragged(progress: ConversationCameraPullPolicy.triggerDistance - 1)
        XCTAssertTrue(gesture.isArmed, "Easing off is not the same as changing your mind")

        gesture.dragged(progress: 0)
        XCTAssertFalse(gesture.isArmed)
        XCTAssertFalse(gesture.released(), "Pulled all the way back: nothing should open")
    }

    func testTheBounceBackToRestCannotSwallowAnArmedRelease() {
        // The release and the bounce that follows it both drive the overscroll to zero. Only the
        // drag may disarm, so the order of those two events cannot decide whether the camera opens.
        var gesture = ConversationCameraPullGesture()
        _ = gesture.overscrolled(to: ConversationCameraPullPolicy.triggerDistance + 30)
        XCTAssertFalse(
            gesture.overscrolled(to: 0),
            "Settling back to rest is not a gesture the customer made"
        )
        XCTAssertTrue(gesture.isArmed)
        XCTAssertTrue(gesture.released())
    }

    func testAnArmedPullLeftOverFromACancelledGestureIsDroppedAtTheNextDrag() {
        var gesture = ConversationCameraPullGesture()
        _ = gesture.overscrolled(to: ConversationCameraPullPolicy.triggerDistance)
        XCTAssertTrue(gesture.isArmed)

        // A new drag starts from rest, so a stale arm can never survive into it and open the
        // camera on a release the customer never associated with the camera.
        gesture.dragged(progress: 0)
        XCTAssertFalse(gesture.released())
    }

    func testLeavingTheGestureBehindDisarmsIt() {
        var gesture = ConversationCameraPullGesture()
        _ = gesture.overscrolled(to: ConversationCameraPullPolicy.triggerDistance)
        gesture.cancel()
        XCTAssertFalse(gesture.isArmed)
        XCTAssertFalse(gesture.released())
    }

    func testAttachmentStagingCapAllowsAlbums() {
        XCTAssertGreaterThanOrEqual(
            ConversationAttachmentStagingPolicy.maximumStagedAttachments,
            5
        )
    }

    func testGroupPickerExcludesSelfBlockedAndDuplicateContacts() {
        let currentUserID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let allowedUserID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let blockedUserID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let contacts = [
            contact(id: currentUserID, name: "Me"),
            contact(id: allowedUserID, name: "Allowed"),
            contact(id: allowedUserID.uppercased(), name: "Allowed duplicate"),
            contact(id: blockedUserID, name: "Blocked"),
        ]

        let eligible = GroupCreatePolicy.eligibleContacts(
            contacts,
            currentUserID: currentUserID,
            allowsOutbound: { $0 != blockedUserID }
        )

        XCTAssertEqual(eligible.map(\.name), ["Allowed"])
    }

    func testGroupPolicyMatchesServerMemberAndUnicodeScalarBounds() {
        XCTAssertEqual(SecureMessagingWire.maximumGroupMembers, 32)
        XCTAssertEqual(GroupCreatePolicy.minimumMembers, 1)
        XCTAssertEqual(GroupCreatePolicy.maximumMembers, 31)
        XCTAssertTrue(GroupCreatePolicy.isValidName("A"))
        XCTAssertTrue(GroupCreatePolicy.isValidName(String(repeating: "🟢", count: 30)))
        XCTAssertFalse(GroupCreatePolicy.isValidName(String(repeating: "🟢", count: 31)))
        XCTAssertFalse(GroupCreatePolicy.isValidName("   "))

        let combining = String(repeating: "e\u{301}", count: 33)
        XCTAssertEqual(combining.count, 33)
        XCTAssertEqual(combining.unicodeScalars.count, 66)
        XCTAssertEqual(combining.utf8.count, 99)
        XCTAssertFalse(GroupCreatePolicy.isValidName(combining))
    }

    private func contact(id: String, name: String) -> WalletContactDTO {
        WalletContactDTO(
            id: id,
            contactId: nil,
            name: name,
            phone: "+256700000000",
            isKitUser: true,
            favorite: false,
            status: nil,
            tag: nil,
            avatarURL: nil,
            receivingWalletId: nil
        )
    }
}
