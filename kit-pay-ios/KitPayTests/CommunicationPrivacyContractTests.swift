import Foundation
import XCTest
@testable import KitPay

final class CommunicationPrivacyContractTests: XCTestCase {
    private let currentUserId = "10000000-0000-4000-8000-000000000001"
    private let firstUserId = "20000000-0000-4000-8000-000000000001"
    private let secondUserId = "20000000-0000-4000-8000-000000000002"
    private let thirdUserId = "20000000-0000-4000-8000-000000000003"
    private let blockedAt = "2026-08-20T08:00:00Z"

    func testPreferencesDecodeEveryRequiredVersionedField() throws {
        let preferences = try decode(
            CommunicationPreferencesDTO.self,
            from: preferenceObject()
        )

        XCTAssertEqual(preferences.version, 7)
        XCTAssertTrue(preferences.phoneDiscoverable)
        XCTAssertFalse(preferences.directMessageRequestsEnabled)
        XCTAssertTrue(preferences.incomingCallsEnabled)
        XCTAssertTrue(preferences.messagingPresenceVisible)
        XCTAssertEqual(preferences.updatedAt, "2026-08-20T08:30:00.125Z")
    }

    func testPreferencesRejectMissingUnknownOrInvalidValues() throws {
        var invalidObjects: [[String: Any]] = []

        var zeroVersion = preferenceObject()
        zeroVersion["version"] = 0
        invalidObjects.append(zeroVersion)

        var missingPreference = preferenceObject()
        missingPreference.removeValue(forKey: "phone_discoverable")
        invalidObjects.append(missingPreference)

        var missingPresencePreference = preferenceObject()
        missingPresencePreference.removeValue(forKey: "messaging_presence_visible")
        invalidObjects.append(missingPresencePreference)

        var nonBooleanPreference = preferenceObject()
        nonBooleanPreference["direct_message_requests_enabled"] = 1
        invalidObjects.append(nonBooleanPreference)

        var invalidTimestamp = preferenceObject()
        invalidTimestamp["updated_at"] = "2026-08-20"
        invalidObjects.append(invalidTimestamp)

        var paddedTimestamp = preferenceObject()
        paddedTimestamp["updated_at"] = " 2026-08-20T08:30:00Z"
        invalidObjects.append(paddedTimestamp)

        var unknownField = preferenceObject()
        unknownField["effective_call_block"] = true
        invalidObjects.append(unknownField)

        for object in invalidObjects {
            XCTAssertThrowsError(
                try decode(CommunicationPreferencesDTO.self, from: object)
            )
        }
    }

    func testPreferenceUpdateRequiresVersionAndAtLeastOneTypedChange() throws {
        XCTAssertThrowsError(try UpdateCommunicationPreferencesRequest(version: 0)) { error in
            XCTAssertEqual(
                error as? CommunicationPrivacyContractError,
                .invalidPreferenceVersion
            )
        }
        XCTAssertThrowsError(try UpdateCommunicationPreferencesRequest(version: 1)) { error in
            XCTAssertEqual(
                error as? CommunicationPrivacyContractError,
                .emptyPreferenceUpdate
            )
        }

        let request = try UpdateCommunicationPreferencesRequest(
            version: 7,
            phoneDiscoverable: false,
            directMessageRequestsEnabled: true,
            messagingPresenceVisible: false
        )
        let encoded = try jsonObject(request)

        XCTAssertEqual(
            Set(encoded.keys),
            [
                "version", "phone_discoverable", "direct_message_requests_enabled",
                "messaging_presence_visible",
            ]
        )
        XCTAssertEqual(encoded["version"] as? Int, 7)
        XCTAssertEqual(encoded["phone_discoverable"] as? Bool, false)
        XCTAssertEqual(encoded["direct_message_requests_enabled"] as? Bool, true)
        XCTAssertEqual(encoded["messaging_presence_visible"] as? Bool, false)
        XCTAssertNil(encoded["incoming_calls_enabled"])

        let compatibilityRequest = try UpdateCommunicationPreferencesRequest(
            version: 8,
            incomingCallsEnabled: false
        )
        XCTAssertEqual(
            Set(try jsonObject(compatibilityRequest).keys),
            ["version", "incoming_calls_enabled"]
        )
    }

