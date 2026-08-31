import XCTest
@testable import KitPay

/// What crosses the boundary between the system share sheet and Kit Pay.
///
/// The share extension is a separate process with its own copy of these rules, so the constants it
/// relies on are pinned here to the ones the app actually enforces. A wire change that forgot the
/// extension would otherwise only be discovered by a customer whose share went nowhere.
final class SharedInboxTests: XCTestCase {
    private let accountID = "10000000-0000-4000-8000-000000000001"
    private let otherAccountID = "20000000-0000-4000-8000-000000000002"

    // MARK: The two copies of the contract agree

    func testShareLimitsMatchTheLimitsTheAppEnforces() {
        XCTAssertEqual(
            SharedInboxPolicy.maximumBytes,
            SecureMediaAttachmentCipher.maximumPlaintextBytes,
            "A share the extension accepted must be a share the wire can carry"
        )
        XCTAssertEqual(
            SharedInboxPolicy.maximumItems,
            ConversationAttachmentStagingPolicy.maximumStagedAttachments,
            "A share the extension accepted must fit in the composer it lands in"
        )
    }

    func testShareAllowlistMatchesTheWireAllowlist() {
        XCTAssertEqual(
            SharedInboxPolicy.allowedMediaTypes,
            SecureMessagingWire.allowedAttachmentMediaTypes
        )
    }

    func testHandoffLinkUsesTheSchemeTheAppIsRegisteredFor() {
        XCTAssertEqual(KitShareHandoffLink.url?.scheme, KitDeepLink.scheme)
        XCTAssertNotNil(KitShareHandoffLink.url)
        XCTAssertTrue(KitShareHandoffLink.matches(KitShareHandoffLink.url!))
        XCTAssertTrue(KitShareHandoffLink.matches(URL(string: "KitWallet://SHARE")!))
        XCTAssertFalse(KitShareHandoffLink.matches(URL(string: "kitwallet://verify?token=x")!))
        XCTAssertFalse(KitShareHandoffLink.matches(URL(string: "https://kit.africa/share")!))
    }

    /// The hand-off must not be able to reach a pre-authentication screen, and a verification link
    /// must not be able to open the share inbox.
    func testHandoffLinkIsNotADeepLink() {
        XCTAssertNil(KitDeepLink.parse(KitShareHandoffLink.url!))
    }

    // MARK: Hand-off attempt lifecycle

    private func step(
        _ phase: KitShareHandoffAttempt.Phase,
        _ event: KitShareHandoffAttempt.Event
    ) -> (phase: KitShareHandoffAttempt.Phase, decision: KitShareHandoffAttempt.Decision) {
        KitShareHandoffAttempt.decide(phase: phase, event: event)
    }

    /// The original bug: completing the extension before iOS answered the open request tore the
    /// process down and the app never came forward. The machine only finishes after acceptance.
    func testHandoffCompletesTheExtensionOnlyAfterIOSAcceptsTheOpen() {
        let attempt = step(.queued, .attemptRequested(canOpen: true))
        XCTAssertEqual(attempt.phase, .opening)
        XCTAssertEqual(attempt.decision, .attemptOpen)

        let accepted = step(attempt.phase, .openResolved(opened: true))
        XCTAssertEqual(accepted.phase, .finished)
        XCTAssertEqual(accepted.decision, .finishExtension)
    }

    /// A declined or timed-out open keeps the sheet alive with the queued state, and the explicit
    /// retry starts a fresh attempt — the batch is durable, so nothing is lost in between.
    func testHandoffDeclineOrTimeoutKeepsTheSheetAliveAndAllowsRetry() {
        let declined = step(.opening, .openResolved(opened: false))
        XCTAssertEqual(declined.phase, .queued)
        XCTAssertEqual(declined.decision, .offerManualHandoff)

        let retry = step(declined.phase, .attemptRequested(canOpen: true))
        XCTAssertEqual(retry.phase, .opening)
        XCTAssertEqual(retry.decision, .attemptOpen)
    }

    /// After the timeout already resolved the attempt as declined, a late acceptance must not
    /// complete the request underneath the manual hand-off UI the customer is reading.
    func testHandoffIgnoresAnAcceptanceThatArrivesAfterTheTimeoutResolvedIt() {
        let late = step(.queued, .openResolved(opened: true))
        XCTAssertEqual(late.phase, .queued)
        XCTAssertEqual(late.decision, .ignore)
    }

    /// While one open is in flight, another tap (or the automatic attempt racing a tap) must not
    /// issue a second open, and "Not now" must not complete a request the open may still win.
    func testHandoffIsReentrancySafeWhileAnOpenIsInFlight() {
        let doubleTap = step(.opening, .attemptRequested(canOpen: true))
        XCTAssertEqual(doubleTap.phase, .opening)
        XCTAssertEqual(doubleTap.decision, .ignore)

        let notNowWhileOpening = step(.opening, .notNowTapped)
        XCTAssertEqual(notNowWhileOpening.phase, .opening)
        XCTAssertEqual(notNowWhileOpening.decision, .ignore)
    }

    /// "Not now" is always safe from the queued state: the batch is already durable, so the
    /// extension completes without opening and Kit Pay finds the share on its next launch.
    func testHandoffNotNowCompletesWithoutOpeningBecauseTheBatchIsDurable() {
        let notNow = step(.queued, .notNowTapped)
        XCTAssertEqual(notNow.phase, .finished)
        XCTAssertEqual(notNow.decision, .finishExtension)
    }

