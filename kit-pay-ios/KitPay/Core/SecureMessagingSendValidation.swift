import Foundation

enum SecureMessagingExchangeError: LocalizedError, Equatable {
    case invalidAccount
    case invalidRecipient
    case invalidConversation
    case messageNotRetryable
    case invalidServerResponse
    case unsupportedEvent(String)
    case staleOutboundFanout
    case retryLimitExceeded
    case groupCapabilityUnavailable
    case reactionCapabilityUnavailable
    case editCapabilityUnavailable
    case richMediaCapabilityUnavailable
    case mediaMessageCapabilityUnavailable
    case mediaMessageBlobExpired
    case mediaMessageRosterChanged

    var errorDescription: String? {
        switch self {
        case .invalidAccount: "Your messaging account changed. Sign in again to continue."
        case .invalidRecipient: "Choose one valid Kit Pay recipient."
        case .invalidConversation: "This conversation is no longer available."
        case .messageNotRetryable: "This message can no longer be retried."
        case .invalidServerResponse: "Kit could not load this conversation. Please try again."
        case .unsupportedEvent: "Kit could not process a message update. Please try again."
        case .staleOutboundFanout: "The recipient's devices changed. Retry the message."
        case .retryLimitExceeded: "Messages changed while syncing. Please try again."
        case .groupCapabilityUnavailable:
            "Everyone in this group needs the latest Kit Pay to receive messages."
        case .reactionCapabilityUnavailable:
            "Everyone in this conversation needs the latest Kit Pay to use reactions."
        case .editCapabilityUnavailable:
            "Everyone in this conversation needs the latest Kit Pay to see edited messages."
        case .richMediaCapabilityUnavailable:
            "This attachment is waiting for secure media delivery to become available."
        case .mediaMessageCapabilityUnavailable:
            "Multiple attachments aren't available for this chat right now."
        case .mediaMessageBlobExpired:
            "The attachments expired before sending. Kit Pay is uploading them again."
        case .mediaMessageRosterChanged:
            "The recipient's devices changed. Kit Pay is securing this message again."
        }
    }
}

struct ValidatedDirectConversation: Codable {
    let id: String
    /// The single peer of a direct thread. Always nil for groups — a group has no "the" recipient.
    let recipientUserID: String?
    let memberUserIDs: Set<String>
    let title: String
    let updatedAt: Date
    let conversationType: String
    let groupMemberRoles: [String: MessagingGroupRole]?
    /// Server-visible group identity; always nil for a direct thread, which discloses nothing.
    let groupDescription: String?
    let groupPhotoURL: String?
    let memberIdentities: [String: AccountIdentityProjection]?

    var isGroup: Bool { conversationType == SecureMessagingWire.groupConversationType }

    /// Canonical outbox recipient list: the single direct peer, or every group member but self.
    func outboundRecipientUserIDs(excluding localUserID: String) -> [String] {
        if let recipientUserID { return [recipientUserID] }
        return memberUserIDs.filter { $0 != localUserID }.sorted()
    }

    #if !KIT_SHARE_EXTENSION
    var localProjection: Conversation {
        Conversation(
            id: id,
            title: title,
            participantUserIds: memberUserIDs.sorted(),
            unreadCount: 0,
            updatedAt: updatedAt,
            conversationType: conversationType,
            groupMemberRoles: groupMemberRoles,
            groupDescription: groupDescription,
            groupPhotoURL: groupPhotoURL,
            memberIdentities: memberIdentities
        )
    }
    #endif
}

struct OutboundEcho {
    let clientMessageID: String
    let serverMessageID: String
    let sentAt: Date
    let historyMetadata: SecureMessagingRetainedMessageMetadata
}

