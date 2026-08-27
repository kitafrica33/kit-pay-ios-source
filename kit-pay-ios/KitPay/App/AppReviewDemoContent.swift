import Foundation

enum AppReviewDemoCapabilityAuthority: Equatable, Sendable {
    case publicDiscovery
    case authenticatedSession
}

/// Authenticated capability policy for Apple's review account. A public capabilities response,
/// process argument, environment variable, or locally cached profile is never sufficient.
enum AppReviewDemoAccessPolicy {
    static let featureKey = "app_review_demo"

    static func ownerID(
        features: [String: Bool?]?,
        authority: AppReviewDemoCapabilityAuthority,
        isSignedIn: Bool,
        profileID: String?,
        sessionID: String?,
        sessionAccountID: String?
    ) -> String? {
        guard authority == .authenticatedSession,
              isSignedIn,
              features?[featureKey] == true,
              let profileID = canonicalUUID(profileID),
              let sessionAccountID = canonicalUUID(sessionAccountID),
              profileID == sessionAccountID,
              sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return nil }
        return profileID
    }

    private static func canonicalUUID(_ rawValue: String?) -> String? {
        guard let rawValue,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              let identifier = UUID(uuidString: rawValue)
        else { return nil }
        return identifier.uuidString.lowercased()
    }
}

enum AppReviewDemoMutationError: LocalizedError, Equatable {
    case readOnly

    var errorDescription: String? {
        "This App Review account is read-only."
    }
}

/// One fail-closed policy shared by UI guards and the authenticated HTTP boundary. The reviewer
/// may inspect live GET projections, sign out, and submit an abuse report for the one provisioned
/// Amina conversation. Every other authenticated write stays blocked even if a stale sheet,
/// notification action, or background task tries to bypass the visible controls.
enum AppReviewDemoMutationPolicy {
    static let readOnlyMessage = "This App Review account is read-only."

    static func allowsAccountMutation(
        isSignedIn: Bool,
        hasAuthenticatedCapabilities: Bool,
        isDemoActive: Bool
    ) -> Bool {
        isSignedIn && hasAuthenticatedCapabilities && !isDemoActive
    }

    static func conversationIsReadOnly(
        _ conversationID: String,
        isDemoActive: Bool
    ) -> Bool {
        isDemoActive || AppReviewDemoContent.isSyntheticConversationID(conversationID)
    }

    static func callIsReadOnly(_ callID: String, isDemoActive: Bool) -> Bool {
        isDemoActive || AppReviewDemoContent.isSyntheticCallID(callID)
    }

    static func peerIsReadOnly(_ peerID: String, isDemoActive: Bool) -> Bool {
        isDemoActive || AppReviewDemoContent.isSyntheticPeerID(peerID)
    }

    static func allowsAuthenticatedRequest(
        method rawMethod: String,
        path rawPath: String,
        isDemoSession: Bool
    ) -> Bool {
        guard isDemoSession else { return true }
        let method = rawMethod.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if ["GET", "HEAD", "OPTIONS"].contains(method) { return true }

        let path = rawPath
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        return (method == "POST" && path == AbuseReportAPIEndpoint.path)
            || (method == "POST" && path == "auth/logout")
            || (method == "POST" && path == "auth/refresh")
            || (method == "DELETE" && path == "devices/current/push-token")
    }

    static func allowsAbuseReport(
        conversationID: String,
        reportedUserID: String,
        isDemoSession: Bool
    ) -> Bool {
        !isDemoSession || AppReviewDemoContent.isProvisionedReportingTarget(
            conversationID: conversationID,
            peerID: reportedUserID
        )
    }
}

/// Models the capability transition separately so a transient failure cannot silently turn a
/// protected or not-yet-classified authenticated session writable. A successful non-demo result
/// is the sole transition that permits the transport fence to be removed, and callers do that
/// only after replacing any synthetic projection.
struct AppReviewDemoCapabilityFenceDecision: Equatable {
    let projectedOwnerID: String?
    let keepsTransportFenceAfterProjection: Bool

