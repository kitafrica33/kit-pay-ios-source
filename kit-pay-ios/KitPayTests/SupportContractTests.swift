import Foundation
import XCTest

@testable import KitPay

final class SupportContractTests: XCTestCase {
    // MARK: - Capability gating

    func testSupportUnavailableWhenCapabilitiesMissing() {
        XCTAssertFalse(SupportContract.available(features: nil))
        XCTAssertFalse(SupportContract.available(features: [:]))
        XCTAssertFalse(SupportContract.available(features: ["support": nil]))
        XCTAssertFalse(SupportContract.available(features: ["support": false]))
        XCTAssertFalse(SupportContract.available(features: ["other": true]))
    }

    func testSupportAvailableOnlyWhenServerAdvertisesIt() {
        XCTAssertTrue(SupportContract.available(features: ["support": true]))
    }

    /// A coherent protocols.support advertisement matching this client's typed contract exactly.
    /// Built through the internal memberwise initializer; the strict wire decoder has its own
    /// fixture-based tests below.
    private func makeSupportProtocol(
        ready: Bool = true,
        endToEndEncrypted: Bool = false,
        content: String = "server_readable",
        transport: String = "poll",
        attachmentsEnabled: Bool = false,
        aiEnabled: Bool = false,
        paymentsReady: Bool = false
    ) -> SupportProtocolDTO {
        SupportProtocolDTO(
            ready: ready,
            endToEndEncrypted: endToEndEncrypted,
            content: content,
            transport: transport,
            attachmentsEnabled: attachmentsEnabled,
            aiEnabled: aiEnabled,
            payments: SupportPaymentsProtocolDTO(
                ready: paymentsReady,
                beneficiaryKind: "company",
                beneficiaryDisplayName: "Kit Africa"
            )
        )
    }

    private var coherentGateFeatures: [String: Bool?] {
        ["support": true, "support_ai": false]
    }

    func testSupportGateRequiresFeatureFlagAndTypedContractTogether() {
        let support = makeSupportProtocol()

        // The fully coherent advertisement is the ONLY available state.
        XCTAssertEqual(
            SupportGate.state(features: coherentGateFeatures, support: support),
            .available(aiProcessingEnabled: false)
        )
        XCTAssertEqual(
            SupportGate.state(
                features: ["support": true, "support_ai": true],
                support: makeSupportProtocol(aiEnabled: true)
            ),
            .available(aiProcessingEnabled: true)
        )

        // Bare feature flag without the typed protocol block is never enough.
        XCTAssertEqual(
            SupportGate.state(features: coherentGateFeatures, support: nil),
            .unavailable
        )
        // Protocol block without the feature flag is never enough.
        XCTAssertEqual(
            SupportGate.state(features: ["support": false, "support_ai": false], support: support),
            .unavailable
        )
        XCTAssertEqual(SupportGate.state(features: nil, support: support), .unavailable)
        // The support_ai flag must be explicitly present and non-null — never assumed off.
        XCTAssertEqual(
            SupportGate.state(features: ["support": true], support: support),
            .unavailable
        )
        XCTAssertEqual(
            SupportGate.state(features: ["support": true, "support_ai": nil], support: support),
            .unavailable
        )
        // Every field of the typed contract must match this client exactly.
        XCTAssertEqual(
            SupportGate.state(
                features: coherentGateFeatures,
                support: makeSupportProtocol(ready: false)
            ),
            .unavailable
        )
        XCTAssertEqual(
            SupportGate.state(
                features: coherentGateFeatures,
                support: makeSupportProtocol(endToEndEncrypted: true)
            ),
            .unavailable
        )
        XCTAssertEqual(
            SupportGate.state(
                features: coherentGateFeatures,
                support: makeSupportProtocol(content: "customer_only")
            ),
            .unavailable
        )
        XCTAssertEqual(
            SupportGate.state(
                features: coherentGateFeatures,
                support: makeSupportProtocol(transport: "websocket")
            ),
            .unavailable
        )
        // This client ships no attachment pipeline; an attachments-enabled advertisement is a
        // contract this client does not implement and must fail closed.
        XCTAssertEqual(
            SupportGate.state(
                features: coherentGateFeatures,
                support: makeSupportProtocol(attachmentsEnabled: true)
            ),
            .unavailable
        )
        // The support_ai flag and protocols.support.ai.enabled must agree exactly.
        XCTAssertEqual(
            SupportGate.state(
                features: coherentGateFeatures,
                support: makeSupportProtocol(aiEnabled: true)
            ),
            .unavailable
        )
        XCTAssertEqual(
            SupportGate.state(
                features: ["support": true, "support_ai": true],
                support: makeSupportProtocol(aiEnabled: false)
            ),
            .unavailable
        )
    }

