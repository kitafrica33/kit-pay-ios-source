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
        pendingCount: Int = 3,
        acceptedCount: Int = 0,
        returnedCount: Int = 0
    ) throws -> GroupPaymentDTO {
        let total = totalAmount.map { "\"total_amount\":\"\($0)\"," } ?? ""
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