    static func resolved(ownerID: String?) -> Self {
        Self(
            projectedOwnerID: ownerID,
            keepsTransportFenceAfterProjection: ownerID != nil
        )
    }

    static func failed(previousOwnerID: String?) -> Self {
        Self(
            projectedOwnerID: previousOwnerID,
            keepsTransportFenceAfterProjection: true
        )
    }
}

/// In-memory, non-financial sample content for the authenticated App Review account. It never
/// enters SecureLocalStore, never changes the profile/wallet/transaction projection, and uses a
/// reserved set of synthetic identifiers so actions can remain read-only.
enum AppReviewDemoContent {
    private static let peerIDs = [
        "d0000000-0000-4000-8000-000000000001",
        "d0000000-0000-4000-8000-000000000002",
        "d0000000-0000-4000-8000-000000000003",
        "d0000000-0000-4000-8000-000000000004",
        "d0000000-0000-4000-8000-000000000005",
    ]
    private static let conversationIDs = [
        "d1000000-0000-4000-8000-000000000001",
        "d1000000-0000-4000-8000-000000000002",
        "d1000000-0000-4000-8000-000000000003",
        "d1000000-0000-4000-8000-000000000004",
        "d1000000-0000-4000-8000-000000000005",
    ]
    private static let callIDs = [
        "d2000000-0000-4000-8000-000000000001",
        "d2000000-0000-4000-8000-000000000002",
        "d2000000-0000-4000-8000-000000000003",
        "d2000000-0000-4000-8000-000000000004",
        "d2000000-0000-4000-8000-000000000005",
    ]