    /// Without a usable link or extension context the attempt degrades straight to the manual
    /// hand-off; and once finished, every further event — late completions, stray taps, a stray
    /// timeout — is inert, so the request can never be completed twice.
    func testHandoffDegradesWithoutALinkAndIsInertOnceFinished() {
        let cannotOpen = step(.queued, .attemptRequested(canOpen: false))
        XCTAssertEqual(cannotOpen.phase, .queued)
        XCTAssertEqual(cannotOpen.decision, .offerManualHandoff)

        for event in [
            KitShareHandoffAttempt.Event.attemptRequested(canOpen: true),
            .attemptRequested(canOpen: false),
            .openResolved(opened: true),
            .openResolved(opened: false),
            .notNowTapped,
        ] {
            let after = step(.finished, event)
            XCTAssertEqual(after.phase, .finished)
            XCTAssertEqual(after.decision, .ignore)
        }
    }

    /// The app group is named in three places — this constant and both entitlement files. Locking
    /// the value here makes a rename fail in CI rather than silently in the customer's container.
    func testAppGroupIdentifierIsTheOneBothTargetsAreEntitledFor() {
        XCTAssertEqual(KitAppGroup.identifier, "group.africa.kit.pay.ios")
    }

    // MARK: What a shared file travels as

    func testKnownMediaTypesAreKeptExactly() {
        XCTAssertEqual(SharedInboxPolicy.normalizedMediaType("application/pdf"), "application/pdf")
        XCTAssertEqual(SharedInboxPolicy.normalizedMediaType("VIDEO/MP4"), "video/mp4")
        XCTAssertEqual(
            SharedInboxPolicy.normalizedMediaType("text/plain; charset=utf-8"),
            "text/plain"
        )
    }

    /// A photo straight off the camera is HEIC, which the wire does not carry — but the app
    /// re-encodes every shared image, so it stays an image here instead of being demoted to an
    /// opaque blob the recipient cannot open.
    func testCameraNativeImagesStayImages() {
        XCTAssertEqual(SharedInboxPolicy.normalizedMediaType("image/heic"), "image/heic")
        XCTAssertEqual(KitChatMediaKind(mediaType: "image/heic"), .image)
    }

    func testAnythingElseTravelsAsADocument() {
        XCTAssertEqual(
            SharedInboxPolicy.normalizedMediaType("application/x-made-up"),
            "application/octet-stream"
        )
        XCTAssertEqual(SharedInboxPolicy.normalizedMediaType(nil), "application/octet-stream")
        XCTAssertEqual(SharedInboxPolicy.normalizedMediaType("   "), "application/octet-stream")
    }

    // MARK: Names from another app are not trusted

    func testStoredNameIsOursAndKeepsOnlyTheExtension() {
        let id = UUID()
        XCTAssertEqual(
            SharedInboxPolicy.storageFileName(id: id, suggestedName: "Quarterly Report.PDF"),
            "\(id.uuidString).pdf"
        )
        XCTAssertEqual(
            SharedInboxPolicy.storageFileName(id: id, suggestedName: "../../../etc/passwd"),
            id.uuidString
        )
        XCTAssertEqual(
            SharedInboxPolicy.storageFileName(id: id, suggestedName: nil),
            id.uuidString
        )
    }

    func testAFileNameThatCouldLeaveTheBatchIsRefused() {
        XCTAssertTrue(SharedInboxPolicy.isSafeFileName("photo.jpg"))
        XCTAssertFalse(SharedInboxPolicy.isSafeFileName(""))
        XCTAssertFalse(SharedInboxPolicy.isSafeFileName(".."))
        XCTAssertFalse(SharedInboxPolicy.isSafeFileName("nested/photo.jpg"))
        XCTAssertFalse(SharedInboxPolicy.isSafeFileName("..\\photo.jpg"))
    }

    func testDisplayNameFallsBackToWhatTheFileIs() {
        XCTAssertEqual(
            SharedInboxPolicy.displayName(suggestedName: "Report.pdf", mediaType: "application/pdf"),
            "Report.pdf"
        )
        XCTAssertEqual(
            SharedInboxPolicy.displayName(suggestedName: nil, mediaType: "image/jpeg"),
            "Photo"
        )
        XCTAssertEqual(
            SharedInboxPolicy.displayName(suggestedName: "  ", mediaType: "video/mp4"),
            "Video"
        )
        XCTAssertEqual(
            SharedInboxPolicy.displayName(suggestedName: nil, mediaType: "application/zip"),
            "Document"
        )
        XCTAssertEqual(
            SharedInboxPolicy.displayName(suggestedName: "a/b:c", mediaType: "application/pdf"),
            "a-b-c",
            "A separator in a name must never read as a path"
        )
        XCTAssertEqual(
            SharedInboxPolicy.displayName(
                suggestedName: "  quarterly\n\treport.pdf  ",
                mediaType: "application/pdf"
            ),
            "quarterly--report.pdf",
            "control characters from another app must not enter the share UI"
        )
    }

    func testLargeImagesRemainShareableWithoutUnsafeImageDecoding() {
        XCTAssertTrue(SharedInboxPolicy.shouldDecodeSharedImage(byteCount: 1))
        XCTAssertTrue(
            SharedInboxPolicy.shouldDecodeSharedImage(
                byteCount: SharedInboxPolicy.maximumImageDecodeBytes
            )
        )
        XCTAssertFalse(
            SharedInboxPolicy.shouldDecodeSharedImage(
                byteCount: SharedInboxPolicy.maximumImageDecodeBytes + 1
            )
        )
        XCTAssertTrue(SharedInboxPolicy.fits(SharedInboxPolicy.maximumBytes))
    }