    func testPreferenceChangeValidatesNoOpAndSingleFieldVersionTransitions() throws {
        let current = try decode(
            CommunicationPreferencesDTO.self,
            from: preferenceObject(
                version: 7,
                phoneDiscoverable: false,
                directMessageRequestsEnabled: true,
                incomingCallsEnabled: true
            )
        )
        let change = CommunicationPreferenceChange.phoneDiscovery(true)
        let updated = try decode(
            CommunicationPreferencesDTO.self,
            from: preferenceObject(
                version: 8,
                phoneDiscoverable: true,
                directMessageRequestsEnabled: true,
                incomingCallsEnabled: true
            )
        )
        XCTAssertTrue(change.isValidTransition(from: current, to: updated))

        let wrongVersion = try decode(
            CommunicationPreferencesDTO.self,
            from: preferenceObject(
                version: 7,
                phoneDiscoverable: true,
                directMessageRequestsEnabled: true,
                incomingCallsEnabled: true
            )
        )
        XCTAssertFalse(change.isValidTransition(from: current, to: wrongVersion))

        let changedOmittedField = try decode(
            CommunicationPreferencesDTO.self,
            from: preferenceObject(
                version: 8,
                phoneDiscoverable: true,
                directMessageRequestsEnabled: false,
                incomingCallsEnabled: true
            )
        )
        XCTAssertFalse(change.isValidTransition(from: current, to: changedOmittedField))

        let noOp = CommunicationPreferenceChange.messageRequests(true)
        XCTAssertTrue(noOp.isValidTransition(from: current, to: current))
        XCTAssertEqual(
            Set(try jsonObject(noOp.request(version: current.version)).keys),
            ["version", "direct_message_requests_enabled"]
        )

        let presenceChange = CommunicationPreferenceChange.presenceVisibility(false)
        let presenceUpdated = try decode(
            CommunicationPreferencesDTO.self,
            from: preferenceObject(
                version: 8,
                phoneDiscoverable: false,
                directMessageRequestsEnabled: true,
                incomingCallsEnabled: true,
                messagingPresenceVisible: false
            )
        )
        XCTAssertTrue(presenceChange.isValidTransition(from: current, to: presenceUpdated))
        XCTAssertEqual(
            Set(try jsonObject(presenceChange.request(version: current.version)).keys),
            ["version", "messaging_presence_visible"]
        )
    }

