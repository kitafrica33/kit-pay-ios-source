import CryptoKit
import Foundation

/// One explicit tap on Send. Media keys, exact Signal bytes and recovery metadata are encrypted
/// in MessagingProcessBroker; none of these records is a plaintext URL handoff or composer draft.
struct DirectShareSendRecord: Codable {
    static let maximumPendingSends = 16
    static let maximumCompletionReceipts = 128
    let id: UUID
    let generation: UUID
    let accountID: String
    let sessionID: String
    let destination: SharedInboxDestination
    let createdAt: Date
    let text: String?
    var media: [Media]
    var conversation: ValidatedDirectConversation?
    var body: String?
    var fanout: SecureMessagingCommittedFanout?
    var wireRequest: Data?
    var enrollment: SecureMessagingEnrollmentBinding?
    var serverMessageID: String?
    var sentAt: Date?
    var historyMetadata: SecureMessagingRetainedMessageMetadata?
    var localMediaImported: Bool?

    struct Media: Codable {
        let item: SharedInboxItem
        let keyMaterial: Data
        var ciphertextBytes: Int64?
        var ciphertextSHA256: String?
        var storageKey: String?
    }

    var isComplete: Bool { serverMessageID != nil && sentAt != nil }
    var readyForPrivateImport: Bool { isComplete && (media.isEmpty || localMediaImported == true) }

    /// Retains only enough encrypted status to reconcile an open sheet after the main app
    /// imports its send and removes the staging. The immutable input hash also prevents an
    /// uncertain enqueue retry from reusing this ID for different content.
    struct CompletionReceipt: Codable, Equatable {
        let id: UUID
        let generation: UUID
        let accountID: String
        let sessionID: String
        let inputSHA256: Data

        init(_ send: DirectShareSendRecord) throws {
            guard send.readyForPrivateImport else { throw MessagingProcessBroker.Failure.corrupt }
            id = send.id
            generation = send.generation
            accountID = send.accountID
            sessionID = send.sessionID
            inputSHA256 = try send.inputFingerprint()
        }

        func matches(_ scope: MessagingProcessBroker.Scope) -> Bool {
            generation == scope.generation && accountID == scope.accountID && sessionID == scope.sessionID
        }
    }

    static func inputFingerprint(
        destination: SharedInboxDestination, items: [SharedInboxItem], text: String?
    ) throws -> Data {
        struct Input: Encodable {
            let version = 1
            let destination: SharedInboxDestination
            let items: [SharedInboxItem]
            let text: String?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(Input(destination: destination, items: items, text: text))))
    }

    func inputFingerprint() throws -> Data {
        try Self.inputFingerprint(destination: destination, items: media.map(\.item), text: text)
    }

    static var stagingStore: SharedInboxStore {
        SharedInboxStore(containerURL: KitAppGroup.containerURL?.appendingPathComponent(
            "DirectShare", isDirectory: true
        ))
    }

    #if !KIT_SHARE_EXTENSION
    static func project(_ records: [Self], into state: inout PersistedState) {
        guard let owner = state.profile?.id.lowercased() ?? state.communicationOwnerUserID?.lowercased() else { return }
        for record in records where record.accountID == owner {
            guard let conversation = record.conversation?.localProjection else { continue }
            if let index = state.conversations.firstIndex(where: { $0.id == conversation.id }) {
                state.conversations[index].updatedAt = max(
                    state.conversations[index].updatedAt, record.createdAt
                )
            } else {
                state.conversations.append(conversation)
            }
            if let index = state.messages.firstIndex(where: { $0.id == record.id }) {
                guard state.messages[index].senderId.lowercased() == owner,
                      state.messages[index].conversationId == conversation.id
                else { continue }
                if let body = record.body { state.messages[index].body = body }
                if record.isComplete {
                    state.messages[index].serverMessageId = record.serverMessageID
                    state.messages[index].sentAt = record.sentAt
                    state.messages[index].secureMessagingHistory = record.historyMetadata
                    if ![.delivered, .read].contains(state.messages[index].state) {
                        state.messages[index].state = .sent
                    }
                    state.messages[index].failureReason = nil
                }
            } else {
                state.messages.append(LocalMessage(
                    id: record.id, serverMessageId: record.serverMessageID,
                    conversationId: conversation.id, senderId: owner,
                    body: record.body ?? record.text ?? "Preparing attachment…",
                    createdAt: record.createdAt, sentAt: record.sentAt,
                    state: record.isComplete ? .sent : .encrypting,
                    failureReason: nil, isOutgoing: true,
                    secureMessagingHistory: record.historyMetadata
                ))
            }
            if record.localMediaImported == true,
               let index = state.messages.firstIndex(where: { $0.id == record.id }) {
                let mediaRecords = record.media.compactMap { media -> LocalMediaRecord? in
                    guard var value = LocalMediaRecordPolicy.queuedOutgoing(
                        id: media.item.id.uuidString.lowercased(), messageID: record.id,
                        conversationID: conversation.id, mediaType: media.item.mediaType,
                        fileSize: media.item.byteCount,
                        localStorageKey: media.item.id.uuidString.lowercased(), storesInline: false,
                        now: record.createdAt, outboundKeyMaterial: media.keyMaterial,
                        localStorageKind: .protectedFile
                    ) else { return nil }
                    value.remoteEncryptedObjectID = media.storageKey
                    value.uploadState = .uploaded
                    value.encryptionState = .encrypted
                    return value.isStructurallyValid ? value : nil
                }
                if mediaRecords.count == record.media.count {
                    state.messages[index].localMediaRecords = mediaRecords
                }
            }
        }
    }
    #endif
}