    func testAValidMultiFileBatchCannotExceedTheSafeAggregateMemoryBound() {
        let firstID = UUID()
        let secondID = UUID()
        let half = SharedInboxPolicy.maximumBatchBytes / 2
        let first = SharedInboxItem(
            id: firstID,
            fileName: firstID.uuidString,
            mediaType: "application/octet-stream",
            displayName: "First",
            byteCount: half
        )
        let second = SharedInboxItem(
            id: secondID,
            fileName: secondID.uuidString,
            mediaType: "application/octet-stream",
            displayName: "Second",
            byteCount: SharedInboxPolicy.maximumBatchBytes - half
        )
        XCTAssertTrue(SharedInboxPolicy.batchFits([first, second]))
        let over = SharedInboxItem(
            id: secondID,
            fileName: secondID.uuidString,
            mediaType: "application/octet-stream",
            displayName: "Second",
            byteCount: SharedInboxPolicy.maximumBatchBytes - half + 1
        )
        XCTAssertFalse(SharedInboxPolicy.batchFits([first, over]))
    }

    // MARK: Text

    func testSharedTextTravelsByteForByteAndIsNeverSilentlyTruncated() {
        XCTAssertNil(SharedInboxPolicy.carriedText("   \n "), "boundary scalars alone carry nothing")
        XCTAssertNil(SharedInboxPolicy.carriedText(""))
        XCTAssertNil(SharedInboxPolicy.carriedText(nil))
        XCTAssertEqual(
            SharedInboxPolicy.carriedText("  hello  "),
            "  hello  ",
            "the six-scalar strip belongs to the V2 queue at seal, never to the handoff"
        )
        // Over-limit text is carried intact so the failure can be shown against the real text;
        // publishing it is what `finishBatch` refuses, visibly.
        let long = String(repeating: "a", count: SharedInboxPolicy.maximumTextCharacters + 500)
        XCTAssertEqual(SharedInboxPolicy.carriedText(long), long)
        XCTAssertTrue(SharedInboxPolicy.exceedsTextLimit(long))
        XCTAssertFalse(
            SharedInboxPolicy.exceedsTextLimit(
                String(repeating: "a", count: SharedInboxPolicy.maximumTextCharacters)
            )
        )
        // One extended grapheme can chain thousands of scalars: the character count stays 1
        // while storage grows without bound. The UTF-8 byte reading catches it, visibly.
        let pathological = "a" + String(
            repeating: "\u{0301}",
            count: SharedInboxPolicy.maximumTextUTF8Bytes
        )
        XCTAssertEqual(pathological.count, 1)
        XCTAssertTrue(SharedInboxPolicy.exceedsTextLimit(pathological))
        XCTAssertEqual(
            SharedInboxPolicy.carriedText(pathological),
            pathological,
            "even refused text is carried intact to the visible failure, never reshaped"
        )
    }

    func testSharedTextPreservesScalarsFoundationCallsWhitespace() {
        // NBSP, NEL, LINE SEPARATOR, and PARAGRAPH SEPARATOR are inside Foundation's
        // `.whitespacesAndNewlines` but outside the contract's six boundary scalars: they are
        // caption content and must survive the handoff at either end of the text.
        for scalar in ["\u{00A0}", "\u{0085}", "\u{2028}", "\u{2029}"] {
            let text = "\(scalar)caption\(scalar)"
            XCTAssertEqual(SharedInboxPolicy.carriedText(text), text)
            XCTAssertEqual(
                SharedInboxPolicy.carriedText(scalar),
                scalar,
                "a caption consisting of this scalar alone is content, not blank"
            )
            XCTAssertFalse(SharedInboxPolicy.carriesNoContent(scalar))
        }
        // The six contract scalars, and only they, read as no content.
        XCTAssertTrue(SharedInboxPolicy.carriesNoContent("\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}"))
    }

    func testExtensionBoundarySetMirrorsTheWireCaptionPolicyExactly() {
        // SharedInbox.swift compiles into the share extension without the wire models, so it
        // restates the caption boundary set. This pin is what keeps the copies one policy.
        XCTAssertEqual(
            SharedInboxPolicy.captionBoundaryScalars,
            KitMediaMessageCaptionPolicy.boundaryScalars
        )
    }

    func testFinishedBatchTextIsExactlyWhatTheHandoffCarried() {
        // The persisted manifest must hold the same judgement `carriedText` makes: content-
        // bearing text rides unchanged, so applying it to the composer is byte-identical.
        let text = "\u{00A0}shared note\u{2028}"
        XCTAssertEqual(SharedInboxPolicy.carriedText(text), text)
        XCTAssertEqual(
            SharedInboxPolicy.composerDraft(existingDraft: "", sharedText: text),
            text
        )
    }

    func testSharedTextCanBeRemovedForReroutingWithoutLosingLaterTyping() {
        let original = "Existing draft"
        let applied = SharedInboxPolicy.composerDraft(
            existingDraft: original,
            sharedText: "Shared link"
        )
        XCTAssertEqual(applied, "Existing draft\nShared link")
        XCTAssertEqual(
            SharedInboxPolicy.composerDraft(
                existingDraft: applied,
                sharedText: "Shared link"
            ),
            applied,
            "re-applying a retained batch after process death must not duplicate its text"
        )
        XCTAssertEqual(
            SharedInboxPolicy.draftAfterRemovingShare(
                currentDraft: applied,
                originalDraft: original,
                sharedText: "Shared link"
            ),
            original
        )
        XCTAssertEqual(
            SharedInboxPolicy.draftAfterRemovingShare(
                currentDraft: applied + "\nMy follow-up",
                originalDraft: original,
                sharedText: "Shared link"
            ),
            "Existing draft\nMy follow-up"
        )
        XCTAssertNil(
            SharedInboxPolicy.draftAfterRemovingShare(
                currentDraft: "Existing draft\nEdited shared link",
                originalDraft: original,
                sharedText: "Shared link"
            ),
            "an edited span is kept rather than guessed at"
        )
    }

