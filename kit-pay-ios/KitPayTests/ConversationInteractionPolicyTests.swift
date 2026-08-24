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

    func testAttachmentStagingCapAllowsAlbums() {
        XCTAssertGreaterThanOrEqual(
            ConversationAttachmentStagingPolicy.maximumStagedAttachments,
            5
        )
    }
}
