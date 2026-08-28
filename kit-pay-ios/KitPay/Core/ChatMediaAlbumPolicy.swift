import Foundation

/// One display item inside a conversation timeline media album.
///
/// Carries identity and display facts only, never descriptor text: a descriptor holds
/// attachment key material, so cells re-resolve the persisted row by identity instead.
struct ChatMediaAlbumItem: Equatable, Identifiable {
    let messageID: UUID
    let conversationID: String
    /// Opaque thumbnail-store key (the attachment's storage key); carries no key material.
    /// Changes whenever the row's sealed descriptor changes, so cells keyed on it re-resolve.
    let thumbnailKey: String
    let mediaType: String
    let plaintextByteSize: Int
    let isOutgoing: Bool
    let createdAt: Date

    var id: UUID { messageID }
}

/// A run of 2...N consecutive visual-media messages rendered as one grid bubble.
struct ChatMediaAlbum: Equatable, Identifiable {
    /// 2...`ChatMediaAlbumPolicy.maximumAlbumItems`, chronological.
    let items: [ChatMediaAlbumItem]

    var id: UUID { items[0].messageID }
}

/// Per-message album membership, so a renderer iterating messages in order can render the
/// album grid at the FIRST member and skip the rest.
enum ChatMediaAlbumMembership: Equatable {
    /// Render the grid here.
    case leader(ChatMediaAlbum)
    /// Skip this message's own bubble.
    case follower
}

/// Groups CONSECUTIVE visual-media messages (image or video kinds only) from the same
/// sender/direction into albums when each gap is <= `maximumGapSeconds` and none of the grouped
/// messages has a caption (a caption forces its own bubble) and none is still pending upload
/// (`pendingAttachment != nil` stays standalone). Non-media or voice/document messages break a
/// run, as does a failed message (its retry UI must stay visible). Runs longer than
/// `maximumAlbumItems` split into consecutive albums; a leftover single is never an album.
///
/// Deterministic and O(n) over the message list.
enum ChatMediaAlbumPolicy {
    static let maximumGapSeconds: TimeInterval = 90
    static let maximumAlbumItems = 12

    static func albums(for messages: [LocalMessage]) -> [ChatMediaAlbum] {
        var albums: [ChatMediaAlbum] = []
        var run: [ChatMediaAlbumItem] = []
        var runSenderID: String?
        var runIsOutgoing = false
        var runLastCreatedAt = Date.distantPast

        func flushRun() {
            if run.count >= 2 {
                albums.append(ChatMediaAlbum(items: run))
            }
            run.removeAll(keepingCapacity: true)
            runSenderID = nil
        }

        for message in messages {
            guard let item = albumEligibleItem(for: message) else {
                flushRun()
                continue
            }
            let continuesRun = runSenderID == message.senderId
                && runIsOutgoing == item.isOutgoing
                && abs(item.createdAt.timeIntervalSince(runLastCreatedAt)) <= maximumGapSeconds
                && run.count < maximumAlbumItems
            if continuesRun {
                run.append(item)
            } else {
                flushRun()
                run = [item]
                runSenderID = message.senderId
                runIsOutgoing = item.isOutgoing
            }
            runLastCreatedAt = item.createdAt
        }
        flushRun()
        return albums
    }

    /// Message-ID -> membership. Messages that are not part of any album are absent.
    static func membership(for messages: [LocalMessage]) -> [UUID: ChatMediaAlbumMembership] {
        var membership: [UUID: ChatMediaAlbumMembership] = [:]
        for album in albums(for: messages) {
            for (index, item) in album.items.enumerated() {
                membership[item.messageID] = index == 0 ? .leader(album) : .follower
            }
        }
        return membership
    }

    /// A message may join an album only when it is a fully uploaded, captionless image or video
    /// with an authenticated canonical descriptor and no failure/retry affordance of its own.
    private static func albumEligibleItem(for message: LocalMessage) -> ChatMediaAlbumItem? {
        guard message.pendingAttachment == nil,
              message.state != .failed,
              let descriptor = KitMediaMessageDescriptor.parse(message.body),
              descriptor.caption == nil
        else { return nil }
        let kind = KitChatMediaKind(mediaType: descriptor.mediaType)
        guard kind == .image || kind == .video else { return nil }
        return ChatMediaAlbumItem(
            messageID: message.id,
            conversationID: message.conversationId,
            thumbnailKey: descriptor.storageKey,
            mediaType: descriptor.mediaType,
            plaintextByteSize: descriptor.plaintextByteSize,
            isOutgoing: message.isOutgoing,
            createdAt: message.createdAt
        )
    }
}