    func testDeletionAssistanceFailsClosedToLegalDeletionPage() {
        let support = makeSupportProtocol()

        XCTAssertEqual(
            SupportContract.deletionAssistancePath(features: nil, support: nil),
            .legalDeletionPage
        )
        // The bare feature flag no longer opens in-app support anywhere — deletion assistance
        // rides the same full typed gate as every other support surface.
        XCTAssertEqual(
            SupportContract.deletionAssistancePath(features: ["support": true], support: nil),
            .legalDeletionPage
        )
        XCTAssertEqual(
            SupportContract.deletionAssistancePath(
                features: ["support": false, "support_ai": false],
                support: support
            ),
            .legalDeletionPage
        )
        // A malformed contract field fails closed to the legal deletion page.
        XCTAssertEqual(
            SupportContract.deletionAssistancePath(
                features: coherentGateFeatures,
                support: makeSupportProtocol(endToEndEncrypted: true)
            ),
            .legalDeletionPage
        )
        XCTAssertEqual(
            SupportContract.deletionAssistancePath(
                features: coherentGateFeatures,
                support: support
            ),
            .inAppSupport
        )
    }

    // MARK: - Verified-official predicate (fail closed on partial/inconsistent metadata)

    func testVerifiedOfficialSupportRequiresOfficialFlagAndDesignationTogether() {
        let officialSupport = SupportVerificationDTO(designation: "official_support")

        XCTAssertTrue(
            SupportContract.isVerifiedOfficialSupport(
                official: true,
                verification: officialSupport
            )
        )
        // official flag alone is never enough.
        XCTAssertFalse(
            SupportContract.isVerifiedOfficialSupport(official: true, verification: nil)
        )
        // Wrong or unknown designation fails closed.
        XCTAssertFalse(
            SupportContract.isVerifiedOfficialSupport(
                official: true,
                verification: SupportVerificationDTO(designation: "support")
            )
        )
        XCTAssertFalse(
            SupportContract.isVerifiedOfficialSupport(
                official: true,
                verification: SupportVerificationDTO(designation: "OFFICIAL_SUPPORT")
            )
        )
        XCTAssertFalse(
            SupportContract.isVerifiedOfficialSupport(
                official: true,
                verification: SupportVerificationDTO(designation: "")
            )
        )
        // Designation alone is never enough either.
        XCTAssertFalse(
            SupportContract.isVerifiedOfficialSupport(
                official: false,
                verification: officialSupport
            )
        )
        XCTAssertFalse(
            SupportContract.isVerifiedOfficialSupport(official: false, verification: nil)
        )
    }

    func testIdentityVerificationFailsClosedOnMalformedMetadata() throws {
        func identity(_ json: String) throws -> SupportIdentityDTO {
            try JSONDecoder().decode(SupportIdentityDTO.self, from: Data(json.utf8))
        }

        let verified = try identity(
            """
            {"display_name": "Kit Support", "official": true,
             "verification": {"designation": "official_support"}}
            """
        )
        XCTAssertTrue(verified.isVerifiedOfficialSupport)

        let officialWithoutVerification = try identity(
            """
            {"display_name": "Kit Support", "official": true, "verification": null}
            """
        )
        XCTAssertFalse(officialWithoutVerification.isVerifiedOfficialSupport)

        let officialWithWrongDesignation = try identity(
            """
            {"display_name": "Kit Support", "official": true,
             "verification": {"designation": "partner"}}
            """
        )
        XCTAssertFalse(officialWithWrongDesignation.isVerifiedOfficialSupport)

        let designatedButNotOfficial = try identity(
            """
            {"display_name": "Kit Support", "official": false,
             "verification": {"designation": "official_support"}}
            """
        )
        XCTAssertFalse(designatedButNotOfficial.isVerifiedOfficialSupport)
    }