enum SecureMessagingConversationValidation {
    static func validate(
        _ dto: MessagingConversationDTO,
        currentUserID: String,
        expectedRecipientUserID: String?,
        fallbackTitle: String
    ) throws -> ValidatedDirectConversation {
        guard let type = dto.type,
              let rawID = dto.id,
              let members = dto.members,
              members.allSatisfy({ $0 != nil })
        else { throw SecureMessagingExchangeError.invalidConversation }
        let id = try canonicalUUID(rawID, error: .invalidConversation)
        let values = members.compactMap { $0 }
        var memberIDs: Set<String> = []
        var memberIdentities: [String: AccountIdentityProjection] = [:]
        for member in values {
            let userID = try canonicalUUID(member.userId, error: .invalidConversation)
            guard memberIDs.insert(userID).inserted else {
                throw SecureMessagingExchangeError.invalidConversation
            }
            if let identity = AccountIdentityProjection(
                displayName: member.name,
                avatarURL: member.avatarUrl,
                verification: member.verification
            ) {
                memberIdentities[userID] = identity
            }
        }
        let parsedUpdatedAt = try? parseServerDate(dto.updatedAt)

        switch type {
        case SecureMessagingWire.directConversationType:
            guard members.count == 2,
                  memberIDs.count == 2,
                  memberIDs.contains(currentUserID),
                  let recipient = memberIDs.first(where: { $0 != currentUserID }),
                  expectedRecipientUserID.map({ $0 == recipient }) ?? true
            else { throw SecureMessagingExchangeError.invalidConversation }
            let serverTitle = dto.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            // Direct titles are server-null by contract; prefer the viewer-scoped peer alias.
            let peerName = memberIdentities[recipient]?.displayName
            let fallback = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = [peerName, serverTitle, fallback, "Kit Pay contact"]
                .compactMap { $0 }
                .first(where: { !$0.isEmpty })!
            // Identity fields belong to groups alone. A direct conversation carrying either is
            // not describing a thread this client knows how to trust.
            guard dto.description == nil, dto.photoUrl == nil else {
                throw SecureMessagingExchangeError.invalidConversation
            }
            return ValidatedDirectConversation(
                id: id,
                recipientUserID: recipient,
                memberUserIDs: memberIDs,
                title: title,
                updatedAt: parsedUpdatedAt ?? Date(),
                conversationType: type,
                groupMemberRoles: nil,
                groupDescription: nil,
                groupPhotoURL: nil,
                memberIdentities: memberIdentities.isEmpty ? nil : memberIdentities
            )

        case SecureMessagingWire.groupConversationType:
            // A group has no single peer; any caller pinning an expected direct recipient must
            // fail closed rather than address one member of a wider roster.
            guard expectedRecipientUserID == nil,
                  memberIDs.count == values.count,
                  (1 ... SecureMessagingWire.maximumGroupMembers).contains(memberIDs.count),
                  memberIDs.contains(currentUserID),
                  let updatedAt = parsedUpdatedAt
            else { throw SecureMessagingExchangeError.invalidConversation }
            // Group titles are server-owned: the server title wins for every member; the
            // neutral fallback never leaks a per-viewer alias into a shared thread name.
            guard let title = dto.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  MessagingGroupTitlePolicy.isValid(title)
            else { throw SecureMessagingExchangeError.invalidConversation }
            let rawRoles = values.map(\.role)
            let memberRoles: [String: MessagingGroupRole]?
            if rawRoles.allSatisfy({ $0 == nil }) {
                memberRoles = nil
            } else {
                guard rawRoles.allSatisfy({ $0 != nil }) else {
                    throw SecureMessagingExchangeError.invalidConversation
                }
                var roles: [String: MessagingGroupRole] = [:]
                for member in values {
                    guard let rawUserID = member.userId,
                          let userID = try? canonicalUUID(
                              rawUserID,
                              error: .invalidConversation
                          ),
                          let rawRole = member.role,
                          let role = MessagingGroupRole(rawValue: rawRole),
                          roles[userID] == nil
                    else { throw SecureMessagingExchangeError.invalidConversation }
                    roles[userID] = role
                }
                memberRoles = roles
            }
            if let rawViewerRole = dto.role {
                guard let viewerRole = MessagingGroupRole(rawValue: rawViewerRole),
                      memberRoles?[currentUserID] == viewerRole
                else { throw SecureMessagingExchangeError.invalidConversation }
            }
            // Group identity is optional but never malformed: a description is canonicalized
            // the way the server stores it, and a photo address must be structurally sane.
            let description = dto.description
                .map(MessagingGroupDescriptionPolicy.normalized)
                .flatMap { $0.isEmpty ? nil : $0 }
            if let description {
                guard MessagingGroupDescriptionPolicy.isValid(description) else {
                    throw SecureMessagingExchangeError.invalidConversation
                }
            }
            let photoURL = dto.photoUrl
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .flatMap { $0.isEmpty ? nil : $0 }
            if let photoURL {
                guard MessagingGroupPhotoURLPolicy.isValid(photoURL) else {
                    throw SecureMessagingExchangeError.invalidConversation
                }
            }
            return ValidatedDirectConversation(
                id: id,
                recipientUserID: nil,
                memberUserIDs: memberIDs,
                title: title,
                updatedAt: updatedAt,
                conversationType: type,
                groupMemberRoles: memberRoles,
                groupDescription: description,
                groupPhotoURL: photoURL,
                memberIdentities: memberIdentities.isEmpty ? nil : memberIdentities
            )

        default:
            throw SecureMessagingExchangeError.invalidConversation
        }
    }

    private static func canonicalUUID(
        _ rawValue: String?,
        error: SecureMessagingExchangeError
    ) throws -> String {
        guard let rawValue,
              let uuid = UUID(uuidString: rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw error }
        let value = uuid.uuidString.lowercased()
        guard SecureMessagingValidation.isCanonicalUUID(value) else { throw error }
        return value
    }