    static func projectedState(
        from persisted: PersistedState,
        authenticatedOwnerID: String,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> PersistedState {
        guard persisted.profile?.id.caseInsensitiveCompare(authenticatedOwnerID) == .orderedSame,
              persisted.communicationOwnerUserID?.caseInsensitiveCompare(authenticatedOwnerID)
                == .orderedSame
        else { return persisted }

        var result = persisted
        let anchor = calendar.startOfDay(for: now)
        let conversations = demoConversations(ownerID: authenticatedOwnerID, anchor: anchor)
        let conversationIDSet = Set(conversationIDs)
        result.conversations.removeAll { conversationIDSet.contains($0.id.lowercased()) }
        result.conversations.append(contentsOf: conversations)

        result.messages.removeAll { conversationIDSet.contains($0.conversationId.lowercased()) }
        result.messages.append(
            contentsOf: demoMessages(ownerID: authenticatedOwnerID, anchor: anchor)
        )

        let callIDSet = Set(callIDs)
        result.calls.removeAll { callIDSet.contains($0.id.lowercased()) }
        result.calls.append(contentsOf: demoCalls(ownerID: authenticatedOwnerID, anchor: anchor))

        var pinned = result.pinnedConversationIds ?? []
        if !pinned.contains(conversationIDs[0]) { pinned.append(conversationIDs[0]) }
        result.pinnedConversationIds = pinned
        return result
    }

    static func isSyntheticConversationID(_ rawValue: String) -> Bool {
        conversationIDs.contains(rawValue.lowercased())
    }

    static func isSyntheticCallID(_ rawValue: String) -> Bool {
        callIDs.contains(rawValue.lowercased())
    }

    static func isSyntheticPeerID(_ rawValue: String) -> Bool {
        peerIDs.contains(rawValue.lowercased())
    }

    /// Only this pair is provisioned on the server, so the review UI must never advertise a
    /// successful account report for the other in-memory preview conversations.
    static func isProvisionedReportingTarget(
        conversationID rawConversationID: String,
        peerID rawPeerID: String?
    ) -> Bool {
        guard let rawPeerID else { return false }
        return rawConversationID.lowercased() == conversationIDs[0]
            && rawPeerID.lowercased() == peerIDs[0]
    }

    private static func demoConversations(ownerID: String, anchor: Date) -> [Conversation] {
        let names = [
            "Amina Demo", "Brian Sample", "Claire Demo", "Daniel Sample", "Esther Demo",
        ]
        return conversationIDs.indices.map { index in
            Conversation(
                id: conversationIDs[index],
                title: names[index],
                participantUserIds: [ownerID, peerIDs[index]],
                unreadCount: index == 1 ? 2 : 0,
                updatedAt: anchor.addingTimeInterval(9 * 3_600 + Double(35 - index * 6) * 60)
            )
        }
    }

    private static func demoMessages(ownerID: String, anchor: Date) -> [LocalMessage] {
        let primary = conversationIDs[0]
        let primaryPeer = peerIDs[0]
        var messages = [
            message(1, conversationID: primary, senderID: primaryPeer, body: "Welcome to the Kit Pay App Review demo 👋", minute: 4, outgoing: false, anchor: anchor),
            message(2, conversationID: primary, senderID: ownerID, body: "Thanks! Messages and calls live together here.", minute: 8, outgoing: true, anchor: anchor),
            message(3, conversationID: primary, senderID: primaryPeer, body: "This sample conversation is a read-only preview.", minute: 12, outgoing: false, anchor: anchor),
            message(4, conversationID: primary, senderID: ownerID, body: "Everything is end-to-end encrypted on real chats.", minute: 17, outgoing: true, anchor: anchor),
            message(5, conversationID: primary, senderID: primaryPeer, body: "You can explore Chats, Calls, Profile and the payment flows.", minute: 24, outgoing: false, anchor: anchor),
            message(6, conversationID: primary, senderID: ownerID, body: "Great — the demo data is clearly marked and contains no real customer information.", minute: 31, outgoing: true, anchor: anchor),
        ]
        let previews = [
            "Your secure message preview is ready.",
            "The sample call is scheduled for later.",
            "Thanks for reviewing Kit Pay.",
            "Profile and privacy controls are available too.",
        ]
        for index in 1 ..< conversationIDs.count {
            messages.append(
                message(
                    10 + index,
                    conversationID: conversationIDs[index],
                    senderID: index == 1 ? peerIDs[index] : ownerID,
                    body: previews[index - 1],
                    minute: 30 - index * 5,
                    outgoing: index != 1,
                    anchor: anchor
                )
            )
        }
        return messages
    }

    private static func demoCalls(ownerID: String, anchor: Date) -> [CallRecord] {
        let names = ["Amina Demo", "Brian Sample", "Claire Demo", "Daniel Sample", "Esther Demo"]
        return callIDs.indices.map { index in
            let start = anchor.addingTimeInterval(Double(8 - index) * 3_600 + 15 * 60)
            let completed = index != 2
            return CallRecord(
                id: callIDs[index],
                name: names[index],
                participantUserIds: [ownerID, peerIDs[index]],
                direction: index.isMultiple(of: 2) ? "incoming" : "outgoing",
                type: index == 1 || index == 3 ? "video" : "voice",
                video: index == 1 || index == 3,
                state: completed ? .completed : .missed,
                startedAt: start,
                endedAt: completed ? start.addingTimeInterval(Double(70 + index * 31)) : start,
                isDeferredAttempt: false,
                conversationId: index == 0 ? conversationIDs[0] : nil,
                answeredAt: completed ? start.addingTimeInterval(7) : nil
            )
        }
    }

    private static func message(
        _ index: Int,
        conversationID: String,
        senderID: String,
        body: String,
        minute: Int,
        outgoing: Bool,
        anchor: Date
    ) -> LocalMessage {
        let date = anchor.addingTimeInterval(9 * 3_600 + Double(minute) * 60)
        return LocalMessage(
            id: UUID(uuidString: String(format: "d3000000-0000-4000-8000-%012d", index))!,
            serverMessageId: nil,
            conversationId: conversationID,
            senderId: senderID,
            body: body,
            createdAt: date,
            sentAt: date,
            state: outgoing ? .read : .received,
            failureReason: nil,
            isOutgoing: outgoing
        )
    }
}