    func testSenderVerificationFailsClosedForCustomersAndInconsistentMetadata() throws {
        func sender(_ json: String) throws -> SupportSenderDTO {
            try JSONDecoder().decode(SupportSenderDTO.self, from: Data(json.utf8))
        }

        // A customer message can never earn the seal, whatever flags the payload carries.
        let customerClaimingOfficial = try sender(
            """
            {"type": "customer", "display_name": "Kit Support", "official": true,
             "automated": false, "verification": {"designation": "official_support"},
             "agent_alias": null}
            """
        )
        XCTAssertFalse(customerClaimingOfficial.isVerifiedOfficialSupport)

        let verifiedAgent = try sender(
            """
            {"type": "agent", "display_name": "Kit Support", "official": true,
             "automated": false, "verification": {"designation": "official_support"},
             "agent_alias": "Amina"}
            """
        )
        XCTAssertTrue(verifiedAgent.isVerifiedOfficialSupport)

        let agentWithoutVerification = try sender(
            """
            {"type": "agent", "display_name": "Kit Support", "official": true,
             "automated": false, "verification": null, "agent_alias": null}
            """
        )
        XCTAssertFalse(agentWithoutVerification.isVerifiedOfficialSupport)

        let assistantWithWrongDesignation = try sender(
            """
            {"type": "assistant", "display_name": "Kit Assistant", "official": true,
             "automated": true, "verification": {"designation": "assistant"},
             "agent_alias": null}
            """
        )
        XCTAssertFalse(assistantWithWrongDesignation.isVerifiedOfficialSupport)
    }

    // MARK: - Ticket-scoped avatars

    func testAvatarInitialsDeriveFromTicketScopedAliasOnly() {
        XCTAssertEqual(SupportContract.avatarInitials(fromAlias: "Amina K."), "AK")
        XCTAssertEqual(SupportContract.avatarInitials(fromAlias: "Sam"), "S")
        // Only the first two words contribute, and case is normalized.
        XCTAssertEqual(SupportContract.avatarInitials(fromAlias: "amina katherine okello"), "AK")
        XCTAssertEqual(SupportContract.avatarInitials(fromAlias: "édouard n"), "ÉN")
        // Nothing letterable yields nil (caller falls back to the official mark).
        XCTAssertNil(SupportContract.avatarInitials(fromAlias: nil))
        XCTAssertNil(SupportContract.avatarInitials(fromAlias: ""))
        XCTAssertNil(SupportContract.avatarInitials(fromAlias: "   "))
    }

    func testTicketScopedAvatarNeverDecoratesCustomersOrUnverifiedSenders() throws {
        func sender(_ json: String) throws -> SupportSenderDTO {
            try JSONDecoder().decode(SupportSenderDTO.self, from: Data(json.utf8))
        }

        // A customer never carries identity artwork in a support thread — even one whose
        // payload claims official flags.
        let customer = try sender(
            """
            {"type": "customer", "display_name": "Kit Support", "official": true,
             "automated": false, "verification": {"designation": "official_support"},
             "agent_alias": null}
            """
        )
        XCTAssertEqual(customer.ticketScopedAvatar, SupportSenderAvatar.none)

        // An unverified non-customer must not borrow official-looking artwork either.
        let unverifiedAgent = try sender(
            """
            {"type": "agent", "display_name": "Kit Support", "official": true,
             "automated": false, "verification": null, "agent_alias": "Amina"}
            """
        )
        XCTAssertEqual(unverifiedAgent.ticketScopedAvatar, SupportSenderAvatar.none)

        // Verified human agents get initials from the ticket-scoped alias only.
        let verifiedAgent = try sender(
            """
            {"type": "agent", "display_name": "Kit Support", "official": true,
             "automated": false, "verification": {"designation": "official_support"},
             "agent_alias": "Amina K."}
            """
        )
        XCTAssertEqual(verifiedAgent.ticketScopedAvatar, .initials("AK"))

        // A verified agent without an alias falls back to the official mark, never an
        // empty disc.
        let verifiedAgentNoAlias = try sender(
            """
            {"type": "agent", "display_name": "Kit Support", "official": true,
             "automated": false, "verification": {"designation": "official_support"},
             "agent_alias": null}
            """
        )
        XCTAssertEqual(verifiedAgentNoAlias.ticketScopedAvatar, .officialMark)

        // Verified assistant and system senders wear the official mark.
        let assistant = try sender(
            """
            {"type": "assistant", "display_name": "Kit Assistant", "official": true,
             "automated": true, "verification": {"designation": "official_support"},
             "agent_alias": null}
            """
        )
        XCTAssertEqual(assistant.ticketScopedAvatar, .officialMark)

        let system = try sender(
            """
            {"type": "system", "display_name": "Kit Pay", "official": true,
             "automated": false, "verification": {"designation": "official_support"},
             "agent_alias": null}
            """
        )
        XCTAssertEqual(system.ticketScopedAvatar, .officialMark)
    }