    private static func parseServerDate(_ rawValue: String?) throws -> Date {
        guard let rawValue, let value = Self.serverDate(rawValue) else {
            throw SecureMessagingExchangeError.invalidServerResponse
        }
        return value
    }

    private static func serverDate(_ rawValue: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: rawValue) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: rawValue)
    }
}

enum SecureMessagingOutboundValidation {
    static func validate(
        _ dto: EncryptedMessageDTO,
        fanout: SecureMessagingCommittedFanout,
        expectedPlaintext: String,
        expectedAttachments: [EncryptedAttachmentRequest],
        userID: String,
        enrollment: SecureMessagingEnrollmentBinding?
    ) throws -> OutboundEcho {
        guard let expectedKind = SecureMessagingContentBindingPolicy.kind(
                  for: expectedPlaintext,
                  replyToMessageID: fanout.replyToMessageID,
                  attachments: expectedAttachments
              ),
              let enrollment,
              let id = dto.id,
              SecureMessagingValidation.isCanonicalUUID(id),
              dto.clientMessageId == fanout.clientMessageID,
              dto.conversationId == fanout.conversationID,
              dto.rosterRevision == fanout.rosterRevision,
              dto.sender?.id == userID,
              dto.senderDeviceId == enrollment.serverDeviceID,
              dto.senderEnrollmentEpoch == enrollment.enrollmentEpoch,
              dto.senderSignalDeviceId == Int(enrollment.signalDeviceID),
              dto.senderRegistrationId == Int(enrollment.registrationID),
              dto.senderProtocolVersion == SecureMessagingWire.protocolVersion,
              dto.senderBundleVersion == enrollment.bundleVersion,
              dto.senderIdentityKeySha256 == enrollment.identityKeySHA256,
              dto.kind == expectedKind.rawValue,
              dto.replyToMessageId == fanout.replyToMessageID,
              dto.envelope == nil,
              let rawAttachments = dto.attachments,
              rawAttachments.allSatisfy({ $0 != nil }),
              KitMediaMessageFamilyPolicy.validatesWireRows(
                  rawAttachments,
                  forBody: expectedPlaintext
              ),
              dto.reactions?.isEmpty == true,
              dto.revokedAt == nil
        else { throw SecureMessagingExchangeError.invalidServerResponse }
        return OutboundEcho(
            clientMessageID: fanout.clientMessageID,
            serverMessageID: id,
            sentAt: try parseServerDate(dto.sentAt),
            historyMetadata: SecureMessagingRetainedMessageMetadata(
                clientMessageID: fanout.clientMessageID,
                senderUserID: userID,
                senderDeviceID: enrollment.serverDeviceID,
                senderEnrollmentEpoch: enrollment.enrollmentEpoch,
                senderSignalDeviceID: enrollment.signalDeviceID,
                rosterRevision: fanout.rosterRevision,
                kind: expectedKind,
                replyToMessageID: fanout.replyToMessageID
            )
        )
    }

    private static func parseServerDate(_ rawValue: String?) throws -> Date {
        guard let rawValue, let value = Self.serverDate(rawValue) else {
            throw SecureMessagingExchangeError.invalidServerResponse
        }
        return value
    }

    private static func serverDate(_ rawValue: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: rawValue) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: rawValue)
    }
}

struct ValidatedMessagingAttachmentUpload: Equatable, Sendable {
    let storageKey: String
    let byteSize: Int64
    let ciphertextSHA256: String
}

enum SecureMessagingAttachmentUploadResponsePolicy {
    /// Both upload request shapes send a permanent client media id. Its response echo is
    /// mandatory: accepting an omitted legacy echo would make timeout reconciliation unable to
    /// prove that the returned object belongs to the queued local media record.
    static func validate(
        _ upload: MessagingAttachmentUploadDTO,
        attachmentID: String,
        ciphertextByteSize: Int64,
        ciphertextSHA256: String
    ) -> ValidatedMessagingAttachmentUpload? {
        guard SecureMessagingWirePolicy.isCanonicalUUID(attachmentID),
              let echoedClientMediaID = upload.clientMediaId,
              echoedClientMediaID == attachmentID,
              SecureMessagingWirePolicy.isCanonicalUUID(echoedClientMediaID),
              let storageKey = upload.storageKey?.lowercased(),
              SecureMessagingWirePolicy.isCanonicalUUID(storageKey),
              let byteSize = upload.byteSize,
              byteSize == ciphertextByteSize,
              let digest = upload.ciphertextSha256?.lowercased(),
              digest == ciphertextSHA256
        else { return nil }
        return ValidatedMessagingAttachmentUpload(
            storageKey: storageKey,
            byteSize: byteSize,
            ciphertextSHA256: digest
        )
    }
}