    func testPrivacyEndpointsUseExactCompatibilityPathsAndBoundedQueries() throws {
        XCTAssertEqual(CommunicationPrivacyAPIEndpoint.preferences.path, "communications/preferences")
        XCTAssertTrue(CommunicationPrivacyAPIEndpoint.preferences.queryItems.isEmpty)

        let list = CommunicationPrivacyAPIEndpoint.blocks(cursor: "opaque+/=", limit: 100)
        XCTAssertEqual(list.path, "communications/blocks")
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: list.queryItems.map { ($0.name, $0.value) }),
            ["limit": "100", "cursor": "opaque+/="]
        )

        let block = try CommunicationPrivacyAPIEndpoint.block(rawUserID: firstUserId.uppercased())
        XCTAssertEqual(block.path, "communications/blocks/\(firstUserId)")
        XCTAssertTrue(block.queryItems.isEmpty)
        XCTAssertThrowsError(try CommunicationPrivacyAPIEndpoint.block(rawUserID: "../profile"))
    }

    func testBlockDecodingCanonicalizesUUIDAndValidatesStateTimestamps() throws {
        let active = try decode(
            CommunicationBlockDTO.self,
            from: blockObject(userId: firstUserId.uppercased())
        )
        XCTAssertEqual(active.userId, firstUserId)
        XCTAssertTrue(active.blocked)
        XCTAssertEqual(active.blockedAt, blockedAt)
        XCTAssertNil(active.unblockedAt)

        let neverBlocked = try decode(
            CommunicationBlockDTO.self,
            from: blockObject(
                userId: secondUserId,
                blocked: false,
                blockedAt: nil,
                unblockedAt: nil
            )
        )
        XCTAssertFalse(neverBlocked.blocked)
        XCTAssertNil(neverBlocked.blockedAt)

        let unblocked = try decode(
            CommunicationBlockDTO.self,
            from: blockObject(
                userId: thirdUserId,
                blocked: false,
                blockedAt: blockedAt,
                unblockedAt: "2026-08-20T09:00:00+00:00"
            )
        )
        XCTAssertFalse(unblocked.blocked)
        XCTAssertNotNil(unblocked.unblockedAt)

        // Idempotent DELETE returns explicit null history when no block ever existed. Preserve
        // both keys when this response crosses an encrypted Codable round trip; omitting either
        // optional key makes the strict decoder reject otherwise valid server state.
        let encodedNeverBlocked = try JSONEncoder().encode(neverBlocked)
        let encodedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedNeverBlocked) as? [String: Any]
        )
        XCTAssertTrue(encodedObject["blocked_at"] is NSNull)
        XCTAssertTrue(encodedObject["unblocked_at"] is NSNull)
        XCTAssertEqual(
            try JSONDecoder().decode(CommunicationBlockDTO.self, from: encodedNeverBlocked),
            neverBlocked
        )
    }

    func testBlockDecodingRejectsMalformedIdentityHistoryAndUnknownFields() throws {
        var invalidObjects: [[String: Any]] = []

        var invalidUser = blockObject(userId: firstUserId)
        invalidUser["user_id"] = "not-a-public-id"
        invalidObjects.append(invalidUser)

        var missingNullableTimestamp = blockObject(userId: firstUserId)
        missingNullableTimestamp.removeValue(forKey: "unblocked_at")
        invalidObjects.append(missingNullableTimestamp)

        var activeWithoutTimestamp = blockObject(userId: firstUserId)
        activeWithoutTimestamp["blocked_at"] = NSNull()
        invalidObjects.append(activeWithoutTimestamp)
        invalidObjects.append(blockObject(
            userId: firstUserId,
            blocked: true,
            blockedAt: blockedAt,
            unblockedAt: "2026-08-20T09:00:00Z"
        ))
        invalidObjects.append(blockObject(
            userId: firstUserId,
            blocked: false,
            blockedAt: blockedAt,
            unblockedAt: nil
        ))
        invalidObjects.append(blockObject(
            userId: firstUserId,
            blocked: false,
            blockedAt: blockedAt,
            unblockedAt: "2026-08-19T09:00:00Z"
        ))

        var invalidTimestamp = blockObject(userId: firstUserId)
        invalidTimestamp["blocked_at"] = "yesterday"
        invalidObjects.append(invalidTimestamp)

        var unknownField = blockObject(userId: firstUserId)
        unknownField["display_name"] = "Server supplied name"
        invalidObjects.append(unknownField)

        for object in invalidObjects {
            XCTAssertThrowsError(try decode(CommunicationBlockDTO.self, from: object))
        }
    }

    func testBlockPageStrictlyValidatesLimitCursorAndActiveRows() throws {
        let cursor = "opaque+/= next"
        let page = try decode(
            CommunicationBlockPageDTO.self,
            from: pageObject(
                items: [blockObject(userId: firstUserId)],
                nextCursor: cursor,
                hasMore: true,
                limit: 2
            )
        )
        XCTAssertEqual(page.page.nextCursor, cursor)
        XCTAssertEqual(page.page.limit, 2)
        XCTAssertTrue(page.page.hasMore)

        let oversizedCursor = String(
            repeating: "x",
            count: CommunicationBlockPageAccumulator.maximumCursorLength + 1
        )
        let invalidPages: [[String: Any]] = [
            pageObject(items: [], nextCursor: nil, hasMore: true, limit: 2),
            pageObject(items: [], nextCursor: "unexpected", hasMore: false, limit: 2),
            pageObject(items: [], nextCursor: oversizedCursor, hasMore: true, limit: 2),
            pageObject(items: [], nextCursor: "cursor\nvalue", hasMore: true, limit: 2),
            pageObject(items: [], nextCursor: nil, hasMore: false, limit: 101),
            pageObject(
                items: [
                    blockObject(userId: firstUserId),
                    blockObject(userId: secondUserId),
                ],
                nextCursor: nil,
                hasMore: false,
                limit: 1
            ),
            pageObject(
                items: [
                    blockObject(
                        userId: firstUserId,
                        blocked: false,
                        blockedAt: nil,
                        unblockedAt: nil
                    ),
                ],
                nextCursor: nil,
                hasMore: false,
                limit: 2
            ),
        ]
        for object in invalidPages {
            XCTAssertThrowsError(try decode(CommunicationBlockPageDTO.self, from: object))
        }

        var unknownOuter = pageObject(items: [], nextCursor: nil, hasMore: false, limit: 2)
        unknownOuter["total"] = 0
        XCTAssertThrowsError(try decode(CommunicationBlockPageDTO.self, from: unknownOuter))

        var unknownNested = pageObject(items: [], nextCursor: nil, hasMore: false, limit: 2)
        var nestedPage = try XCTUnwrap(unknownNested["page"] as? [String: Any])
        nestedPage["offset"] = 0
        unknownNested["page"] = nestedPage
        XCTAssertThrowsError(try decode(CommunicationBlockPageDTO.self, from: unknownNested))
    }

    func testBlockAccumulatorFollowsPagesAndDeduplicatesBoundaryUsers() throws {
        var accumulator = CommunicationBlockPageAccumulator(
            requestedLimit: 2,
            maximumPageCount: 4
        )
        let firstPage = try decode(
            CommunicationBlockPageDTO.self,
            from: pageObject(
                items: [blockObject(userId: firstUserId)],
                nextCursor: "page-2",
                hasMore: true,
                limit: 2
            )
        )
        XCTAssertFalse(try accumulator.append(firstPage))

        let terminalPage = try decode(
            CommunicationBlockPageDTO.self,
            from: pageObject(
                items: [
                    blockObject(userId: firstUserId.uppercased()),
                    blockObject(userId: secondUserId),
                ],
                nextCursor: nil,
                hasMore: false,
                limit: 2
            )
        )
        XCTAssertTrue(try accumulator.append(terminalPage))
        XCTAssertEqual(accumulator.blocks.map(\.userId), [firstUserId, secondUserId])
        XCTAssertEqual(accumulator.pageCount, 2)
        XCTAssertNil(accumulator.nextCursor)
    }

    func testBlockAccumulatorRejectsRepeatedCursorAndPageCeilingWithoutMutation() throws {
        XCTAssertEqual(CommunicationBlockPageAccumulator.pageLimit, 100)
        XCTAssertEqual(CommunicationBlockPageAccumulator.maximumPages, 100)
        XCTAssertEqual(CommunicationPrivacyCache.maximumBlockCount, 10_000)

        var repeated = CommunicationBlockPageAccumulator(
            requestedLimit: 1,
            maximumPageCount: 3
        )
        let firstPage = try decode(
            CommunicationBlockPageDTO.self,
            from: pageObject(
                items: [blockObject(userId: firstUserId)],
                nextCursor: "repeated",
                hasMore: true,
                limit: 1
            )
        )
        XCTAssertFalse(try repeated.append(firstPage))

        let repeatedCursorPage = try decode(
            CommunicationBlockPageDTO.self,
            from: pageObject(
                items: [blockObject(userId: secondUserId)],
                nextCursor: "repeated",
                hasMore: true,
                limit: 1
            )
        )
        XCTAssertThrowsError(try repeated.append(repeatedCursorPage))
        XCTAssertEqual(repeated.blocks.map(\.userId), [firstUserId])
        XCTAssertEqual(repeated.pageCount, 1)

        var bounded = CommunicationBlockPageAccumulator(
            requestedLimit: 1,
            maximumPageCount: 2
        )
        XCTAssertFalse(try bounded.append(firstPage))
        let unboundedContinuation = try decode(
            CommunicationBlockPageDTO.self,
            from: pageObject(
                items: [blockObject(userId: secondUserId)],
                nextCursor: "page-3",
                hasMore: true,
                limit: 1
            )
        )
        XCTAssertThrowsError(try bounded.append(unboundedContinuation))
        XCTAssertEqual(bounded.pageCount, 1)
        XCTAssertEqual(bounded.blocks.map(\.userId), [firstUserId])
    }

    func testBlockedPersonResolverUsesContactThenConversationThenNeutralFallback() throws {
        let blocks = try [
            decode(CommunicationBlockDTO.self, from: blockObject(userId: firstUserId)),
            decode(CommunicationBlockDTO.self, from: blockObject(userId: secondUserId)),
            decode(CommunicationBlockDTO.self, from: blockObject(userId: thirdUserId)),
            decode(CommunicationBlockDTO.self, from: blockObject(userId: firstUserId)),
            decode(
                CommunicationBlockDTO.self,
                from: blockObject(
                    userId: "20000000-0000-4000-8000-000000000004",
                    blocked: false,
                    blockedAt: nil,
                    unblockedAt: nil
                )
            ),
        ]
        let contacts = [
            WalletContactDTO(
                id: firstUserId,
                contactId: "device-example_contact",
                name: "ExampleContact",
                phone: "+256 700 000 001",
                isKitUser: true,
                favorite: false,
                status: nil,
                tag: "example_contact",
                avatarURL: "https://objects.example.test/example_contact.jpg",
                receivingWalletId: nil
            ),
        ]
        let conversations = [
            Conversation(
                id: "30000000-0000-4000-8000-000000000001",
                title: "ExampleMerchant",
                participantUserIds: [currentUserId, secondUserId],
                unreadCount: 0,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
        ]

        let people = CommunicationBlockedPersonResolver.resolve(
            blocks: blocks,
            contacts: contacts,
            conversations: conversations,
            currentUserID: currentUserId
        )

        XCTAssertEqual(people.map(\.userId), [firstUserId, secondUserId, thirdUserId])
        XCTAssertEqual(people.map(\.displayName), ["ExampleContact", "ExampleMerchant", "Kit Pay user"])
        XCTAssertEqual(people[0].detail, "@example_contact")
        XCTAssertEqual(people[0].avatarURL, "https://objects.example.test/example_contact.jpg")
        XCTAssertNil(people[1].detail)
        XCTAssertNil(people[2].detail)
        XCTAssertFalse(people[2].displayName.contains(thirdUserId))
    }

    func testBlockedPersonResolverUsesPhoneAfterInvalidTagAndRejectsAmbiguousConversation() throws {
        let block = try decode(
            CommunicationBlockDTO.self,
            from: blockObject(userId: firstUserId)
        )
        let contact = WalletContactDTO(
            id: firstUserId,
            contactId: nil,
            name: " ",
            phone: "+256750000002",
            isKitUser: true,
            favorite: false,
            status: nil,
            tag: "invalid tag",
            avatarURL: nil,
            receivingWalletId: nil
        )
        let unrelated = Conversation(
            id: "30000000-0000-4000-8000-000000000002",
            title: "Must not leak",
            participantUserIds: [currentUserId, firstUserId, secondUserId],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let person = try XCTUnwrap(CommunicationBlockedPersonResolver.resolve(
            blocks: [block],
            contacts: [contact],
            conversations: [unrelated],
            currentUserID: currentUserId
        ).first)
        XCTAssertEqual(person.displayName, "Kit Pay user")
        XCTAssertEqual(person.detail, "+256750000002")
    }

    func testBlockCandidateResolverDeduplicatesAndExcludesOwnerAndBlockedAccounts() throws {
        let blocked = try decode(
            CommunicationBlockDTO.self,
            from: blockObject(userId: firstUserId)
        )
        let contacts = [
            contact(userId: currentUserId, name: "My account"),
            contact(userId: firstUserId, name: "Blocked ExampleContact"),
            contact(userId: secondUserId, name: ""),
            contact(
                userId: secondUserId,
                name: "Amina",
                tag: "amina_pay",
                avatarURL: "https://objects.example.test/amina.jpg"
            ),
            contact(userId: thirdUserId, name: "Zed", phone: "+256700000003"),
            WalletContactDTO(
                id: "device-only",
                contactId: "device-only",
                name: "Invite only",
                phone: "+256700000004",
                isKitUser: false,
                favorite: false,
                status: nil,
                tag: nil,
                avatarURL: nil,
                receivingWalletId: nil
            ),
        ]

        let candidates = CommunicationBlockCandidateResolver.resolve(
            contacts: contacts,
            blocks: [blocked],
            currentUserID: currentUserId
        )

        XCTAssertEqual(candidates.map(\.userId), [secondUserId, thirdUserId])
        XCTAssertEqual(candidates.map(\.displayName), ["Amina", "Zed"])
        XCTAssertEqual(candidates[0].detail, "@amina_pay")
        XCTAssertEqual(candidates[0].avatarURL, "https://objects.example.test/amina.jpg")
        XCTAssertEqual(candidates[1].detail, "+256700000003")
    }

    func testEncryptedCacheRoundTripsOnlyForItsCanonicalOwnerAndActiveUniqueBlocks() throws {
        let preferences = try decode(
            CommunicationPreferencesDTO.self,
            from: preferenceObject()
        )
        let block = try decode(
            CommunicationBlockDTO.self,
            from: blockObject(userId: firstUserId)
        )
        let refreshedAt = Date(timeIntervalSince1970: 1_777_777_777)
        let cache = try XCTUnwrap(CommunicationPrivacyCache(
            ownerUserId: currentUserId.uppercased(),
            preferences: preferences,
            blocks: [block],
            refreshedAt: refreshedAt
        ))
        XCTAssertEqual(cache.ownerUserId, currentUserId)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(cache)
        let encodedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let encodedBlocks = try XCTUnwrap(encodedObject["blocks"] as? [[String: Any]])
        let encodedBlock = try XCTUnwrap(encodedBlocks.first)
        XCTAssertTrue(encodedBlock["unblocked_at"] is NSNull)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(
            try decoder.decode(CommunicationPrivacyCache.self, from: encoded),
            cache
        )

        XCTAssertNil(CommunicationPrivacyCache(
            ownerUserId: currentUserId,
            preferences: preferences,
            blocks: [block, block],
            refreshedAt: refreshedAt
        ))
        let selfBlock = try decode(
            CommunicationBlockDTO.self,
            from: blockObject(userId: currentUserId)
        )
        XCTAssertNil(CommunicationPrivacyCache(
            ownerUserId: currentUserId,
            preferences: preferences,
            blocks: [selfBlock],
            refreshedAt: refreshedAt
        ))
        XCTAssertNil(CommunicationPrivacyCache(
            ownerUserId: "not-an-account",
            preferences: preferences,
            blocks: [],
            refreshedAt: refreshedAt
        ))
    }

    func testEncryptedCacheMigratesMissingPresencePreferenceToBackendDefault() throws {
        let legacyObject: [String: Any] = [
            "owner_user_id": currentUserId,
            "preferences": [
                "version": 7,
                "phone_discoverable": true,
                "direct_message_requests_enabled": false,
                "incoming_calls_enabled": true,
                "updated_at": "2026-08-20T08:30:00.125Z",
            ],
            "blocks": [],
            "refreshed_at": 777_777_777,
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let cache = try decoder.decode(
            CommunicationPrivacyCache.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        XCTAssertTrue(cache.preferences.messagingPresenceVisible)
    }

    func testOutboundAccessFailsClosedWithoutCompleteAccountBoundProjection() throws {
        let preferences = try decode(
            CommunicationPreferencesDTO.self,
            from: preferenceObject()
        )
        let block = try decode(
            CommunicationBlockDTO.self,
            from: blockObject(userId: firstUserId)
        )

        XCTAssertEqual(
            CommunicationPrivacyAccessPolicy.decision(
                ownerUserID: currentUserId,
                recipientUserID: secondUserId,
                hasLoadedCompleteProjection: false,
                blocks: []
            ),
            .unavailable
        )
        XCTAssertEqual(
            CommunicationPrivacyAccessPolicy.decision(
                ownerUserID: currentUserId,
                recipientUserID: secondUserId,
                hasLoadedCompleteProjection: true,
                blocks: []
            ),
            .allowed
        )
        XCTAssertEqual(
            CommunicationPrivacyAccessPolicy.decision(
                ownerUserID: currentUserId,
                recipientUserID: firstUserId,
                hasLoadedCompleteProjection: true,
                blocks: [block]
            ),
            .blocked
        )
        XCTAssertEqual(
            CommunicationPrivacyAccessPolicy.decision(
                ownerUserID: currentUserId,
                recipientUserID: currentUserId,
                hasLoadedCompleteProjection: true,
                blocks: []
            ),
            .unavailable
        )
        XCTAssertEqual(
            CommunicationPrivacyAccessPolicy.decision(
                ownerUserID: currentUserId,
                recipientUserID: secondUserId,
                hasLoadedCompleteProjection: true,
                blocks: [block, block]
            ),
            .unavailable
        )
        XCTAssertTrue(CommunicationPrivacyAccessPolicy.isCompleteProjection(
            ownerUserID: currentUserId,
            hasLoadedCompleteProjection: true,
            blocks: [block]
        ))
        XCTAssertFalse(CommunicationPrivacyAccessPolicy.isCompleteProjection(
            ownerUserID: currentUserId,
            hasLoadedCompleteProjection: true,
            blocks: [block, block]
        ))

        let cache = try XCTUnwrap(CommunicationPrivacyCache(
            ownerUserId: currentUserId,
            preferences: preferences,
            blocks: [block]
        ))
        XCTAssertEqual(
            CommunicationPrivacyAccessPolicy.decision(
                ownerUserID: currentUserId,
                recipientUserID: secondUserId,
                cache: cache
            ),
            .allowed
        )
        XCTAssertEqual(
            CommunicationPrivacyAccessPolicy.decision(
                ownerUserID: secondUserId,
                recipientUserID: thirdUserId,
                cache: cache
            ),
            .unavailable
        )
        XCTAssertEqual(
            CommunicationPrivacyAccessPolicy.decision(
                ownerUserID: currentUserId,
                recipientUserID: secondUserId,
                cache: nil
            ),
            .unavailable
        )
    }

    func testStateWrittenBeforePrivacyCachingStillDecodes() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(PersistedState.empty)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "communicationPrivacy")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(
            PersistedState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(restored.communicationPrivacy)
    }

    func testPrivacyErrorCopyHandlesConflictUnavailableAndRateLimitingNeutrally() {
        let conflict = APIErrorPayload(
            code: "COMMUNICATION_PREFERENCES_VERSION_CONFLICT",
            message: "Internal optimistic-lock detail.",
            httpStatus: 409
        )
        XCTAssertEqual(
            CommunicationPrivacyErrorCopy.message(for: conflict, operation: .updatePreferences),
            "Your communication settings changed elsewhere. Refresh them before trying again."
        )

        let unavailable = APIErrorPayload(
            code: "COMMUNICATION_TARGET_UNAVAILABLE",
            message: "Enumeration-sensitive target detail.",
            httpStatus: 422
        )
        XCTAssertEqual(
            CommunicationPrivacyErrorCopy.message(for: unavailable, operation: .block),
            "This person is unavailable for this action."
        )

        let rateLimited = APIErrorPayload(
            code: "TOO_MANY_REQUESTS",
            message: "Framework limiter detail.",
            httpStatus: 429,
            retryAfter: 30
        )
        let expectedRateCopy = "Too many requests were made. Please wait a moment and try again."
        XCTAssertEqual(
            CommunicationPrivacyErrorCopy.message(for: rateLimited, operation: .block),
            expectedRateCopy
        )
        XCTAssertEqual(
            CommunicationPrivacyErrorCopy.message(
                for: APIClientError.httpResponse(status: 429, retryAfter: 5),
                operation: .load
            ),
            expectedRateCopy
        )
    }

    func testPrivacyErrorCopyIsProfessionalAndNeverClaimsLegacyCallBlocking() {
        let genericError = APIClientError.invalidPayload(status: 200)
        let expected: [CommunicationPrivacyOperation: String] = [
            .load: "Kit Pay could not load your communication privacy settings. Please try again.",
            .updatePreferences:
                "Kit Pay could not save your communication settings. Refresh them and try again.",
            .block: "Kit Pay could not block this person. Please try again.",
            .unblock: "Kit Pay could not unblock this person. Please try again.",
        ]

        for operation in CommunicationPrivacyOperation.allCases {
            let message = CommunicationPrivacyErrorCopy.message(
                for: genericError,
                operation: operation
            )
            XCTAssertEqual(message, expected[operation])
            XCTAssertFalse(message.localizedCaseInsensitiveContains("incoming_calls_enabled"))
            XCTAssertFalse(message.localizedCaseInsensitiveContains("prevents calls"))
            XCTAssertFalse(message.localizedCaseInsensitiveContains("effective blocking"))
            XCTAssertFalse(message.localizedCaseInsensitiveContains("HTTP 200"))
        }
    }

    private func preferenceObject(
        version: Int = 7,
        phoneDiscoverable: Bool = true,
        directMessageRequestsEnabled: Bool = false,
        incomingCallsEnabled: Bool = true,
        messagingPresenceVisible: Bool = true
    ) -> [String: Any] {
        [
            "version": version,
            "phone_discoverable": phoneDiscoverable,
            "direct_message_requests_enabled": directMessageRequestsEnabled,
            "incoming_calls_enabled": incomingCallsEnabled,
            "messaging_presence_visible": messagingPresenceVisible,
            "updated_at": "2026-08-20T08:30:00.125Z",
        ]
    }

    private func blockObject(
        userId: String,
        blocked: Bool = true,
        blockedAt: String? = nil,
        unblockedAt: String? = nil
    ) -> [String: Any] {
        let blockedTimestamp: Any
        if let blockedAt {
            blockedTimestamp = blockedAt
        } else {
            blockedTimestamp = blocked ? self.blockedAt : NSNull()
        }
        let unblockedTimestamp: Any
        if let unblockedAt {
            unblockedTimestamp = unblockedAt
        } else {
            unblockedTimestamp = NSNull()
        }
        return [
            "user_id": userId,
            "blocked": blocked,
            "blocked_at": blockedTimestamp,
            "unblocked_at": unblockedTimestamp,
        ]
    }

    private func pageObject(
        items: [[String: Any]],
        nextCursor: String?,
        hasMore: Bool,
        limit: Int
    ) -> [String: Any] {
        let cursor: Any
        if let nextCursor {
            cursor = nextCursor
        } else {
            cursor = NSNull()
        }
        return [
            "items": items,
            "page": [
                "next_cursor": cursor,
                "has_more": hasMore,
                "limit": limit,
            ],
        ]
    }

    private func contact(
        userId: String,
        name: String,
        phone: String = "+256700000000",
        tag: String? = nil,
        avatarURL: String? = nil
    ) -> WalletContactDTO {
        WalletContactDTO(
            id: userId,
            contactId: "device-\(userId)",
            name: name,
            phone: phone,
            isKitUser: true,
            favorite: false,
            status: nil,
            tag: tag,
            avatarURL: avatarURL,
            receivingWalletId: nil
        )
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from object: Any
    ) throws -> Value {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(type, from: data)
    }

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