    // MARK: - Client policy pins

    func testAttachmentSupportFailsClosedInThisVersion() {
        // The request DTOs cannot carry `media_asset_id` (the encode tests pin the exact key
        // sets), and this flag documents that attachments stay fail-closed until a real
        // authenticated pipeline exists.
        XCTAssertFalse(SupportContract.attachmentsSupported)
    }

    func testMessagesPageLimitMatchesServerContract() {
        XCTAssertEqual(SupportContract.messagesPageLimit, 100)
    }

    func testNewContractErrorsExplainThemselves() {
        XCTAssertNotNil(SupportContractError.inconsistentThread.errorDescription)
        XCTAssertNotNil(SupportContractError.supportUnavailable.errorDescription)
    }

    // MARK: - Identifier hygiene

    func testCanonicalTicketIDAcceptsOnlyExactUUIDs() {
        let canonical = SupportContract.canonicalTicketID(
            "0B8C2A4E-93F1-4A6B-8D2C-5E7F01234567"
        )
        XCTAssertEqual(canonical, "0b8c2a4e-93f1-4a6b-8d2c-5e7f01234567")

        XCTAssertNil(SupportContract.canonicalTicketID(""))
        XCTAssertNil(SupportContract.canonicalTicketID("not-a-uuid"))
        XCTAssertNil(SupportContract.canonicalTicketID("../support/tickets"))
        XCTAssertNil(SupportContract.canonicalTicketID("123"))
        XCTAssertNil(
            SupportContract.canonicalTicketID(" 0b8c2a4e-93f1-4a6b-8d2c-5e7f01234567")
        )
        XCTAssertNil(
            SupportContract.canonicalTicketID("0b8c2a4e-93f1-4a6b-8d2c-5e7f01234567\n")
        )
    }

    // MARK: - Input normalization boundaries

    func testNormalizedSubjectEnforcesServerBounds() {
        XCTAssertNil(SupportContract.normalizedSubject(""))
        XCTAssertNil(SupportContract.normalizedSubject("ab"))
        XCTAssertNil(SupportContract.normalizedSubject("  ab  "))
        XCTAssertEqual(SupportContract.normalizedSubject("  abc  "), "abc")
        XCTAssertEqual(
            SupportContract.normalizedSubject(String(repeating: "s", count: 140))?.count,
            140
        )
        XCTAssertNil(SupportContract.normalizedSubject(String(repeating: "s", count: 141)))
    }

    func testNormalizedMessageBodyEnforcesServerBounds() {
        XCTAssertNil(SupportContract.normalizedMessageBody(""))
        XCTAssertNil(SupportContract.normalizedMessageBody("   \n  "))
        XCTAssertEqual(SupportContract.normalizedMessageBody(" hello "), "hello")
        XCTAssertEqual(
            SupportContract.normalizedMessageBody(String(repeating: "m", count: 4000))?.count,
            4000
        )
        XCTAssertNil(SupportContract.normalizedMessageBody(String(repeating: "m", count: 4001)))
    }

    // MARK: - Category preselection

    func testPreferredCategoryMatchesHintsCaseInsensitively() {
        let categories = [
            SupportCategoryDTO(id: "1", key: "payments", name: "Payments", description: nil),
            SupportCategoryDTO(
                id: "2",
                key: "Account_Deletion",
                name: "Account deletion",
                description: nil
            ),
        ]
        XCTAssertEqual(SupportContract.preferredCategory(in: categories)?.id, "2")
        XCTAssertEqual(
            SupportContract.preferredCategory(in: categories, hints: ["payments"])?.id,
            "1"
        )
        XCTAssertNil(SupportContract.preferredCategory(in: categories, hints: ["unknown"]))
        XCTAssertNil(SupportContract.preferredCategory(in: []))
    }