    func testComposerDraftPreservesTheExistingDraftsBytes() {
        XCTAssertEqual(
            SharedInboxPolicy.composerDraft(existingDraft: "typed \u{00A0}", sharedText: "Shared"),
            "typed \u{00A0}\nShared",
            "no Foundation trim may touch what the customer already typed"
        )
        XCTAssertEqual(
            SharedInboxPolicy.composerDraft(existingDraft: "  \n", sharedText: "Shared"),
            "Shared",
            "a contentless draft is replaced, judged by the contract's own six scalars"
        )
        let original = "draft ends in space "
        let applied = SharedInboxPolicy.composerDraft(existingDraft: original, sharedText: "Shared")
        XCTAssertEqual(applied, "draft ends in space \nShared")
        XCTAssertEqual(
            SharedInboxPolicy.draftAfterRemovingShare(
                currentDraft: applied,
                originalDraft: original,
                sharedText: "Shared"
            ),
            original,
            "the re-route inverse hands back the untrimmed original"
        )
    }

    // MARK: What the picker says

    func testSummaryCountsWhatIsActuallyThere() {
        XCTAssertEqual(SharedInboxPolicy.summary(itemCount: 0, hasText: false), "Nothing to send")
        XCTAssertEqual(SharedInboxPolicy.summary(itemCount: 0, hasText: true), "Text ready to send")
        XCTAssertEqual(SharedInboxPolicy.summary(itemCount: 1, hasText: false), "1 item ready to send")
        XCTAssertEqual(
            SharedInboxPolicy.summary(itemCount: 1, hasText: true),
            "1 item and text ready to send"
        )
        XCTAssertEqual(SharedInboxPolicy.summary(itemCount: 3, hasText: false), "3 items ready to send")
        XCTAssertEqual(
            SharedInboxPolicy.summary(itemCount: 3, hasText: true),
            "3 items and text ready to send"
        )
    }

    func testPickerOrdersFiveRecentChatsThenContactsAndOlderGroups() {
        let now = Date()
        let recent: [(destination: SharedInboxDestination, updatedAt: Date)] = [
            (groupDestination(0, name: "Newest group"), now),
            (directDestination(1, name: "Zoe"), now.addingTimeInterval(-1)),
            (groupDestination(2, name: "Second group"), now.addingTimeInterval(-2)),
            (directDestination(3, name: "Mary"), now.addingTimeInterval(-3)),
            (groupDestination(4, name: "Third group"), now.addingTimeInterval(-4)),
            (directDestination(5, name: "Older direct"), now.addingTimeInterval(-5)),
            (groupDestination(6, name: "Older group"), now.addingTimeInterval(-6)),
            (groupDestination(10, name: "Alpha group"), now.addingTimeInterval(-7)),
        ]
        let contacts = [
            contactDestination(9, name: "charlie"),
            contactDestination(1, name: "Zoe duplicate"),
            contactDestination(8, name: "Alice"),
            contactDestination(7, name: "Bob"),
        ]

        let ordered = SharedInboxPolicy.orderedDestinations(
            recentCandidates: Array(recent.reversed()),
            contacts: Array(contacts.reversed())
        )

        XCTAssertEqual(
            Array(ordered.prefix(5)).map(\.displayName),
            ["Newest group", "Zoe", "Second group", "Mary", "Third group"]
        )
        XCTAssertTrue(ordered.prefix(5).allSatisfy { $0.isRecent == true })
        XCTAssertTrue(ordered.dropFirst(5).allSatisfy { $0.isRecent != true })
        XCTAssertEqual(
            Array(ordered.dropFirst(5)).map(\.displayName),
            ["Alice", "Bob", "charlie", "Alpha group", "Older group"]
        )
        XCTAssertEqual(ordered.filter { $0.kind == .group }.count, 5)
        XCTAssertFalse(ordered.contains { $0.displayName == "Zoe duplicate" })
    }

    func testDestinationValidationKeepsRoutesStructurallyDistinct() {
        XCTAssertTrue(SharedInboxPolicy.isValidDestination(directDestination(1, name: "Emma")))
        XCTAssertTrue(SharedInboxPolicy.isValidDestination(groupDestination(2, name: "Family")))
        XCTAssertTrue(SharedInboxPolicy.isValidDestination(contactDestination(3, name: "Florence")))
        XCTAssertFalse(SharedInboxPolicy.isValidDestination(SharedInboxDestination(
            conversationID: conversationID(4),
            recipientUserID: recipientID(4),
            displayName: "Forged group",
            kind: .group,
            memberCount: 3
        )))
        XCTAssertFalse(SharedInboxPolicy.isValidDestination(SharedInboxDestination(
            conversationID: nil,
            recipientUserID: recipientID(5),
            displayName: "Not a direct conversation",
            kind: .direct,
            memberCount: nil
        )))
    }

    func testDestinationAvatarMustBeBoundedPublicHTTPSPresentationData() {
        let avatar = "https://pay.kit.africa/avatars/emma.jpg"
        XCTAssertEqual(SharedInboxPolicy.destinationAvatarURL("  \(avatar)\n"), avatar)
        XCTAssertNil(SharedInboxPolicy.destinationAvatarURL("http://pay.kit.africa/emma.jpg"))
        XCTAssertNil(SharedInboxPolicy.destinationAvatarURL("https://user:secret@pay.kit.africa/a"))
        XCTAssertNil(SharedInboxPolicy.destinationAvatarURL("https://pay.kit.africa/a#private"))

        XCTAssertTrue(SharedInboxPolicy.isValidDestination(SharedInboxDestination(
            conversationID: conversationID(6),
            recipientUserID: recipientID(6),
            displayName: "Emma",
            kind: .direct,
            memberCount: nil,
            avatarURL: avatar
        )))
        XCTAssertFalse(SharedInboxPolicy.isValidDestination(SharedInboxDestination(
            conversationID: conversationID(6),
            recipientUserID: recipientID(6),
            displayName: "Emma",
            kind: .direct,
            memberCount: nil,
            avatarURL: "http://pay.kit.africa/avatars/emma.jpg"
        )))
    }

