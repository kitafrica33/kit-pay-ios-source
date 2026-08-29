import XCTest
@testable import KitPay

/// Everything a group payment promises that is decided on the device: what the wire is allowed to
/// carry, which of those descriptors the thread is willing to believe, and how the result reads.
final class GroupPaymentTests: XCTestCase {
    func testComposerSubmissionGateAcceptsOneTapAndDismissesOnce() {
        var gate = GroupPaymentSubmissionGate()

        XCTAssertTrue(gate.begin())
        XCTAssertTrue(gate.isSubmitting)
        XCTAssertFalse(gate.begin(), "A fast second tap must not start another payment")
        XCTAssertTrue(gate.resolve(succeeded: true), "The confirmed payment dismisses the sheet")
        XCTAssertFalse(gate.isSubmitting)
        XCTAssertFalse(
            gate.resolve(succeeded: true),
            "A duplicate completion cannot dismiss the presentation a second time"
        )
        XCTAssertFalse(gate.begin(), "A succeeded presentation cannot send again")
    }

    func testComposerSubmissionGateReopensOnlyAfterFailure() {
        var gate = GroupPaymentSubmissionGate()

        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.resolve(succeeded: false))
        XCTAssertFalse(gate.isSubmitting)
        XCTAssertTrue(gate.begin(), "A failed request may be retried deliberately")
    }

    private let sender = "10000000-0000-4000-8000-000000000001"
    private let ama = "10000000-0000-4000-8000-000000000002"
    private let ben = "10000000-0000-4000-8000-000000000003"
    private let cara = "10000000-0000-4000-8000-000000000004"
    private let paymentID = "60000000-0000-4000-8000-000000000001"
    private let conversationID = "20000000-0000-4000-8000-000000000001"

    // MARK: - Wire descriptor

    func testEvenSplitAnnouncementRoundTripsThroughItsCanonicalEncoding() throws {
        let descriptor = try XCTUnwrap(KitGroupPaymentMessage(
            action: .sent,
            groupPaymentId: paymentID,
            splitMode: .even,
            audience: .selected,
            recipientCount: 2,
            currencyCode: "UGX",
            currencyScale: 0,
            totalAmountMinor: 30_000,
            note: "Lunch & taxi",
            recipientUserIds: [ama.uppercased(), ben]
        ))

        XCTAssertTrue(descriptor.encoded.hasPrefix(KitGroupPaymentMessage.prefix))
        XCTAssertEqual(descriptor.recipientUserIds, [ama, ben])
        XCTAssertEqual(KitGroupPaymentMessage.parse(descriptor.encoded), descriptor)
        XCTAssertEqual(descriptor.evenShareMinor, 15_000)
        XCTAssertTrue(descriptor.dividesEvenly)
        XCTAssertEqual(descriptor.decimalTotalAmount, "30000")
    }

    func testCustomSplitNeverCarriesThePotAndOnlyEverNamesChosenMembers() {
        XCTAssertNil(
            KitGroupPaymentMessage(
                action: .sent,
                groupPaymentId: paymentID,
                splitMode: .custom,
                audience: .selected,
                recipientCount: 2,
                currencyCode: "UGX",
                currencyScale: 0,
                totalAmountMinor: 30_000
            ),
            "a custom split that carried its total would put every other member's share one subtraction away"
        )
        XCTAssertNil(
            KitGroupPaymentMessage(
                action: .sent,
                groupPaymentId: paymentID,
                splitMode: .custom,
                audience: .all,
                recipientCount: 2,
                currencyCode: "UGX",
                currencyScale: 0
            )
        )
        XCTAssertNotNil(
            KitGroupPaymentMessage(
                action: .sent,
                groupPaymentId: paymentID,
                splitMode: .custom,
                audience: .selected,
                recipientCount: 2,
                currencyCode: "UGX",
                currencyScale: 0
            )
        )
    }

    func testEvenSplitRequiresAPotAndARealCurrency() {
        XCTAssertNil(KitGroupPaymentMessage(
            action: .sent,
            groupPaymentId: paymentID,
            splitMode: .even,
            audience: .all,
            recipientCount: 3,
            currencyCode: "UGX",
            currencyScale: 0,
            totalAmountMinor: nil
        ))
        XCTAssertNil(KitGroupPaymentMessage(
            action: .sent,
            groupPaymentId: paymentID,
            splitMode: .even,
            audience: .all,
            recipientCount: 3,
            currencyCode: "ugx",
            currencyScale: 0,
            totalAmountMinor: 300
        ))
        XCTAssertNil(KitGroupPaymentMessage(
            action: .sent,
            groupPaymentId: "not-a-uuid",
            splitMode: .even,
            audience: .all,
            recipientCount: 3,
            currencyCode: "UGX",
            currencyScale: 0,
            totalAmountMinor: 300
        ))
    }

    func testAnnouncementRefusesARosterThatDisagreesWithTheCount() {
        XCTAssertNil(
            KitGroupPaymentMessage(
                action: .sent,
                groupPaymentId: paymentID,
                splitMode: .even,
                audience: .selected,
                recipientCount: 3,
                currencyCode: "UGX",
                currencyScale: 0,
                totalAmountMinor: 300,
                recipientUserIds: [ama, ben]
            ),
            "naming two of three members reads as the whole list"
        )
        XCTAssertNil(
            KitGroupPaymentMessage(
                action: .sent,
                groupPaymentId: paymentID,
                splitMode: .even,
                audience: .selected,
                recipientCount: 2,
                currencyCode: "UGX",
                currencyScale: 0,
                totalAmountMinor: 300,
                recipientUserIds: [ama, ama]
            )
        )
    }

    func testOutcomeDescriptorCarriesNothingButWhoDidWhat() {
        XCTAssertNil(KitGroupPaymentMessage(
            action: .accepted,
            groupPaymentId: paymentID,
            currencyCode: "UGX",
            currencyScale: 0,
            totalAmountMinor: 15_000
        ))
        XCTAssertNil(KitGroupPaymentMessage(
            action: .rejected,
            groupPaymentId: paymentID,
            note: "not today"
        ))
        XCTAssertNil(KitGroupPaymentMessage(outcome: .sent, groupPaymentId: paymentID))

        let accepted = KitGroupPaymentMessage(outcome: .accepted, groupPaymentId: paymentID)
        XCTAssertEqual(accepted?.encoded, "KITGRP1:v=1&a=accepted&id=\(paymentID)")
        XCTAssertEqual(KitGroupPaymentMessage.parse(accepted?.encoded ?? ""), accepted)
    }

    func testParseRejectsAnythingThatIsNotTheCanonicalEncoding() {
        XCTAssertNil(KitGroupPaymentMessage.parse("KITGRP1:a=accepted&v=1&id=\(paymentID)"))
        XCTAssertNil(KitGroupPaymentMessage.parse("KITGRP1:v=1&a=accepted&id=\(paymentID)&x=1"))
        XCTAssertNil(
            KitGroupPaymentMessage.parse("KITGRP1:v=1&a=accepted&id=\(paymentID)&id=\(paymentID)")
        )
        XCTAssertNil(KitGroupPaymentMessage.parse("KITGRP1:v=2&a=accepted&id=\(paymentID)"))
        XCTAssertNil(KitGroupPaymentMessage.parse("KITPAY1:v=1&a=accepted&id=\(paymentID)"))
        XCTAssertFalse(KitGroupPaymentMessage.isGroupPaymentText("Sent 30,000 to the group"))
    }

    func testGroupPaymentWireIsReservedAgainstUserAuthoredText() {
        XCTAssertFalse(
            SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(
                "KITGRP1:v=1&a=accepted&id=\(paymentID)"
            )
        )
    }

    func testAnnouncingAConfirmedPaymentMirrorsWhatTheServerDisclosed() throws {
        let even = try payment(splitMode: "even", audience: "all", totalAmount: "30000")
        let announcement = try XCTUnwrap(
            KitGroupPaymentMessage(announcing: even, recipientUserIds: [ama, ben, cara])
        )
        XCTAssertEqual(announcement.totalAmountMinor, 30_000)
        XCTAssertEqual(announcement.recipientUserIds, [ama, ben, cara])
        XCTAssertTrue(announcement.matchesAuthoritativePayment(even))

        let custom = try payment(splitMode: "custom", audience: "selected", totalAmount: "30000")
        let customAnnouncement = try XCTUnwrap(
            KitGroupPaymentMessage(announcing: custom, recipientUserIds: [ama, ben, cara])
        )
        XCTAssertNil(
            customAnnouncement.totalAmountMinor,
            "the sender's own view of the pot must not be re-broadcast to the group"
        )

        // A roster the server disagrees with is dropped rather than published.
        let mismatched = try XCTUnwrap(
            KitGroupPaymentMessage(announcing: even, recipientUserIds: [ama])
        )
        XCTAssertTrue(mismatched.recipientUserIds.isEmpty)
        XCTAssertEqual(mismatched.recipientCount, 3)
    }

    func testMatchesAuthoritativePaymentRejectsADescriptorThatOverstatesThePot() throws {
        let even = try payment(splitMode: "even", audience: "all", totalAmount: "30000")
        let inflated = try XCTUnwrap(KitGroupPaymentMessage(
            action: .sent,
            groupPaymentId: even.id,
            splitMode: .even,
            audience: .all,
            recipientCount: 3,
            currencyCode: "UGX",
            currencyScale: 0,
            totalAmountMinor: 300_000
        ))
        XCTAssertFalse(inflated.matchesAuthoritativePayment(even))
    }

    func testAuthoritativePaymentMustBelongToThisGroupAndAnnouncementSender() throws {
        let payment = try payment(splitMode: "even", audience: "all", totalAmount: "30000")
        XCTAssertTrue(
            GroupPaymentAuthorityPolicy.matchesContext(
                payment,
                conversationID: conversationID.uppercased(),
                announcementSenderID: sender.uppercased()
            )
        )
        XCTAssertFalse(
            GroupPaymentAuthorityPolicy.matchesContext(
                payment,
                conversationID: "90000000-0000-4000-8000-000000000009",
                announcementSenderID: sender
            ),
            "a genuine payment copied into another group must stay inert"
        )
        XCTAssertFalse(
            GroupPaymentAuthorityPolicy.matchesContext(
                payment,
                conversationID: conversationID,
                announcementSenderID: ama
            ),
            "a member cannot repost somebody else's payment as their own"
        )
    }

    func testOutcomeMessageIDIsStablePerPaymentActionAndAuthor() {
        let first = KitGroupPaymentMessage.outcomeMessageID(
            groupPaymentId: paymentID.uppercased(),
            action: .accepted,
            actorUserId: ama
        )
        XCTAssertEqual(
            first,
            KitGroupPaymentMessage.outcomeMessageID(
                groupPaymentId: paymentID,
                action: .accepted,
                actorUserId: ama.uppercased()
            )
        )
        XCTAssertNotEqual(
            first,
            KitGroupPaymentMessage.outcomeMessageID(
                groupPaymentId: paymentID,
                action: .rejected,
                actorUserId: ama
            )
        )
        XCTAssertNotEqual(
            first,
            KitGroupPaymentMessage.outcomeMessageID(
                groupPaymentId: paymentID,
                action: .accepted,
                actorUserId: ben
            )
        )
    }

    // MARK: - Timeline projection

    func testGroupThreadProjectsAnAnnouncementAndItsRecipientsAnswers() throws {
        let items = timeline([
            message(sender, announcement()),
            message(ama, outcome(.accepted)),
            message(ben, outcome(.rejected)),
            message(sender, outcome(.returned)),
        ])

        XCTAssertEqual(items.count, 5, "four events under one date separator")
        guard case .dateSeparator = items[0] else { return XCTFail("expected a date separator") }
        guard case .groupPayment(_, let card) = items[1] else { return XCTFail("expected the card") }
        XCTAssertEqual(card.groupPaymentId, paymentID)
        guard case .groupPaymentEvent(_, let accepted) = items[2] else {
            return XCTFail("expected an outcome")
        }
        XCTAssertEqual(accepted.action, .accepted)
        guard case .groupPaymentEvent(_, let rejected) = items[3] else {
            return XCTFail("expected an outcome")
        }
        XCTAssertEqual(rejected.action, .rejected)
        guard case .groupPaymentEvent(_, let returned) = items[4] else {
            return XCTFail("expected an outcome")
        }
        XCTAssertEqual(returned.action, .returned)
    }

    func testAnOutcomeWithoutItsAnnouncementRendersNothing() {
        let items = timeline([message(ama, outcome(.accepted))])
        XCTAssertTrue(
            items.allSatisfy(isDateSeparator),
            "a claim about a payment this thread never saw is not shown at all — not even as raw wire"
        )
    }

    func testTheThreadRefusesForgedAnswersAboutSomebodyElsesPayment() {
        let items = timeline([
            message(sender, announcement(recipients: [ama, ben])),
            // The sender cannot accept their own payment...
            message(sender, outcome(.accepted)),
            // ...a member who was not paid cannot answer for one who was...
            message(cara, outcome(.accepted)),
            // ...and nobody but the sender can return the unclaimed shares.
            message(ama, outcome(.returned)),
        ])

        XCTAssertEqual(items.filter(isOutcome).count, 0)
        XCTAssertEqual(items.filter(isCard).count, 1)
    }

    func testReplayedAnnouncementsAndDoubledAnswersAreDropped() {
        let items = timeline([
            message(sender, announcement(recipients: [ama, ben])),
            message(sender, announcement(recipients: [ama, ben])),
            message(ama, outcome(.accepted)),
            message(ama, outcome(.rejected)),
        ])

        XCTAssertEqual(items.filter(isCard).count, 1)
        XCTAssertEqual(
            items.filter(isOutcome).count,
            1,
            "a member answers their own share once; the second word is a replay"
        )
    }

    func testGroupPaymentWireInADirectThreadRendersNothing() {
        let direct = Conversation(
            id: conversationID,
            title: "Ama",
            participantUserIds: [sender, ama],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let items = ConversationTimelinePolicy.items(
            for: direct,
            allConversations: [direct],
            currentUserID: sender,
            messages: [message(sender, announcement())],
            calls: []
        )
        XCTAssertTrue(items.allSatisfy(isDateSeparator))
    }

    // MARK: - Sender-name runs

    func testASendersNameHeadsTheirRunAndNotEveryLineOfIt() {
        let first = message(ama, "one")
        let second = message(ama, "two")
        let third = message(ben, "three")
        let fourth = message(ama, "four")

        let named = ConversationSenderRunPolicy.namedMessageIDs(
            in: [.message(first), .message(second), .message(third), .message(fourth)],
            isGroup: true
        )

        XCTAssertEqual(named, [first.id, third.id, fourth.id])
    }

    func testNamesReturnAfterADayBreakACardOrTheAccountHoldersOwnMessage() throws {
        let first = message(ama, "one")
        let afterSeparator = message(ama, "two")
        let afterOwn = message(ama, "three")
        let mine = message(sender, "mine", outgoing: true)
        let card = message(sender, announcement())
        let afterCard = message(ama, "four")

        let named = ConversationSenderRunPolicy.namedMessageIDs(
            in: [
                .message(first),
                .dateSeparator(
                    ConversationTimelineDateSeparator(
                        day: Date(timeIntervalSince1970: 86_400),
                        label: "Today"
                    )
                ),
                .message(afterSeparator),
                .message(mine),
                .message(afterOwn),
                .groupPayment(card, try XCTUnwrap(KitGroupPaymentMessage.parse(announcement()))),
                .message(afterCard),
            ],
            isGroup: true
        )

        XCTAssertEqual(named, [first.id, afterSeparator.id, afterOwn.id, afterCard.id])
        XCTAssertFalse(named.contains(mine.id), "your own bubbles never carry your name")
    }

    func testRowsThatRenderNothingDoNotBreakARun() {
        let first = message(ama, "one")
        let silent = message(ben, "KITSYS1:v=1")
        let second = message(ama, "two")

        let named = ConversationSenderRunPolicy.namedMessageIDs(
            in: [.message(first), .message(silent), .message(second)],
            isGroup: true,
            isRendered: { $0.id != silent.id }
        )

        XCTAssertEqual(named, [first.id])
    }

    func testOneToOneThreadsNeverNameTheirSender() {
        let named = ConversationSenderRunPolicy.namedMessageIDs(
            in: [.message(message(ama, "one"))],
            isGroup: false
        )
        XCTAssertTrue(named.isEmpty)
    }

    // MARK: - Copy

    func testNameListsStayShortAndCountTheRest() {
        XCTAssertEqual(GroupPaymentCopy.nameList(["Ama"]), "Ama")
        XCTAssertEqual(GroupPaymentCopy.nameList(["Ama", "Ben"]), "Ama and Ben")
        XCTAssertEqual(GroupPaymentCopy.nameList(["Ama", "Ben", "Cara"]), "Ama, Ben and Cara")
        XCTAssertEqual(
            GroupPaymentCopy.nameList(["Ama", "Ben", "Cara", "Dan"], totalCount: 4),
            "Ama, Ben, Cara and 1 other"
        )
        XCTAssertEqual(
            GroupPaymentCopy.nameList(["Ama", "Ben", "Cara"], totalCount: 7),
            "Ama, Ben, Cara and 4 others"
        )
        XCTAssertNil(GroupPaymentCopy.nameList([" ", ""]))
    }

    func testAnnouncementsSayWhoWasPaidAndOnlyDiscloseWhatTheGroupMayKnow() throws {
        let everyone = try XCTUnwrap(KitGroupPaymentMessage.parse(announcement(audience: .all)))
        XCTAssertEqual(
            GroupPaymentCopy.announcement(
                for: everyone,
                senderName: "Ama",
                isViewerSender: false,
                recipientNames: []
            ),
            "Ama sent UGX 30,000 to everyone"
        )
        XCTAssertEqual(
            GroupPaymentCopy.announcement(
                for: everyone,
                senderName: "Ama",
                isViewerSender: true,
                recipientNames: []
            ),
            "You sent UGX 30,000 to everyone"
        )

        let some = try XCTUnwrap(KitGroupPaymentMessage.parse(announcement(recipients: [ama, ben])))
        XCTAssertEqual(
            GroupPaymentCopy.announcement(
                for: some,
                senderName: "Ama",
                isViewerSender: false,
                recipientNames: ["Ben", "Cara"]
            ),
            "Ama sent UGX 30,000 to Ben and Cara"
        )

        let custom = try XCTUnwrap(KitGroupPaymentMessage(
            action: .sent,
            groupPaymentId: paymentID,
            splitMode: .custom,
            audience: .selected,
            recipientCount: 2,
            currencyCode: "UGX",
            currencyScale: 0,
            recipientUserIds: [ama, ben]
        ))
        XCTAssertEqual(
            GroupPaymentCopy.announcement(
                for: custom,
                senderName: "Ama",
                isViewerSender: false,
                recipientNames: ["Ben", "Cara"]
            ),
            "Ama sent payments to Ben and Cara"
        )
        XCTAssertEqual(
            GroupPaymentCopy.announcement(
                for: custom,
                senderName: "Ama",
                isViewerSender: true,
                recipientNames: ["Ben", "Cara"],
                totalOverride: "30000"
            ),
            "You sent UGX 30,000 to Ben and Cara",
            "the sender may see the pot they themselves sent"
        )
    }

    func testAnUnnamedRosterFallsBackToCountingMembers() throws {
        let some = try XCTUnwrap(KitGroupPaymentMessage.parse(announcement(recipients: [])))
        XCTAssertEqual(
            GroupPaymentCopy.announcement(
                for: some,
                senderName: "Ama",
                isViewerSender: false,
                recipientNames: []
            ),
            "Ama sent UGX 30,000 to 3 members"
        )
    }

    func testEvenShareSubtitleOnlyQuotesAnExactFigureWhenItDividesExactly() throws {
        let exact = try XCTUnwrap(KitGroupPaymentMessage.parse(announcement(audience: .all)))
        XCTAssertEqual(GroupPaymentCopy.evenShareSubtitle(for: exact), "UGX 10,000 each")

        let inexact = try XCTUnwrap(KitGroupPaymentMessage(
            action: .sent,
            groupPaymentId: paymentID,
            splitMode: .even,
            audience: .all,
            recipientCount: 3,
            currencyCode: "UGX",
            currencyScale: 0,
            totalAmountMinor: 30_001
        ))
        XCTAssertEqual(GroupPaymentCopy.evenShareSubtitle(for: inexact), "About UGX 10,000 each")
    }

    func testOutcomeLinesOnlySpeakForTheirAuthor() {
        XCTAssertEqual(
            GroupPaymentCopy.outcome(.accepted, actorName: "Ama", isViewerActor: false),
            "Ama took their share"
        )
        XCTAssertEqual(
            GroupPaymentCopy.outcome(.rejected, actorName: "Ama", isViewerActor: false),
            "Ama declined their share"
        )
        XCTAssertEqual(
            GroupPaymentCopy.outcome(.returned, actorName: "Ama", isViewerActor: true),
            "You returned the unclaimed shares"
        )
        XCTAssertNil(GroupPaymentCopy.outcome(.sent, actorName: "Ama", isViewerActor: false))
    }

    func testSenderProgressIsCountsAndNeverAmounts() throws {
        let waiting = try payment(
            splitMode: "even",
            audience: "all",
            totalAmount: "30000",
            pendingCount: 2,
            acceptedCount: 1
        )
        XCTAssertEqual(GroupPaymentCopy.progress(for: waiting), "1 of 3 taken, 2 waiting")

        let done = try payment(
            splitMode: "even",
            audience: "all",
            totalAmount: "30000",
            pendingCount: 0,
            acceptedCount: 3
        )
        XCTAssertEqual(GroupPaymentCopy.progress(for: done), "All 3 shares taken")

        let partlyReturned = try payment(
            splitMode: "even",
            audience: "all",
            totalAmount: "30000",
            pendingCount: 0,
            acceptedCount: 2,
            returnedCount: 1
        )
        XCTAssertEqual(
            GroupPaymentCopy.progress(for: partlyReturned),
            "2 of 3 taken, 1 returned"
        )
    }

    // MARK: - Composing a send

    func testAnEvenSplitDraftSendsThePotAndLetsTheServerResolveEveryone() throws {
        let outcome = GroupPaymentDraftPolicy.draft(
            sourceWalletId: "wallet-1",
            splitMode: .even,
            audience: .all,
            selected: members(),
            totalInput: "30000",
            customAmounts: [:],
            note: "  Lunch  ",
            scale: 0,
            availableBalance: "50000"
        )
        guard case .ready(let body) = outcome else { return XCTFail("expected a ready draft") }
        XCTAssertEqual(body.totalAmount, "30000")
        XCTAssertEqual(body.note, "Lunch")
        XCTAssertNil(body.recipients, "the roster the server holds at send time is the true one")
    }

    func testADraftIsRefusedBeforeAnyoneIsAskedToApproveIt() {
        let selected = members()
        XCTAssertEqual(
            problem(
                GroupPaymentDraftPolicy.draft(
                    sourceWalletId: "wallet-1",
                    splitMode: .even,
                    audience: .selected,
                    selected: [],
                    totalInput: "30000",
                    customAmounts: [:],
                    note: nil,
                    scale: 0,
                    availableBalance: "50000"
                )
            ),
            "Choose at least one member to pay."
        )
        XCTAssertNotNil(
            problem(
                GroupPaymentDraftPolicy.draft(
                    sourceWalletId: "wallet-1",
                    splitMode: .even,
                    audience: .selected,
                    selected: selected,
                    totalInput: "2",
                    customAmounts: [:],
                    note: nil,
                    scale: 0,
                    availableBalance: "50000"
                )
            ),
            "two whole units cannot be divided between three members"
        )
        XCTAssertEqual(
            problem(
                GroupPaymentDraftPolicy.draft(
                    sourceWalletId: "wallet-1",
                    splitMode: .even,
                    audience: .selected,
                    selected: selected,
                    totalInput: "90000",
                    customAmounts: [:],
                    note: nil,
                    scale: 0,
                    availableBalance: "50000"
                )
            ),
            "Your wallet does not have that much available."
        )
        XCTAssertNotNil(
            problem(
                GroupPaymentDraftPolicy.draft(
                    sourceWalletId: "wallet-1",
                    splitMode: .custom,
                    audience: .all,
                    selected: selected,
                    totalInput: "",
                    customAmounts: [ama: "1000", ben: "2000", cara: "3000"],
                    note: nil,
                    scale: 0,
                    availableBalance: "50000"
                )
            ),
            "different amounts each means choosing the members by hand"
        )
        XCTAssertNotNil(
            problem(
                GroupPaymentDraftPolicy.draft(
                    sourceWalletId: "wallet-1",
                    splitMode: .custom,
                    audience: .selected,
                    selected: selected,
                    totalInput: "",
                    customAmounts: [ama: "1000", ben: "2000"],
                    note: nil,
                    scale: 0,
                    availableBalance: "50000"
                )
            ),
            "a member with no amount is a member who would be paid nothing"
        )
    }

    func testACustomSplitDraftCarriesEveryAmountAndNoPot() throws {
        let outcome = GroupPaymentDraftPolicy.draft(
            sourceWalletId: "wallet-1",
            splitMode: .custom,
            audience: .selected,
            selected: members(),
            totalInput: "",
            customAmounts: [ama: "1000", ben: "2000", cara: "3000"],
            note: nil,
            scale: 0,
            availableBalance: "50000"
        )
        guard case .ready(let body) = outcome else { return XCTFail("expected a ready draft") }
        XCTAssertNil(body.totalAmount)
        XCTAssertEqual(
            try XCTUnwrap(body.recipients),
            [
                CreateGroupPaymentBody.Recipient(userId: ama, amount: "1000"),
                CreateGroupPaymentBody.Recipient(userId: ben, amount: "2000"),
                CreateGroupPaymentBody.Recipient(userId: cara, amount: "3000"),
            ]
        )
        XCTAssertEqual(
            GroupPaymentDraftPolicy.totalMinor(
                splitMode: .custom,
                selected: members(),
                totalInput: "",
                customAmounts: [ama: "1000", ben: "2000", cara: "3000"],
                scale: 0
            ),
            6_000
        )
    }

    func testDraftRejectsMalformedOrDuplicateRecipientIdentities() {
        let duplicate = [
            GroupPaymentDraftPolicy.Member(userId: ama, name: "Ama"),
            GroupPaymentDraftPolicy.Member(userId: ama.uppercased(), name: "Ama again"),
        ]
        XCTAssertNotNil(problem(GroupPaymentDraftPolicy.draft(
            sourceWalletId: "wallet-1",
            splitMode: .even,
            audience: .selected,
            selected: duplicate,
            totalInput: "2000",
            customAmounts: [:],
            note: nil,
            scale: 0,
            availableBalance: "50000"
        )))
        XCTAssertNotNil(problem(GroupPaymentDraftPolicy.draft(
            sourceWalletId: "wallet-1",
            splitMode: .even,
            audience: .selected,
            selected: [.init(userId: "not-a-user", name: "Unknown")],
            totalInput: "2000",
            customAmounts: [:],
            note: nil,
            scale: 0,
            availableBalance: "50000"
        )))
    }

    func testNoteBoundaryCountsUTF16SoAnnouncementCannotFailAfterMoneyMoves() {
        let bounded = GroupPaymentDraftPolicy.boundedNoteInput(String(repeating: "🙂", count: 200))
        XCTAssertEqual(bounded.count, 140)
        XCTAssertEqual(bounded.utf16.count, KitGroupPaymentMessage.maximumNoteLength)
    }

    // MARK: - Step-up binding

    func testTheApprovedIntentPinsTheSplitTheMembersAndTheirAmounts() throws {
        let body = CreateGroupPaymentBody(
            sourceWalletId: "wallet-1",
            splitMode: "custom",
            audience: "selected",
            totalAmount: nil,
            note: "Lunch",
            recipients: [
                CreateGroupPaymentBody.Recipient(userId: ama, amount: "1000"),
                CreateGroupPaymentBody.Recipient(userId: ben, amount: "2000"),
            ]
        )
        let intent = GroupPaymentStepUpPolicy.sendIntent(for: body, conversationId: conversationID)

        XCTAssertEqual(field(intent, "conversation_id"), conversationID)
        XCTAssertEqual(field(intent, "source_wallet_id"), "wallet-1")
        XCTAssertEqual(field(intent, "split_mode"), "custom")
        XCTAssertEqual(field(intent, "audience"), "selected")
        XCTAssertNil(field(intent, "total_amount"))
        XCTAssertEqual(field(intent, "note"), "Lunch")
        XCTAssertEqual(
            field(intent, "recipients"),
            "\(ama):1000,\(ben):2000",
            "approving three shares of one pot must not be replayable as three whole pots"
        )

        let evenBody = CreateGroupPaymentBody(
            sourceWalletId: "wallet-1",
            splitMode: "even",
            audience: "all",
            totalAmount: "30000",
            note: nil,
            recipients: nil
        )
        let evenIntent = GroupPaymentStepUpPolicy.sendIntent(
            for: evenBody,
            conversationId: conversationID
        )
        XCTAssertTrue(evenIntent.keys.contains("recipients"))
        XCTAssertNil(field(evenIntent, "recipients"))
        XCTAssertEqual(field(evenIntent, "total_amount"), "30000")

        XCTAssertEqual(
            try KitFinancialStepUpBinding.intentHash(
                purpose: GroupPaymentStepUpPolicy.sendPurpose,
                intent: evenIntent
            ),
            "13f62a8ec6aa2775af1f879f3b733ee36e07ef82fba66ac54d7b308bc6b92248",
            "the iPhone must hash the same null-normalized intent as Laravel"
        )

        let reverse = GroupPaymentStepUpPolicy.reverseIntent(groupPaymentId: paymentID, reason: nil)
        XCTAssertEqual(field(reverse, "group_payment_id"), paymentID)
        XCTAssertNil(field(reverse, "reason"))
        XCTAssertEqual(GroupPaymentStepUpPolicy.sendPurpose, "group_payment")
        XCTAssertEqual(GroupPaymentStepUpPolicy.reversePurpose, "group_payment_reverse")
    }

    // MARK: - Capability gate

    func testGroupPaymentsNeedClaimableTransfersAsWellAsTheirOwnFlag() {
        XCTAssertFalse(GroupPaymentPolicy(features: nil).groupPaymentsEnabled)
        XCTAssertFalse(
            GroupPaymentPolicy(features: [
                "wallets": true,
                "internal_transfers": true,
                "claimable_transfers": false,
                "group_payments": true,
            ]).groupPaymentsEnabled
        )
        XCTAssertFalse(
            GroupPaymentPolicy(features: [
                "wallets": true,
                "internal_transfers": true,
                "claimable_transfers": true,
                "group_payments": false,
            ]).groupPaymentsEnabled
        )
        XCTAssertTrue(
            GroupPaymentPolicy(features: [
                "wallets": true,
                "internal_transfers": true,
                "claimable_transfers": true,
                "group_payments": true,
            ]).groupPaymentsEnabled
        )
    }

    // MARK: - Scheduled group payments

    func testScheduledGroupPaymentRejectsMalformedPresentRecipientAmount() throws {
        let malformed = try JSONDecoder().decode(
            ScheduledGroupPaymentDTO.self,
            from: Data(scheduledGroupPaymentJSON(firstAmount: "not-money").utf8)
        )

        XCTAssertFalse(
            malformed.isStructurallyValid,
            "null may redact a custom share, but malformed present money must fail closed"
        )
    }

    func testScheduledGroupPlanPinsFrozenRosterAndExactStepUpIntent() throws {
        let plan = try JSONDecoder().decode(
            ScheduledGroupPaymentPlanDTO.self,
            from: Data(scheduledGroupPaymentPlanJSON().utf8)
        )
        let wallet = Wallet(
            id: "80000000-0000-4000-8000-000000000001",
            name: "Primary",
            accountNumber: nil,
            accountType: nil,
            currency: CurrencyDTO(code: "UGX", scale: "0"),
            balances: WalletBalances(available: "50000", ledger: "50000"),
            status: "active",
            isPrimary: true
        )
        let draft = CreateGroupPaymentBody(
            sourceWalletId: wallet.id,
            splitMode: "even",
            audience: "selected",
            totalAmount: "30000",
            note: "Team lunch",
            recipients: [ama, ben, cara].map {
                CreateGroupPaymentBody.Recipient(userId: $0, amount: nil)
            }
        )
        let now = try XCTUnwrap(ScheduledPaymentDates.parse("2026-08-29T10:00:00Z"))
        let scheduled = try XCTUnwrap(
            ScheduledPaymentDates.parse("2026-08-29T12:05:00Z")
        )

        XCTAssertTrue(plan.isStructurallyValid(now: now))
        XCTAssertTrue(plan.matches(
            draft: draft,
            conversationID: conversationID,
            wallet: wallet,
            scheduledFor: scheduled,
            allowedRecipientIDs: [ama, ben, cara],
            now: now
        ))
        XCTAssertEqual(plan.stepUp.intent.fields["plan_hash"]!, plan.planHash)
        XCTAssertEqual(plan.stepUp.intent.fields["frozen_recipients"]!, plan.frozenRecipients)

        let damaged = try JSONDecoder().decode(
            ScheduledGroupPaymentPlanDTO.self,
            from: Data(
                scheduledGroupPaymentPlanJSON()
                    .replacingOccurrences(of: ":10000,\(ben)", with: ":9999,\(ben)")
                    .utf8
            )
        )
        XCTAssertFalse(damaged.isStructurallyValid(now: now))
    }

    func testScheduledGroupCompletionProjectsCanonicalCardForEveryGroupMember() throws {
        let schedule = try JSONDecoder().decode(
            ScheduledGroupPaymentDTO.self,
            from: Data(scheduledGroupPaymentJSON().utf8)
        )
        let eventJSON = """
        {
          "id":"901",
          "type":"scheduled_group_payment.completed",
          "conversation_id":"\(conversationID)",
          "resource_type":"scheduled_group_payment",
          "resource_id":"70000000-0000-4000-8000-000000000090",
          "data":{
            "schema":"kit.scheduled-group-payment.v1",
            "scheduled_group_payment_id":"70000000-0000-4000-8000-000000000090",
            "conversation_id":"\(conversationID)",
            "status":"completed",
            "group_payment_id":"\(paymentID)",
            "scheduled_for":"2026-08-29T12:05:00Z",
            "completed_at":"2026-08-29T12:05:01Z",
            "cancelled_at":null
          },
          "occurred_at":"2026-08-29T12:05:01Z"
        }
        """
        let event = try JSONDecoder().decode(
            MessagingSyncEventDTO.self,
            from: Data(eventJSON.utf8)
        )
        let envelope = try XCTUnwrap(ScheduledGroupPaymentSyncEnvelope(event: event))
        let authoritative = try payment(
            splitMode: "even",
            audience: "selected",
            totalAmount: "30000",
            note: "Team lunch"
        )

        XCTAssertTrue(envelope.matchesAuthoritative(schedule))
        let projection = try XCTUnwrap(ScheduledGroupPaymentProjectionPolicy.completion(
            envelope: envelope,
            schedule: schedule,
            payment: authoritative,
            memberUserIDs: [sender, ama, ben, cara]
        ))
        XCTAssertEqual(projection.senderUserID, sender)
        XCTAssertEqual(projection.descriptor.groupPaymentId, paymentID)
        XCTAssertEqual(projection.descriptor.recipientUserIds, [ama, ben, cara])
        XCTAssertEqual(
            ScheduledGroupPaymentProjectionPolicy.deterministicMessageID(
                scheduledGroupPaymentID: schedule.id,
                groupPaymentID: paymentID
            ),
            ScheduledGroupPaymentProjectionPolicy.deterministicMessageID(
                scheduledGroupPaymentID: schedule.id,
                groupPaymentID: paymentID
            )
        )
    }

    // MARK: - Collaborative requests

    func testGroupRequestWireRoundTripsAndIsReservedFromTypedText() throws {
        let request = try groupRequest()
        let descriptor = try XCTUnwrap(KitGroupPaymentRequestMessage(requesting: request))

        XCTAssertEqual(
            descriptor.encoded,
            "KITGREQ1:v=1&a=requested&id=70000000-0000-4000-8000-000000000001&amt=1000000&cur=UGX&sc=0&note=Team%20equipment"
        )
        XCTAssertEqual(KitGroupPaymentRequestMessage.parse(descriptor.encoded), descriptor)
        XCTAssertFalse(SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(descriptor.encoded))
    }

    func testGroupRequestWireRejectsNonCanonicalAndOverclaimedEvents() {
        let requestID = "70000000-0000-4000-8000-000000000001"
        XCTAssertNil(KitGroupPaymentRequestMessage.parse(
            "KITGREQ1:a=requested&v=1&id=\(requestID)&amt=100&cur=UGX&sc=0"
        ))
        XCTAssertNil(KitGroupPaymentRequestMessage.parse(
            "KITGREQ1:v=1&a=contributed&id=\(requestID)&cid=bad&amt=100"
        ))
        XCTAssertNil(KitGroupPaymentRequestMessage.parse(
            "KITGREQ1:v=1&a=completed&id=\(requestID)&amt=100"
        ))
        XCTAssertNil(KitGroupPaymentRequestMessage.parse(
            "KITGREQ1:v=1&a=completed&id=\(requestID)"
        ))
        XCTAssertNil(KitGroupPaymentRequestMessage.parse(
            "KITGREQ1:v=1&a=cancelled&id=\(requestID)&x=1"
        ))
    }

    func testGroupRequestAuthorityBindsContributorAndFinalCompleter() throws {
        let request = try groupRequest(status: "completed", contributed: 1_000_000)
        let first = try XCTUnwrap(request.contributions.first)
        let last = try XCTUnwrap(request.contributions.last)
        let contribution = try XCTUnwrap(KitGroupPaymentRequestMessage(
            contributing: first,
            requestID: request.id
        ))
        XCTAssertNotNil(GroupPaymentRequestAuthorityPolicy.matchingContribution(
            for: contribution,
            in: request,
            messageAuthorID: first.contributorUserId
        ))
        XCTAssertNil(GroupPaymentRequestAuthorityPolicy.matchingContribution(
            for: contribution,
            in: request,
            messageAuthorID: last.contributorUserId
        ))

        let completed = try XCTUnwrap(KitGroupPaymentRequestMessage(
            completing: last,
            requestID: request.id
        ))
        XCTAssertEqual(
            completed.encoded,
            "KITGREQ1:v=1&a=completed&id=\(request.id)&cid=\(last.id)&amt=750000"
        )
        XCTAssertTrue(GroupPaymentRequestAuthorityPolicy.terminalEventMatches(
            completed,
            request: request,
            messageAuthorID: last.contributorUserId,
            exactContribution: last
        ))
        XCTAssertFalse(GroupPaymentRequestAuthorityPolicy.terminalEventMatches(
            completed,
            request: request,
            messageAuthorID: sender,
            exactContribution: last
        ))
        XCTAssertFalse(GroupPaymentRequestAuthorityPolicy.terminalEventMatches(
            completed,
            request: request,
            messageAuthorID: last.contributorUserId,
            exactContribution: nil
        ))
    }

    func testGroupRequestRejectsAContributionTotalThatContradictsTheRequest() throws {
        let valid = try groupRequest(status: "open", contributed: 250_000)
        XCTAssertTrue(valid.isStructurallyValid)

        let json = groupRequestJSON(
            status: "open",
            contributed: 300_000,
            contributionRows: """
            {
              "id": "70000000-0000-4000-8000-000000000002",
              "contributor_user_id": "\(ama)",
              "amount": "250000",
              "amount_minor": "250000",
              "wallet_transaction_id": null,
              "created_at": "2026-08-29T12:05:00Z",
              "is_yours": true
            }
            """,
            contributorCount: 1
        )
        let contradictory = try JSONDecoder().decode(
            GroupPaymentRequestDTO.self,
            from: Data(json.utf8)
        )
        XCTAssertFalse(contradictory.isStructurallyValid)
    }

    func testGroupRequestAcceptsBoundedRecentContributionWindowAndRepeatedContributor() throws {
        let rows = (0..<50).map { index in
            let suffix = String(format: "%012d", index + 2)
            return """
            {
              "id": "70000000-0000-4000-8000-\(suffix)",
              "contributor_user_id": "\(ama)",
              "amount": "1",
              "amount_minor": "1",
              "wallet_transaction_id": null,
              "created_at": "2026-08-29T12:05:00Z",
              "is_yours": true
            }
            """
        }.joined(separator: ",")
        let cursor = "70000000-0000-4000-8000-000000000002"
        let json = groupRequestJSON(
            status: "open",
            contributed: 55,
            contributionRows: rows,
            contributorCount: 1,
            contributionCount: 55,
            contributionsHasMore: true,
            contributionsNextBefore: cursor
        )
        let request = try JSONDecoder().decode(
            GroupPaymentRequestDTO.self,
            from: Data(json.utf8)
        )

        XCTAssertTrue(request.isStructurallyValid)
        XCTAssertEqual(request.contributionCount, 55)
        XCTAssertEqual(request.contributorCount, 1)
        XCTAssertEqual(request.contributions.count, 50)
    }

    func testGroupRequestRejectsMalformedContributionPaginationCursor() throws {
        let rows = (0..<50).map { index in
            let suffix = String(format: "%012d", index + 2)
            return """
            {
              "id": "70000000-0000-4000-8000-\(suffix)",
              "contributor_user_id": "\(ama)",
              "amount": "1",
              "amount_minor": "1",
              "wallet_transaction_id": null,
              "created_at": "2026-08-29T12:05:00Z",
              "is_yours": true
            }
            """
        }.joined(separator: ",")
        let json = groupRequestJSON(
            status: "open",
            contributed: 55,
            contributionRows: rows,
            contributorCount: 1,
            contributionCount: 55,
            contributionsHasMore: true,
            contributionsNextBefore: "not-a-cursor"
        )
        let request = try JSONDecoder().decode(
            GroupPaymentRequestDTO.self,
            from: Data(json.utf8)
        )

        XCTAssertFalse(request.isStructurallyValid)
    }

    func testForgedEarlyRequestCannotSuppressTheRequesterCard() throws {
        let request = try groupRequest()
        let body = try XCTUnwrap(KitGroupPaymentRequestMessage(requesting: request)).encoded
        let items = timeline([
            message(ama, body),
            message(sender, body),
        ])
        let cards = items.compactMap { item -> LocalMessage? in
            guard case .groupPaymentRequest(let message, _) = item else { return nil }
            return message
        }
        XCTAssertEqual(cards.map(\.senderId), [ama, sender])
    }

    func testGroupRequestProgressCopyIsExactAndDropsTrailingZeroes() {
        XCTAssertEqual(GroupPaymentRequestCopy.progressPercent(0), "0%")
        XCTAssertEqual(GroupPaymentRequestCopy.progressPercent(1_250), "12.5%")
        XCTAssertEqual(GroupPaymentRequestCopy.progressPercent(1_234), "12.34%")
        XCTAssertEqual(GroupPaymentRequestCopy.progressPercent(10_000), "100%")
        XCTAssertEqual(
            GroupPaymentRequestCopy.completedContribution(
                contributorName: "Florence",
                isViewerContributor: false,
                formattedAmount: "UGX 250,000"
            ),
            "Florence contributed UGX 250,000 and completed this request."
        )
        XCTAssertEqual(
            GroupPaymentRequestCopy.completedContribution(
                contributorName: "Florence",
                isViewerContributor: true,
                formattedAmount: "UGX 250,000"
            ),
            "You contributed UGX 250,000 and completed this request."
        )
    }

    func testGroupRequestDraftUsesCanonicalMoneyAndBoundsExpiry() {
        let walletID = "80000000-0000-4000-8000-000000000001"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let outcome = GroupPaymentRequestDraftPolicy.draft(
            destinationWalletID: walletID.uppercased(),
            amountInput: "1,000,000",
            note: "  Team equipment  ",
            expiresAt: now.addingTimeInterval(7 * 24 * 60 * 60),
            currencyScale: 0,
            now: now
        )
        guard case .ready(let body) = outcome else { return XCTFail("expected a ready request") }
        XCTAssertEqual(body.destinationWalletId, walletID)
        XCTAssertEqual(body.totalAmount, "1000000")
        XCTAssertEqual(body.note, "Team equipment")

        XCTAssertNotNil(problem(GroupPaymentRequestDraftPolicy.draft(
            destinationWalletID: walletID,
            amountInput: "1000",
            note: nil,
            expiresAt: now.addingTimeInterval(91 * 24 * 60 * 60),
            currencyScale: 0,
            now: now
        )))
    }

    func testGroupRequestGateNeedsExactProtocolAdvertisement() throws {
        let enabled = try capabilities(groupRequestReady: true, minimumIOS: "1.0.16-r39")
        XCTAssertTrue(GroupPaymentRequestPolicy(capabilities: enabled).enabled)

        let wrongFloor = try capabilities(groupRequestReady: true, minimumIOS: "1.0.16-r38")
        XCTAssertFalse(GroupPaymentRequestPolicy(capabilities: wrongFloor).enabled)

        let notReady = try capabilities(groupRequestReady: false, minimumIOS: "1.0.16-r39")
        XCTAssertFalse(GroupPaymentRequestPolicy(capabilities: notReady).enabled)
    }

    func testContributionApprovalPinsRequestWalletAmountAndCurrency() {
        let walletID = "80000000-0000-4000-8000-000000000001"
        let intent = GroupPaymentRequestContributionPolicy.intent(
            requestID: "70000000-0000-4000-8000-000000000001",
            sourceWalletID: walletID,
            amount: "250000",
            currencyCode: "UGX"
        )
        XCTAssertEqual(field(intent, "action"), "contribute")
        XCTAssertEqual(field(intent, "group_payment_request_id"), "70000000-0000-4000-8000-000000000001")
        XCTAssertEqual(field(intent, "source_wallet_id"), walletID)
        XCTAssertEqual(field(intent, "amount"), "250000")
        XCTAssertEqual(field(intent, "currency"), "UGX")
    }

    // MARK: - Helpers

    private func members() -> [GroupPaymentDraftPolicy.Member] {
        [
            .init(userId: ama, name: "Ama"),
            .init(userId: ben, name: "Ben"),
            .init(userId: cara, name: "Cara"),
        ]
    }

    private func problem(_ outcome: GroupPaymentDraftPolicy.Outcome) -> String? {
        guard case .problem(let message) = outcome else { return nil }
        return message
    }

    private func problem(_ outcome: GroupPaymentRequestDraftPolicy.Outcome) -> String? {
        guard case .problem(let message) = outcome else { return nil }
        return message
    }

    private func capabilities(
        groupRequestReady: Bool,
        minimumIOS: String
    ) throws -> CapabilitiesDTO {
        let json = """
        {
          "api_version": "v1",
          "currency": {"code": "UGX", "scale": "0"},
          "features": {
            "wallets": true,
            "internal_transfers": true,
            "group_payment_requests_v1": true
          },
          "authentication": {},
          "protocols": {
            "payments": {
              "group_payment_requests": {
                "version": "v1",
                "ready": \(groupRequestReady),
                "partial_contributions": true,
                "progress_basis_points_max": 10000,
                "minimum_ios_version": "\(minimumIOS)"
              }
            }
          }
        }
        """
        return try JSONDecoder().decode(CapabilitiesDTO.self, from: Data(json.utf8))
    }

    private func groupRequest(
        status: String = "open",
        contributed: Int64 = 250_000
    ) throws -> GroupPaymentRequestDTO {
        let rows: String
        let contributorCount: Int
        switch contributed {
        case 0:
            rows = ""
            contributorCount = 0
        case 250_000:
            rows = """
            {
              "id": "70000000-0000-4000-8000-000000000002",
              "contributor_user_id": "\(ama)",
              "amount": "250000",
              "amount_minor": "250000",
              "wallet_transaction_id": null,
              "created_at": "2026-08-29T12:05:00Z",
              "is_yours": true
            }
            """
            contributorCount = 1
        default:
            rows = """
            {
              "id": "70000000-0000-4000-8000-000000000002",
              "contributor_user_id": "\(ama)",
              "amount": "250000",
              "amount_minor": "250000",
              "wallet_transaction_id": null,
              "created_at": "2026-08-29T12:05:00Z",
              "is_yours": true
            },
            {
              "id": "70000000-0000-4000-8000-000000000003",
              "contributor_user_id": "\(ben)",
              "amount": "750000",
              "amount_minor": "750000",
              "wallet_transaction_id": null,
              "created_at": "2026-08-29T12:10:00Z",
              "is_yours": false
            }
            """
            contributorCount = 2
        }
        let json = groupRequestJSON(
            status: status,
            contributed: contributed,
            contributionRows: rows,
            contributorCount: contributorCount
        )
        return try JSONDecoder().decode(GroupPaymentRequestDTO.self, from: Data(json.utf8))
    }

    private func scheduledGroupPaymentJSON(firstAmount: String = "10000") -> String {
        """
        {
          "id":"70000000-0000-4000-8000-000000000090",
          "type":"scheduled_group_payment",
          "conversation_id":"\(conversationID)",
          "status":"completed",
          "source_wallet_id":null,
          "split_mode":"even",
          "audience":"selected",
          "total_amount":"30000",
          "currency":{"code":"UGX","scale":"0"},
          "note":"Team lunch",
          "recipient_count":3,
          "recipients":[
            {"user_id":"\(ama)","name":"Ama","amount":"\(firstAmount)"},
            {"user_id":"\(ben)","name":"Ben","amount":"10000"},
            {"user_id":"\(cara)","name":"Cara","amount":"10000"}
          ],
          "group_payment_id":"\(paymentID)",
          "failure":null,
          "scheduled_for":"2026-08-29T12:05:00Z",
          "queued_at":"2026-08-29T12:05:00Z",
          "started_at":"2026-08-29T12:05:00Z",
          "completed_at":"2026-08-29T12:05:01Z",
          "cancelled_at":null,
          "created_at":"2026-08-29T11:00:00Z"
        }
        """
    }

    private func scheduledGroupPaymentPlanJSON() -> String {
        let sourceWallet = "80000000-0000-4000-8000-000000000001"
        let amaWallet = "80000000-0000-4000-8000-000000000002"
        let benWallet = "80000000-0000-4000-8000-000000000003"
        let caraWallet = "80000000-0000-4000-8000-000000000004"
        let frozen = "\(ama):\(amaWallet):10000,\(ben):\(benWallet):10000,\(cara):\(caraWallet):10000"
        return """
        {
          "plan_id":"70000000-0000-4000-8000-000000000091",
          "conversation_id":"\(conversationID)",
          "source_wallet_id":"\(sourceWallet)",
          "split_mode":"even",
          "audience":"selected",
          "total_amount":"30000",
          "currency":{"code":"UGX","scale":"0"},
          "note":"Team lunch",
          "recipient_count":3,
          "recipients":[
            {"user_id":"\(ama)","destination_wallet_id":"\(amaWallet)","amount":"10000"},
            {"user_id":"\(ben)","destination_wallet_id":"\(benWallet)","amount":"10000"},
            {"user_id":"\(cara)","destination_wallet_id":"\(caraWallet)","amount":"10000"}
          ],
          "roster_fingerprint":"\(String(repeating: "a", count: 64))",
          "frozen_recipients":"\(frozen)",
          "plan_hash":"\(String(repeating: "b", count: 64))",
          "scheduled_for":"2026-08-29T12:05:00Z",
          "expires_at":"2026-08-29T10:10:00Z",
          "step_up":{
            "purpose":"scheduled_group_payment",
            "intent":{
              "action":"create",
              "plan_id":"70000000-0000-4000-8000-000000000091",
              "plan_hash":"\(String(repeating: "b", count: 64))",
              "conversation_id":"\(conversationID)",
              "source_wallet_id":"\(sourceWallet)",
              "split_mode":"even",
              "audience":"selected",
              "total_amount":"30000",
              "currency":"UGX",
              "note":"Team lunch",
              "scheduled_for":"2026-08-29T12:05:00Z",
              "roster_fingerprint":"\(String(repeating: "a", count: 64))",
              "frozen_recipients":"\(frozen)"
            }
          }
        }
        """
    }

    private func groupRequestJSON(
        status: String,
        contributed: Int64,
        contributionRows: String,
        contributorCount: Int,
        contributionCount: Int? = nil,
        contributionsHasMore: Bool = false,
        contributionsNextBefore: String? = nil
    ) -> String {
        let contributionCount = contributionCount ?? contributorCount
        let remaining = 1_000_000 - contributed
        let progress = GroupPaymentRequestValidation.progressBasisPoints(
            contributed: contributed,
            target: 1_000_000
        )
        return """
        {
          "id": "70000000-0000-4000-8000-000000000001",
          "type": "group_payment_request",
          "conversation_id": "\(conversationID)",
          "requester_user_id": "\(sender)",
          "status": "\(status)",
          "destination_wallet_id": null,
          "target_amount": "1000000",
          "target_amount_minor": "1000000",
          "contributed_amount": "\(contributed)",
          "contributed_amount_minor": "\(contributed)",
          "remaining_amount": "\(remaining)",
          "remaining_amount_minor": "\(remaining)",
          "progress_basis_points": \(progress),
          "contribution_count": \(contributionCount),
          "contributor_count": \(contributorCount),
          "your_contributed_amount": "0",
          "your_contributed_amount_minor": "0",
          "currency": {"code": "UGX", "scale": "0"},
          "note": "Team equipment",
          "expires_at": "2026-09-05T12:00:00Z",
          "completed_at": \(status == "completed" ? "\"2026-08-29T12:10:00Z\"" : "null"),
          "cancelled_at": \(status == "cancelled" ? "\"2026-08-29T12:10:00Z\"" : "null"),
          "expired_at": \(status == "expired" ? "\"2026-08-29T12:10:00Z\"" : "null"),
          "created_at": "2026-08-29T12:00:00Z",
          "updated_at": "2026-08-29T12:10:00Z",
          "can_contribute": \(status == "open"),
          "can_cancel": false,
          "contributions_has_more": \(contributionsHasMore),
          "contributions_next_before": \(contributionsNextBefore.map { "\"\($0)\"" } ?? "null"),
          "contributions": [\(contributionRows)]
        }
        """
    }

    private func field(_ intent: [String: String?], _ key: String) -> String? {
        intent[key] ?? nil
    }

    private func isCard(_ item: ConversationTimelineItem) -> Bool {
        if case .groupPayment = item { return true }
        return false
    }

    private func isOutcome(_ item: ConversationTimelineItem) -> Bool {
        if case .groupPaymentEvent = item { return true }
        return false
    }

    private func isDateSeparator(_ item: ConversationTimelineItem) -> Bool {
        if case .dateSeparator = item { return true }
        return false
    }

    /// An even-split announcement of UGX 30,000. The stated count always matches the roster, since
    /// the descriptor refuses to name a subset of the members it claims were paid.
    private func announcement(
        audience: GroupPaymentAudience = .selected,
        recipients: [String]? = nil
    ) -> String {
        let roster = audience == .all ? [] : (recipients ?? [ama, ben, cara])
        return KitGroupPaymentMessage(
            action: .sent,
            groupPaymentId: paymentID,
            splitMode: .even,
            audience: audience,
            recipientCount: roster.isEmpty ? 3 : roster.count,
            currencyCode: "UGX",
            currencyScale: 0,
            totalAmountMinor: 30_000,
            recipientUserIds: roster
        )!.encoded
    }

    private func outcome(_ action: KitGroupPaymentMessageAction) -> String {
        KitGroupPaymentMessage(outcome: action, groupPaymentId: paymentID)!.encoded
    }

    private var messageClock = 0.0

    private func message(
        _ senderID: String,
        _ body: String,
        outgoing: Bool = false
    ) -> LocalMessage {
        messageClock += 1
        return LocalMessage(
            id: UUID(),
            conversationId: conversationID,
            senderId: senderID,
            body: body,
            createdAt: Date(timeIntervalSince1970: messageClock),
            sentAt: Date(timeIntervalSince1970: messageClock),
            state: outgoing ? .sent : .received,
            failureReason: nil,
            isOutgoing: outgoing
        )
    }

    private func timeline(_ messages: [LocalMessage]) -> [ConversationTimelineItem] {
        var conversation = Conversation(
            id: conversationID,
            title: "Team",
            participantUserIds: [sender, ama, ben, cara],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        conversation.conversationType = SecureMessagingWire.groupConversationType
        // Separators are opt-in, and a fixed calendar and locale keep the projection the same
        // wherever the test runs.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return ConversationTimelinePolicy.items(
            for: conversation,
            allConversations: [conversation],
            currentUserID: "10000000-0000-4000-8000-000000000009",
            messages: messages,
            calls: [],
            dateSeparatorsRelativeTo: Date(timeIntervalSince1970: 100),
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func payment(
        splitMode: String,
        audience: String,
        totalAmount: String?,
        note: String? = nil,
        pendingCount: Int = 3,
        acceptedCount: Int = 0,
        returnedCount: Int = 0
    ) throws -> GroupPaymentDTO {
        let total = totalAmount.map { "\"total_amount\":\"\($0)\"," } ?? ""
        let noteField = note.map { "\"note\":\"\($0)\"," } ?? ""
        let json = """
        {
          "id": "\(paymentID)",
          "conversation_id": "\(conversationID)",
          "split_mode": "\(splitMode)",
          "audience": "\(audience)",
          "currency": {"code": "UGX", "scale": "0"},
          "sender": {"id": "\(sender)", "name": "Sender"},
          "recipient_count": 3,
          \(total)
          \(noteField)
          "status": "pending",
          "pending_count": \(pendingCount),
          "accepted_count": \(acceptedCount),
          "returned_count": \(returnedCount),
          "can_reverse_unclaimed": true,
          "recipients": [
            {"user_id": "\(ama)", "name": "Ama", "status": "pending"},
            {"user_id": "\(ben)", "name": "Ben", "status": "pending"},
            {"user_id": "\(cara)", "name": "Cara", "status": "pending"}
          ]
        }
        """
        return try JSONDecoder().decode(GroupPaymentDTO.self, from: Data(json.utf8))
    }
}