    // MARK: - Wire decoding (fixtures mirror the backend SupportPresenter payloads)

    func testDecodesTicketFromServerPayload() throws {
        let json = """
        {
            "id": "0b8c2a4e-93f1-4a6b-8d2c-5e7f01234567",
            "reference": "KP-SUP-000123",
            "subject": "Card declined",
            "status": "open",
            "category": {"key": "payments", "name": "Payments"},
            "support_identity": {
                "display_name": "Kit Support",
                "official": true,
                "verification": {"designation": "official_support"}
            },
            "assistant_active": true,
            "message_count": 3,
            "created_at": "2026-08-28T09:15:00Z",
            "last_message_at": "2026-08-28T09:20:00Z",
            "closed": null,
            "end_to_end_encrypted": false,
            "content_visibility": "server_readable"
        }
        """
        let ticket = try JSONDecoder().decode(
            SupportTicketDTO.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(ticket.id, "0b8c2a4e-93f1-4a6b-8d2c-5e7f01234567")
        XCTAssertEqual(ticket.reference, "KP-SUP-000123")
        XCTAssertEqual(ticket.category.key, "payments")
        XCTAssertEqual(ticket.supportIdentity.displayName, "Kit Support")
        XCTAssertTrue(ticket.supportIdentity.official)
        XCTAssertEqual(
            ticket.supportIdentity.verification?.designation,
            "official_support"
        )
        XCTAssertTrue(ticket.assistantActive)
        XCTAssertEqual(ticket.messageCount, 3)
        XCTAssertNil(ticket.closed)
        XCTAssertTrue(ticket.isOpen)
        XCTAssertTrue(ticket.isServerReadable)
        XCTAssertNotNil(SupportDates.parse(ticket.createdAt))
    }

    func testDecodesClosedTicketAndClosureReason() throws {
        let json = """
        {
            "id": "0b8c2a4e-93f1-4a6b-8d2c-5e7f01234567",
            "reference": "KP-SUP-000124",
            "subject": "Resolved question",
            "status": "closed",
            "category": {"key": "account", "name": "Account"},
            "support_identity": {
                "display_name": "Kit Support",
                "official": true,
                "verification": {"designation": "official_support"}
            },
            "assistant_active": false,
            "message_count": 5,
            "created_at": "2026-08-27T10:00:00Z",
            "last_message_at": "2026-08-28T08:00:00Z",
            "closed": {"at": "2026-08-28T08:00:00Z", "reason_code": "customer_closed"},
            "end_to_end_encrypted": false,
            "content_visibility": "server_readable"
        }
        """
        let ticket = try JSONDecoder().decode(
            SupportTicketDTO.self,
            from: Data(json.utf8)
        )
        XCTAssertFalse(ticket.isOpen)
        XCTAssertEqual(ticket.closed?.reasonCode, "customer_closed")
        XCTAssertNotNil(SupportDates.parse(ticket.closed?.at))
    }

    func testNeverTreatsSupportThreadAsEndToEndEncrypted() throws {
        // Support is server-readable by contract — the capability gate itself requires
        // end_to_end_encrypted == false. A ticket payload claiming encryption contradicts the
        // advertised protocol, so it fails closed: it is never coherent server-readable state
        // and the strict validator rejects it outright, so it can never be rendered under a
        // privacy promise the product cannot keep.
        let json = """
        {
            "id": "0b8c2a4e-93f1-4a6b-8d2c-5e7f01234567",
            "reference": "KP-SUP-000125",
            "subject": "Claiming encryption",
            "status": "open",
            "category": {"key": "account", "name": "Account"},
            "support_identity": {"display_name": "Kit Support", "official": true, "verification": null},
            "assistant_active": false,
            "message_count": 1,
            "created_at": "2026-08-28T09:15:00Z",
            "last_message_at": null,
            "closed": null,
            "end_to_end_encrypted": true,
            "content_visibility": "server_readable"
        }
        """
        let ticket = try JSONDecoder().decode(
            SupportTicketDTO.self,
            from: Data(json.utf8)
        )
        XCTAssertFalse(ticket.isServerReadable)
        XCTAssertThrowsError(try SupportThreadPageValidator.validateTicket(ticket))
    }

    func testDecodesMessagesAndSenderKinds() throws {
        let json = """
        {
            "items": [
                {
                    "id": "1c2d3e4f-0000-4000-8000-000000000001",
                    "position": 1,
                    "sender": {
                        "type": "customer",
                        "display_name": "You",
                        "official": false,
                        "automated": false,
                        "verification": null,
                        "agent_alias": null
                    },
                    "body": "My card was declined.",
                    "attachment": null,
                    "created_at": "2026-08-28T09:15:00Z"
                },
                {
                    "id": "1c2d3e4f-0000-4000-8000-000000000002",
                    "position": 2,
                    "sender": {
                        "type": "agent",
                        "display_name": "Kit Support",
                        "official": true,
                        "automated": false,
                        "verification": {"designation": "official_support"},
                        "agent_alias": "Amina"
                    },
                    "body": "Happy to help.",
                    "attachment": {"media_asset_id": "9f8e7d6c-0000-4000-8000-000000000003"},
                    "created_at": "2026-08-28T09:20:00Z"
                }
            ],
            "ticket": {
                "id": "0b8c2a4e-93f1-4a6b-8d2c-5e7f01234567",
                "reference": "KP-SUP-000123",
                "subject": "Card declined",
                "status": "open",
                "category": {"key": "payments", "name": "Payments"},
                "support_identity": {
                    "display_name": "Kit Support",
                    "official": true,
                    "verification": {"designation": "official_support"}
                },
                "assistant_active": false,
                "message_count": 2,
                "created_at": "2026-08-28T09:15:00Z",
                "last_message_at": "2026-08-28T09:20:00Z",
                "closed": null,
                "end_to_end_encrypted": false,
                "content_visibility": "server_readable"
            }
        }
        """
        let list = try JSONDecoder().decode(
            SupportMessageListDTO.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(list.items.count, 2)
        XCTAssertTrue(list.items[0].sender.isCustomer)
        XCTAssertFalse(list.items[0].sender.isVerifiedOfficialSupport)
        XCTAssertFalse(list.items[1].sender.isCustomer)
        XCTAssertTrue(list.items[1].sender.isVerifiedOfficialSupport)
        XCTAssertTrue(list.ticket.supportIdentity.isVerifiedOfficialSupport)
        XCTAssertEqual(list.items[1].sender.agentAlias, "Amina")
        XCTAssertEqual(
            list.items[1].attachment?.mediaAssetID,
            "9f8e7d6c-0000-4000-8000-000000000003"
        )
        XCTAssertEqual(list.ticket.messageCount, 2)
    }

    func testDecodesSnapshotPaginationCursor() throws {
        let json = """
        {
            "ticket": {
                "id": "0b8c2a4e-93f1-4a6b-8d2c-5e7f01234567",
                "reference": "KP-SUP-000123",
                "subject": "Card declined",
                "status": "open",
                "category": {"key": "payments", "name": "Payments"},
                "support_identity": {
                    "display_name": "Kit Support",
                    "official": true,
                    "verification": {"designation": "official_support"}
                },
                "assistant_active": false,
                "message_count": 250,
                "created_at": "2026-08-28T09:15:00Z",
                "last_message_at": "2026-08-28T09:20:00Z",
                "closed": null,
                "end_to_end_encrypted": false,
                "content_visibility": "server_readable"
            },
            "messages": [],
            "messages_has_more": true,
            "messages_next_after_position": 200
        }
        """
        let snapshot = try JSONDecoder().decode(
            SupportTicketSnapshotDTO.self,
            from: Data(json.utf8)
        )
        XCTAssertTrue(snapshot.messagesHasMore)
        XCTAssertEqual(snapshot.messagesNextAfterPosition, 200)
    }

    // MARK: - Wire encoding

    func testEncodesOpenTicketRequestWithSnakeCaseKeys() throws {
        let request = OpenSupportTicketRequestDTO(
            categoryKey: "payments",
            subject: "Card declined",
            message: "My card was declined.",
            clientMessageID: "0b8c2a4e-93f1-4a6b-8d2c-5e7f01234567"
        )
        let object = try encodeToDictionary(request)
        XCTAssertEqual(object["category_key"] as? String, "payments")
        XCTAssertEqual(object["subject"] as? String, "Card declined")
        XCTAssertEqual(object["message"] as? String, "My card was declined.")
        XCTAssertEqual(
            object["client_message_id"] as? String,
            "0b8c2a4e-93f1-4a6b-8d2c-5e7f01234567"
        )
        XCTAssertEqual(object.count, 4)
    }

    func testEncodesSendMessageRequestWithSnakeCaseKeys() throws {
        let request = SendSupportMessageRequestDTO(
            body: "Thanks!",
            clientMessageID: "0b8c2a4e-93f1-4a6b-8d2c-5e7f01234567"
        )
        let object = try encodeToDictionary(request)
        XCTAssertEqual(object["body"] as? String, "Thanks!")
        XCTAssertEqual(
            object["client_message_id"] as? String,
            "0b8c2a4e-93f1-4a6b-8d2c-5e7f01234567"
        )
        XCTAssertEqual(object.count, 2)
    }

    // MARK: - Endpoint routing

    func testSupportEndpointsUseValidatedTicketPaths() {
        let id = "0b8c2a4e-93f1-4a6b-8d2c-5e7f01234567"
        XCTAssertEqual(SupportAPIEndpoint.categories.path, "support/categories")
        XCTAssertEqual(SupportAPIEndpoint.categories.method, "GET")
        XCTAssertEqual(SupportAPIEndpoint.tickets.path, "support/tickets")
        XCTAssertEqual(SupportAPIEndpoint.ticket(id: id).path, "support/tickets/\(id)")
        XCTAssertEqual(SupportAPIEndpoint.close(id: id).path, "support/tickets/\(id)/close")
        XCTAssertEqual(SupportAPIEndpoint.close(id: id).method, "POST")
        XCTAssertEqual(
            SupportAPIEndpoint.escalate(id: id).path,
            "support/tickets/\(id)/escalate"
        )
        XCTAssertEqual(SupportAPIEndpoint.escalate(id: id).method, "POST")
        XCTAssertEqual(
            SupportAPIEndpoint.messages(id: id).path,
            "support/tickets/\(id)/messages"
        )
    }

    // MARK: - Pagination authority

    func testAPIMetaDecodesPaginationFieldsStrictly() throws {
        let full = try JSONDecoder().decode(APIMeta.self, from: Data("""
        {
            "request_id": "req-1",
            "server_time": "2026-08-28T09:15:00Z",
            "next_cursor": "eyJjcmVhdGVkX2F0IjoiMjAyNiJ9",
            "has_more": true,
            "idempotent_replay": false
        }
        """.utf8))
        XCTAssertEqual(full.nextCursor, "eyJjcmVhdGVkX2F0IjoiMjAyNiJ9")
        XCTAssertEqual(full.hasMore, true)
        XCTAssertEqual(full.idempotentReplay, false)

        // Absent keys and explicit nulls both decode as nil — strictly optional.
        let empty = try JSONDecoder().decode(APIMeta.self, from: Data("{}".utf8))
        XCTAssertNil(empty.nextCursor)
        XCTAssertNil(empty.hasMore)
        XCTAssertNil(empty.idempotentReplay)

        let nulled = try JSONDecoder().decode(APIMeta.self, from: Data("""
        {"next_cursor": null, "has_more": false, "idempotent_replay": null}
        """.utf8))
        XCTAssertNil(nulled.nextCursor)
        XCTAssertEqual(nulled.hasMore, false)
        XCTAssertNil(nulled.idempotentReplay)

        // A present key of the wrong type must fail the decode (and with it the whole request),
        // never coerce.
        XCTAssertThrowsError(
            try JSONDecoder().decode(APIMeta.self, from: Data(#"{"has_more": "yes"}"#.utf8))
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(APIMeta.self, from: Data(#"{"next_cursor": 42}"#.utf8))
        )
    }

    func testTicketPageContinuationRequiresCoherentMetaPair() throws {
        let more = try SupportThreadPageValidator.validateTicketPageContinuation(
            hasMore: true,
            nextCursor: "cursor-1"
        )
        XCTAssertTrue(more.hasMore)
        XCTAssertEqual(more.nextCursor, "cursor-1")

        let drained = try SupportThreadPageValidator.validateTicketPageContinuation(
            hasMore: false,
            nextCursor: nil
        )
        XCTAssertFalse(drained.hasMore)
        XCTAssertNil(drained.nextCursor)

        // Missing meta pair: the endpoint contract is not being spoken — reject, never infer
        // completeness from page fullness.
        XCTAssertThrowsError(
            try SupportThreadPageValidator.validateTicketPageContinuation(
                hasMore: nil,
                nextCursor: nil
            )
        )
        // has_more without a usable cursor (absent, empty, or beyond the server's own bound).
        XCTAssertThrowsError(
            try SupportThreadPageValidator.validateTicketPageContinuation(
                hasMore: true,
                nextCursor: nil
            )
        )
        XCTAssertThrowsError(
            try SupportThreadPageValidator.validateTicketPageContinuation(
                hasMore: true,
                nextCursor: ""
            )
        )
        XCTAssertThrowsError(
            try SupportThreadPageValidator.validateTicketPageContinuation(
                hasMore: true,
                nextCursor: String(
                    repeating: "a",
                    count: SupportContract.ticketsCursorMaximumLength + 1
                )
            )
        )
        // A cursor alongside has_more == false is a contradiction.
        XCTAssertThrowsError(
            try SupportThreadPageValidator.validateTicketPageContinuation(
                hasMore: false,
                nextCursor: "cursor-1"
            )
        )
    }

    func testForwardWindowRemainingFollowsAuthoritativeMessageCount() throws {
        // Above the loaded window: more history remains.
        XCTAssertTrue(
            try SupportThreadPageValidator.forwardWindowRemaining(
                lastLoadedPosition: 3,
                ticket: makeTicket(messageCount: 5)
            )
        )
        // Equal: drained — even though a fullness heuristic might have claimed otherwise.
        XCTAssertFalse(
            try SupportThreadPageValidator.forwardWindowRemaining(
                lastLoadedPosition: 5,
                ticket: makeTicket(messageCount: 5)
            )
        )
        // Empty thread.
        XCTAssertFalse(
            try SupportThreadPageValidator.forwardWindowRemaining(
                lastLoadedPosition: 0,
                ticket: makeTicket(messageCount: 0)
            )
        )
        // A count BELOW the validated delivered window contradicts the payload: reject the page
        // rather than pretend the loaded messages don't exist.
        XCTAssertThrowsError(
            try SupportThreadPageValidator.forwardWindowRemaining(
                lastLoadedPosition: 5,
                ticket: makeTicket(messageCount: 4)
            )
        ) {
            XCTAssertEqual($0 as? SupportContractError, .inconsistentThread)
        }
        // Bounded arithmetic: a hostile window position fails closed instead of trapping.
        XCTAssertThrowsError(
            try SupportThreadPageValidator.forwardWindowRemaining(
                lastLoadedPosition: -1,
                ticket: makeTicket(messageCount: 5)
            )
        )
        XCTAssertThrowsError(
            try SupportThreadPageValidator.forwardWindowRemaining(
                lastLoadedPosition: SupportContract.maxMessagePosition + 1,
                ticket: makeTicket(messageCount: Int.max)
            )
        )
    }

    // MARK: - Helpers

    private func makeTicket(messageCount: Int) throws -> SupportTicketDTO {
        try JSONDecoder().decode(SupportTicketDTO.self, from: Data("""
        {
            "id": "0b8c2a4e-93f1-4a6b-8d2c-5e7f01234567",
            "reference": "KP-SUP-000123",
            "subject": "Card declined",
            "status": "open",
            "category": {"key": "payments", "name": "Payments"},
            "support_identity": {
                "display_name": "Kit Support",
                "official": true,
                "verification": {"designation": "official_support"}
            },
            "assistant_active": false,
            "message_count": \(messageCount),
            "created_at": "2026-08-28T09:15:00Z",
            "last_message_at": null,
            "closed": null,
            "end_to_end_encrypted": false,
            "content_visibility": "server_readable"
        }
        """.utf8))
    }

    private func encodeToDictionary(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }
}