    func testDestinationAddedPresentationFieldsRemainBackwardDecodable() throws {
        let legacy = Data("""
        {
          "conversationID": "\(conversationID(7))",
          "recipientUserID": "\(recipientID(7))",
          "displayName": "Legacy recent chat",
          "kind": "direct",
          "memberCount": null
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(SharedInboxDestination.self, from: legacy)
        XCTAssertNil(decoded.avatarURL)
        XCTAssertNil(decoded.isRecent)
        XCTAssertTrue(SharedInboxPolicy.isValidDestination(decoded))
    }

    func testRequestedRouteMustMatchCurrentConversationKindAndParticipants() {
        let currentAccountID = accountID
        let direct = directDestination(1, name: "Emma").request
        XCTAssertTrue(SharedInboxPolicy.destinationRequest(
            direct,
            matchesConversationID: conversationID(1),
            isGroup: false,
            participantUserIDs: [currentAccountID, recipientID(1)],
            currentAccountID: currentAccountID
        ))
        XCTAssertFalse(SharedInboxPolicy.destinationRequest(
            direct,
            matchesConversationID: conversationID(1),
            isGroup: true,
            participantUserIDs: [currentAccountID, recipientID(1)],
            currentAccountID: currentAccountID
        ))
        XCTAssertFalse(SharedInboxPolicy.destinationRequest(
            direct,
            matchesConversationID: conversationID(1),
            isGroup: false,
            participantUserIDs: [currentAccountID, recipientID(99)],
            currentAccountID: currentAccountID
        ))

        let group = groupDestination(2, name: "Family").request
        XCTAssertTrue(SharedInboxPolicy.destinationRequest(
            group,
            matchesConversationID: conversationID(2),
            isGroup: true,
            participantUserIDs: [currentAccountID, recipientID(2), recipientID(3)],
            currentAccountID: currentAccountID
        ))
        XCTAssertFalse(SharedInboxPolicy.destinationRequest(
            group,
            matchesConversationID: conversationID(2),
            isGroup: true,
            participantUserIDs: [recipientID(2), recipientID(3)],
            currentAccountID: currentAccountID
        ))
        XCTAssertFalse(SharedInboxPolicy.destinationRequest(
            group,
            matchesConversationID: conversationID(2),
            isGroup: true,
            participantUserIDs: [currentAccountID, currentAccountID],
            currentAccountID: currentAccountID
        ))
    }

    // MARK: Nothing forgotten is kept

    func testASharedFileNobodyDeliveredIsRetired() {
        let now = Date()
        XCTAssertFalse(SharedInboxPolicy.isExpired(receivedAt: now, now: now))
        XCTAssertFalse(
            SharedInboxPolicy.isExpired(
                receivedAt: now.addingTimeInterval(-SharedInboxPolicy.retention + 60),
                now: now
            )
        )
        XCTAssertTrue(
            SharedInboxPolicy.isExpired(
                receivedAt: now.addingTimeInterval(-SharedInboxPolicy.retention),
                now: now
            )
        )
    }

    /// A device whose clock moved backwards must not turn an old share into a fresh one.
    func testAShareStampedFarInTheFutureIsAlsoRetired() {
        let now = Date()
        XCTAssertTrue(
            SharedInboxPolicy.isExpired(
                receivedAt: now.addingTimeInterval(SharedInboxPolicy.retention * 2),
                now: now
            )
        )
    }

    // MARK: The container round trip

    func testActiveAccountBindingRoundTripsAndClears() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        XCTAssertNil(store.activeAccountID())
        XCTAssertTrue(store.setActiveAccountID(accountID.uppercased()))
        XCTAssertEqual(store.activeAccountID(), accountID)
        store.clearActiveAccount()
        XCTAssertNil(store.activeAccountID())
        XCTAssertFalse(store.setActiveAccountID("not-an-account"))
    }

    func testDestinationSnapshotRoundTripsInPublishedOrder() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let destinations = [
            groupDestination(1, name: "Family"),
            SharedInboxDestination(
                conversationID: conversationID(2),
                recipientUserID: recipientID(2),
                displayName: "Emma",
                kind: .direct,
                memberCount: nil,
                avatarURL: "https://pay.kit.africa/avatars/emma.jpg"
            ),
            contactDestination(3, name: "Florence"),
        ]
        XCTAssertTrue(store.setDestinations(destinations, forAccountID: accountID))
        XCTAssertEqual(store.destinations(forAccountID: accountID), destinations)
    }

    func testDestinationSnapshotCannotCrossAccounts() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        XCTAssertTrue(store.setDestinations(
            [contactDestination(1, name: "Private contact")],
            forAccountID: accountID
        ))
        XCTAssertTrue(store.destinations(forAccountID: otherAccountID).isEmpty)
        XCTAssertTrue(
            store.destinations(forAccountID: accountID).isEmpty,
            "a cross-account snapshot is destroyed rather than retained for a later switch"
        )
    }

    func testExpiredDestinationSnapshotIsDestroyed() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let now = Date()
        XCTAssertTrue(store.setDestinations(
            [contactDestination(1, name: "Old contact")],
            forAccountID: accountID,
            generatedAt: now.addingTimeInterval(-SharedInboxPolicy.destinationSnapshotRetention)
        ))
        XCTAssertTrue(store.destinations(forAccountID: accountID, now: now).isEmpty)
    }

    func testAStagedBatchIsReadBackExactlyAsItWasWritten() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let batchID = UUID()
        let item = try store.stage(
            data: Data("hello".utf8),
            suggestedName: "note.txt",
            mediaType: "text/plain",
            batchID: batchID
        )
        try store.finishBatch(
            id: batchID,
            items: [item],
            text: nil,
            ownerAccountID: accountID,
            receivedAt: Date()
        )

        let batches = store.pendingBatches(forAccountID: accountID)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.items.count, 1)
        XCTAssertEqual(batches.first?.items.first?.displayName, "note.txt")
        XCTAssertEqual(batches.first?.items.first?.mediaType, "text/plain")
        XCTAssertEqual(batches.first?.items.first?.id, item.id)
        XCTAssertEqual(try store.data(for: item, in: batchID), Data("hello".utf8))
    }

    func testValidatedFileURLRemainsOwnedByInboxUntilExplicitRemoval() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let batchID = UUID()
        let bytes = Data("local-first shared document".utf8)
        let item = try store.stage(
            data: bytes,
            suggestedName: "document.txt",
            mediaType: "text/plain",
            batchID: batchID
        )
        try store.finishBatch(
            id: batchID,
            items: [item],
            text: nil,
            ownerAccountID: accountID,
            receivedAt: Date()
        )

        let fileURL = try store.fileURL(for: item, in: batchID)
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // Resolving the file is non-consuming. The composer copies it into permanent protected
        // media storage, and the inbox remains the recovery owner until the outbox commit wins.
        _ = try store.fileURL(for: item, in: batchID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        store.remove(batchID: batchID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertThrowsError(try store.fileURL(for: item, in: batchID))
    }

    func testManifestItemMetadataMustRemainCanonical() {
        let id = UUID()
        XCTAssertTrue(SharedInboxPolicy.isValidItemMetadata(SharedInboxItem(
            id: id,
            fileName: "\(id.uuidString).pdf",
            mediaType: "application/pdf",
            displayName: "Receipt.pdf",
            byteCount: 42
        )))
        XCTAssertFalse(SharedInboxPolicy.isValidItemMetadata(SharedInboxItem(
            id: id,
            fileName: "another-id.pdf",
            mediaType: "application/pdf",
            displayName: "Receipt.pdf",
            byteCount: 42
        )))
        XCTAssertFalse(SharedInboxPolicy.isValidItemMetadata(SharedInboxItem(
            id: id,
            fileName: "\(id.uuidString).pdf",
            mediaType: "APPLICATION/PDF",
            displayName: "Receipt.pdf",
            byteCount: 42
        )))
        XCTAssertFalse(SharedInboxPolicy.isValidItemMetadata(SharedInboxItem(
            id: id,
            fileName: "\(id.uuidString).pdf",
            mediaType: "application/pdf",
            displayName: "Receipt\n.pdf",
            byteCount: 42
        )))
    }

    /// The manifest is written last. A batch interrupted between copying the files and publishing
    /// them is never handed to a chat — it is cleaned up instead.
    func testABatchWithoutAManifestIsNeverDelivered() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let batchID = UUID()
        _ = try store.stage(
            data: Data("hello".utf8),
            suggestedName: "note.txt",
            mediaType: "text/plain",
            batchID: batchID
        )
        XCTAssertTrue(store.pendingBatches(forAccountID: accountID).isEmpty)
    }

    func testATextOnlyShareIsDeliverableWithoutAnyFiles() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let batchID = UUID()
        try store.finishBatch(
            id: batchID,
            items: [],
            text: "https://kit.africa",
            ownerAccountID: accountID,
            receivedAt: Date()
        )
        XCTAssertEqual(
            store.pendingBatches(forAccountID: accountID).first?.text,
            "https://kit.africa"
        )
    }

    func testChosenContactRouteSurvivesTheBatchRoundTrip() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let batchID = UUID()
        let destination = contactDestination(12, name: "Namisi Emmanuel").request
        try store.finishBatch(
            id: batchID,
            items: [],
            text: "Shared text",
            ownerAccountID: accountID,
            receivedAt: Date(),
            destination: destination
        )
        XCTAssertEqual(
            store.pendingBatches(forAccountID: accountID).first?.destination,
            destination
        )
    }

    func testValidatedDestinationPinSurvivesProcessDeathAndRejectsAStaleReroute() throws {
        let container = try makeContainer()
        let firstProcess = SharedInboxStore(containerURL: container)
        let batchID = UUID()
        let firstItem = try firstProcess.stage(
            data: Data("first of a partial queue".utf8),
            suggestedName: "receipt.txt",
            mediaType: "text/plain",
            batchID: batchID
        )
        let remainingItem = try firstProcess.stage(
            data: Data("must survive cancellation".utf8),
            suggestedName: "statement.txt",
            mediaType: "text/plain",
            batchID: batchID
        )
        try firstProcess.finishBatch(
            id: batchID,
            items: [firstItem, remainingItem],
            text: "remaining shared text",
            ownerAccountID: accountID,
            receivedAt: Date()
        )
        let unpinned = try XCTUnwrap(
            firstProcess.pendingBatches(forAccountID: accountID).first
        )
        let chosen = directDestination(21, name: "Florence").request
        let pinned = try firstProcess.pinDestination(for: unpinned, to: chosen)

        let relaunchedProcess = SharedInboxStore(containerURL: container)
        let restored = try XCTUnwrap(
            relaunchedProcess.pendingBatches(forAccountID: accountID).first
        )
        XCTAssertEqual(
            restored.destination,
            chosen,
            "the unqueued remainder must recover only to the destination selected before item one"
        )
        let durablyQueuedMessageIDs: Set<UUID> = [firstItem.id]
        XCTAssertEqual(
            restored.items.filter { !durablyQueuedMessageIDs.contains($0.id) }.map(\.id),
            [remainingItem.id],
            "dismissing after item one must leave the exact unqueued remainder staged"
        )
        XCTAssertThrowsError(try relaunchedProcess.pinDestination(
            for: unpinned,
            to: directDestination(22, name: "Emma").request
        )) { error in
            XCTAssertEqual(error as? SharedInboxError, .unreadable)
        }
        XCTAssertEqual(pinned.items.map(\.id), [firstItem.id, remainingItem.id])
    }

    func testMalformedDestinationRouteRejectsTheWholeBatch() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        XCTAssertThrowsError(try store.finishBatch(
            id: UUID(),
            items: [],
            text: "Shared text",
            ownerAccountID: accountID,
            receivedAt: Date(),
            destination: SharedInboxDestinationRequest(
                kind: .group,
                conversationID: nil,
                recipientUserID: recipientID(1),
                displayName: "Forged group"
            )
        )) { error in
            XCTAssertEqual(error as? SharedInboxError, .unreadable)
        }
    }

    func testAShareFromAnotherAccountIsPurgedInsteadOfDelivered() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let batchID = UUID()
        try store.finishBatch(
            id: batchID,
            items: [],
            text: "private to the first account",
            ownerAccountID: accountID,
            receivedAt: Date()
        )

        XCTAssertTrue(store.pendingBatches(forAccountID: otherAccountID).isEmpty)
        XCTAssertTrue(
            store.pendingBatches(forAccountID: accountID).isEmpty,
            "a cross-account batch must be destroyed, not left for a later account switch"
        )
    }

    func testAShareOfNothingIsRefused() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        XCTAssertThrowsError(
            try store.finishBatch(
                id: UUID(),
                items: [],
                text: "   ",
                ownerAccountID: accountID,
                receivedAt: Date()
            )
        ) { error in
            XCTAssertEqual(error as? SharedInboxError, .empty)
        }
    }

    func testAnEmptyFileIsNotStaged() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        XCTAssertThrowsError(
            try store.stage(
                data: Data(),
                suggestedName: "empty.bin",
                mediaType: nil,
                batchID: UUID()
            )
        ) { error in
            XCTAssertEqual(error as? SharedInboxError, .unreadable)
        }
    }

    func testTheSizeCapIsTheSameOnBothSidesOfTheHandoff() {
        XCTAssertFalse(SharedInboxPolicy.fits(0))
        XCTAssertTrue(SharedInboxPolicy.fits(1))
        XCTAssertTrue(SharedInboxPolicy.fits(SharedInboxPolicy.maximumBytes))
        XCTAssertFalse(SharedInboxPolicy.fits(SharedInboxPolicy.maximumBytes + 1))
        XCTAssertEqual(
            KitChatMediaLimits.fits(SharedInboxPolicy.maximumBytes, kind: .video),
            SharedInboxPolicy.fits(SharedInboxPolicy.maximumBytes)
        )
    }

    func testDeliveringABatchRemovesItsPlaintext() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let batchID = UUID()
        let item = try store.stage(
            data: Data("hello".utf8),
            suggestedName: "note.txt",
            mediaType: "text/plain",
            batchID: batchID
        )
        try store.finishBatch(
            id: batchID,
            items: [item],
            text: nil,
            ownerAccountID: accountID,
            receivedAt: Date()
        )
        store.remove(batchID: batchID)
        XCTAssertTrue(store.pendingBatches(forAccountID: accountID).isEmpty)
        XCTAssertThrowsError(try store.data(for: item, in: batchID))
    }

    func testStaleBatchesAreRemovedWhenTheInboxIsRead() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let batchID = UUID()
        let item = try store.stage(
            data: Data("hello".utf8),
            suggestedName: "note.txt",
            mediaType: "text/plain",
            batchID: batchID
        )
        try store.finishBatch(
            id: batchID,
            items: [item],
            text: nil,
            ownerAccountID: accountID,
            receivedAt: Date().addingTimeInterval(-SharedInboxPolicy.retention - 60)
        )
        XCTAssertTrue(store.pendingBatches(forAccountID: accountID).isEmpty)
        XCTAssertThrowsError(try store.data(for: item, in: batchID))
    }

    /// Two shares before the app is opened are two shares, delivered in the order they happened.
    func testBatchesComeBackOldestFirst() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let older = UUID()
        let newer = UUID()
        try store.finishBatch(
            id: newer,
            items: [],
            text: "second",
            ownerAccountID: accountID,
            receivedAt: Date()
        )
        try store.finishBatch(
            id: older,
            items: [],
            text: "first",
            ownerAccountID: accountID,
            receivedAt: Date().addingTimeInterval(-120)
        )
        XCTAssertEqual(
            store.pendingBatches(forAccountID: accountID).map(\.text),
            ["first", "second"]
        )
    }

    func testFifthPendingBatchIsRejectedBeforeItsManifestIsPublished() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let now = Date()
        for index in 0 ..< SharedInboxPolicy.maximumPendingBatches {
            try store.finishBatch(
                id: UUID(),
                items: [],
                text: "confirmed \(index)",
                ownerAccountID: accountID,
                receivedAt: now.addingTimeInterval(Double(index - 10))
            )
        }

        let rejectedID = UUID()
        XCTAssertThrowsError(try store.finishBatch(
            id: rejectedID,
            items: [],
            text: "must not claim to be queued",
            ownerAccountID: accountID,
            receivedAt: now
        )) { error in
            XCTAssertEqual(error as? SharedInboxError, .inboxFull)
        }
        XCTAssertEqual(
            store.pendingBatches(forAccountID: accountID, now: now).count,
            SharedInboxPolicy.maximumPendingBatches
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(store.rootURL)
            .appendingPathComponent(rejectedID.uuidString, isDirectory: true).path))
    }

    func testLegacyCountOverflowIsPrunedNewestFirst() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let now = Date()
        var batches: [SharedInboxBatch] = []
        for index in 0 ... SharedInboxPolicy.maximumPendingBatches {
            let batch = SharedInboxBatch(
                id: UUID(),
                ownerAccountID: accountID,
                receivedAt: now.addingTimeInterval(Double(index - 10)),
                items: [],
                text: "legacy \(index)"
            )
            try writeLegacyBatch(batch, to: store)
            batches.append(batch)
        }

        XCTAssertEqual(
            store.pendingBatches(forAccountID: accountID, now: now).map(\.id),
            Array(batches.prefix(SharedInboxPolicy.maximumPendingBatches)).map(\.id)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(store.rootURL)
            .appendingPathComponent(try XCTUnwrap(batches.last).id.uuidString, isDirectory: true)
            .path))
    }

    func testLegacyByteOverflowIsPrunedNewestFirst() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let now = Date()
        let bytesPerBatch = 150 * 1_024 * 1_024
        var batches: [SharedInboxBatch] = []
        for index in 0 ..< 3 {
            let itemID = UUID()
            let item = SharedInboxItem(
                id: itemID,
                fileName: "\(itemID.uuidString).bin",
                mediaType: "application/octet-stream",
                displayName: "Archive \(index).bin",
                byteCount: bytesPerBatch
            )
            let batch = SharedInboxBatch(
                id: UUID(),
                ownerAccountID: accountID,
                receivedAt: now.addingTimeInterval(Double(index - 10)),
                items: [item]
            )
            try writeLegacyBatch(batch, to: store)
            batches.append(batch)
        }

        XCTAssertEqual(
            store.pendingBatches(forAccountID: accountID, now: now).map(\.id),
            Array(batches.prefix(2)).map(\.id)
        )
        XCTAssertLessThanOrEqual(
            batches.prefix(2).reduce(0) {
                $0 + SharedInboxPolicy.payloadByteCount($1)
            },
            SharedInboxPolicy.maximumRetainedBytes
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(store.rootURL)
            .appendingPathComponent(try XCTUnwrap(batches.last).id.uuidString, isDirectory: true)
            .path))
    }

    /// A manifest naming a file outside its own batch directory must not be readable, whatever put
    /// it there.
    func testAManifestCannotPointOutsideItsOwnBatch() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let escaping = SharedInboxItem(
            id: UUID(),
            fileName: "../manifest.json",
            mediaType: "application/octet-stream",
            displayName: "escape",
            byteCount: 12
        )
        XCTAssertThrowsError(try store.data(for: escaping, in: UUID())) { error in
            XCTAssertEqual(error as? SharedInboxError, .unreadable)
        }
    }

    func testAStagedFileWhoseSizeChangedIsNotRead() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let batchID = UUID()
        let item = try store.stage(
            data: Data("hello".utf8),
            suggestedName: "note.txt",
            mediaType: "text/plain",
            batchID: batchID
        )
        let fileURL = try XCTUnwrap(store.rootURL)
            .appendingPathComponent(batchID.uuidString, isDirectory: true)
            .appendingPathComponent(item.fileName, isDirectory: false)
        try Data("changed after the manifest was made".utf8).write(to: fileURL)

        XCTAssertThrowsError(try store.data(for: item, in: batchID)) { error in
            XCTAssertEqual(error as? SharedInboxError, .unreadable)
        }
    }

    func testAStagedSymlinkIsNeverFollowed() throws {
        let container = try makeContainer()
        let store = SharedInboxStore(containerURL: container)
        let batchID = UUID()
        let item = try store.stage(
            data: Data("placeholder".utf8),
            suggestedName: "note.txt",
            mediaType: "text/plain",
            batchID: batchID
        )
        let target = container.appendingPathComponent("outside.txt")
        try Data("another account's bytes".utf8).write(to: target)
        let fileURL = try XCTUnwrap(store.rootURL)
            .appendingPathComponent(batchID.uuidString, isDirectory: true)
            .appendingPathComponent(item.fileName, isDirectory: false)
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: target)

        XCTAssertThrowsError(try store.data(for: item, in: batchID)) { error in
            XCTAssertEqual(error as? SharedInboxError, .unreadable)
        }
    }

    // MARK: Helpers

    private func makeContainer() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-inbox-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Writes the shape older builds could leave behind before retained-inbox limits existed.
    /// Payloads are sparse files so the test exercises real byte counts without allocating them.
    private func writeLegacyBatch(
        _ batch: SharedInboxBatch,
        to store: SharedInboxStore
    ) throws {
        let directory = try XCTUnwrap(store.rootURL)
            .appendingPathComponent(batch.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for item in batch.items {
            let fileURL = directory.appendingPathComponent(item.fileName, isDirectory: false)
            XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: nil))
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.truncate(atOffset: UInt64(item.byteCount))
            try handle.close()
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(batch).write(
            to: directory.appendingPathComponent("manifest.json", isDirectory: false),
            options: .atomic
        )
    }

    private func directDestination(_ value: Int, name: String) -> SharedInboxDestination {
        SharedInboxDestination(
            conversationID: conversationID(value),
            recipientUserID: recipientID(value),
            displayName: name,
            kind: .direct,
            memberCount: nil
        )
    }

    private func groupDestination(_ value: Int, name: String) -> SharedInboxDestination {
        SharedInboxDestination(
            conversationID: conversationID(value),
            recipientUserID: nil,
            displayName: name,
            kind: .group,
            memberCount: 4
        )
    }

    private func contactDestination(_ value: Int, name: String) -> SharedInboxDestination {
        SharedInboxDestination(
            conversationID: nil,
            recipientUserID: recipientID(value),
            displayName: name,
            kind: .contact,
            memberCount: nil
        )
    }

    private func conversationID(_ value: Int) -> String {
        String(format: "30000000-0000-4000-8000-%012d", value)
    }

    private func recipientID(_ value: Int) -> String {
        String(format: "40000000-0000-4000-8000-%012d", value)
    }
}
