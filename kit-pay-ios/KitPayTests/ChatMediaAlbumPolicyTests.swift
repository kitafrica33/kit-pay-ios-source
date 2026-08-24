import XCTest
@testable import KitPay

final class ChatMediaAlbumPolicyTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_770_000_000)
    private let outgoingSenderID = "0a1b2c3d-0000-4000-8000-0000000000aa"
    private let incomingSenderID = "0a1b2c3d-0000-4000-8000-0000000000bb"
    private let conversationID = "0a1b2c3d-0000-4000-8000-0000000000cc"

    // MARK: Fixtures

    private func makeDescriptorBody(
        mediaType: String,
        caption: String? = nil,
        plaintextByteSize: Int = 4_000
    ) throws -> String {
        try KitMediaMessageDescriptor(
            attachmentID: UUID().uuidString.lowercased(),
            storageKey: UUID().uuidString.lowercased(),
            mediaType: mediaType,
            ciphertextByteSize: Int64(plaintextByteSize) + 64,
            ciphertextSHA256: String(repeating: "ab", count: 32),
            keyMaterial: Data(repeating: 7, count: SecureMediaAttachmentCipher.keyMaterialBytes),
            plaintextByteSize: plaintextByteSize,
            caption: caption
        ).encoded
    }

    private func makeMediaMessage(
        mediaType: String = "image/jpeg",
        caption: String? = nil,
        secondsAfterBase: TimeInterval,
        isOutgoing: Bool = true,
        senderId: String? = nil,
        state: MessageDeliveryState = .sent,
        pendingAttachment: LocalPendingAttachment? = nil
    ) throws -> LocalMessage {
        LocalMessage(
            id: UUID(),
            serverMessageId: nil,
            conversationId: conversationID,
            senderId: senderId ?? (isOutgoing ? outgoingSenderID : incomingSenderID),
            body: try makeDescriptorBody(mediaType: mediaType, caption: caption),
            createdAt: baseDate.addingTimeInterval(secondsAfterBase),
            sentAt: nil,
            state: state,
            failureReason: nil,
            isOutgoing: isOutgoing,
            attachmentData: nil,
            pendingAttachment: pendingAttachment
        )
    }

    private func makeTextMessage(secondsAfterBase: TimeInterval) -> LocalMessage {
        LocalMessage(
            id: UUID(),
            serverMessageId: nil,
            conversationId: conversationID,
            senderId: outgoingSenderID,
            body: "hello",
            createdAt: baseDate.addingTimeInterval(secondsAfterBase),
            sentAt: nil,
            state: .sent,
            failureReason: nil,
            isOutgoing: true
        )
    }

    // MARK: Grouping

    func testThreeConsecutiveCaptionlessOutgoingImagesFormOneAlbum() throws {
        let messages = [
            try makeMediaMessage(secondsAfterBase: 0),
            try makeMediaMessage(secondsAfterBase: 10),
            try makeMediaMessage(secondsAfterBase: 20),
        ]

        let albums = ChatMediaAlbumPolicy.albums(for: messages)
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums[0].items.map(\.messageID), messages.map(\.id))
        XCTAssertEqual(albums[0].id, messages[0].id)

        let membership = ChatMediaAlbumPolicy.membership(for: messages)
        XCTAssertEqual(membership[messages[0].id], .leader(albums[0]))
        XCTAssertEqual(membership[messages[1].id], .follower)
        XCTAssertEqual(membership[messages[2].id], .follower)
    }

    func testImagesAndVideosMixIntoOneAlbum() throws {
        let messages = [
            try makeMediaMessage(mediaType: "image/jpeg", secondsAfterBase: 0),
            try makeMediaMessage(mediaType: "video/mp4", secondsAfterBase: 15),
        ]

        let albums = ChatMediaAlbumPolicy.albums(for: messages)
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums[0].items.count, 2)
        XCTAssertEqual(albums[0].items[1].mediaType, "video/mp4")
    }

    func testCaptionForcesItsOwnBubble() throws {
        let messages = [
            try makeMediaMessage(secondsAfterBase: 0),
            try makeMediaMessage(secondsAfterBase: 10),
            try makeMediaMessage(caption: "Sunset", secondsAfterBase: 20),
            try makeMediaMessage(secondsAfterBase: 30),
            try makeMediaMessage(secondsAfterBase: 40),
        ]

        let albums = ChatMediaAlbumPolicy.albums(for: messages)
        XCTAssertEqual(albums.count, 2)
        XCTAssertEqual(albums[0].items.map(\.messageID), [messages[0].id, messages[1].id])
        XCTAssertEqual(albums[1].items.map(\.messageID), [messages[3].id, messages[4].id])

        let membership = ChatMediaAlbumPolicy.membership(for: messages)
        XCTAssertNil(membership[messages[2].id])
    }

    func testGapOverNinetySecondsBreaksGrouping() throws {
        let split = [
            try makeMediaMessage(secondsAfterBase: 0),
            try makeMediaMessage(secondsAfterBase: 91),
        ]
        XCTAssertTrue(ChatMediaAlbumPolicy.albums(for: split).isEmpty)
        XCTAssertTrue(ChatMediaAlbumPolicy.membership(for: split).isEmpty)

        // The 90-second boundary itself is inclusive.
        let grouped = [
            try makeMediaMessage(secondsAfterBase: 0),
            try makeMediaMessage(secondsAfterBase: 90),
        ]
        XCTAssertEqual(ChatMediaAlbumPolicy.albums(for: grouped).count, 1)
    }

    func testDirectionChangeBreaksGrouping() throws {
        let messages = [
            try makeMediaMessage(secondsAfterBase: 0, isOutgoing: true),
            try makeMediaMessage(secondsAfterBase: 5, isOutgoing: false),
            try makeMediaMessage(secondsAfterBase: 10, isOutgoing: true),
        ]
        XCTAssertTrue(ChatMediaAlbumPolicy.albums(for: messages).isEmpty)
    }

    func testDifferentSendersInTheSameDirectionDoNotGroup() throws {
        let messages = [
            try makeMediaMessage(secondsAfterBase: 0, isOutgoing: false, senderId: incomingSenderID),
            try makeMediaMessage(
                secondsAfterBase: 5,
                isOutgoing: false,
                senderId: "0a1b2c3d-0000-4000-8000-0000000000dd"
            ),
        ]
        XCTAssertTrue(ChatMediaAlbumPolicy.albums(for: messages).isEmpty)
    }

    func testVoiceAndDocumentMessagesBreakARun() throws {
        let messages = [
            try makeMediaMessage(secondsAfterBase: 0),
            try makeMediaMessage(secondsAfterBase: 5),
            try makeMediaMessage(mediaType: "audio/mp4", secondsAfterBase: 10),
            try makeMediaMessage(secondsAfterBase: 15),
            try makeMediaMessage(mediaType: "application/pdf", secondsAfterBase: 20),
            try makeMediaMessage(secondsAfterBase: 25),
            try makeMediaMessage(secondsAfterBase: 30),
        ]

        let albums = ChatMediaAlbumPolicy.albums(for: messages)
        XCTAssertEqual(albums.count, 2)
        XCTAssertEqual(albums[0].items.map(\.messageID), [messages[0].id, messages[1].id])
        XCTAssertEqual(albums[1].items.map(\.messageID), [messages[5].id, messages[6].id])

        let membership = ChatMediaAlbumPolicy.membership(for: messages)
        XCTAssertNil(membership[messages[2].id], "voice note must not join or lead an album")
        XCTAssertNil(membership[messages[3].id], "single image between breakers is not an album")
        XCTAssertNil(membership[messages[4].id], "document must not join or lead an album")
    }

    func testFailedMessageStaysStandaloneSoRetryUIRemains() throws {
        let messages = [
            try makeMediaMessage(secondsAfterBase: 0),
            try makeMediaMessage(secondsAfterBase: 5, state: .failed),
            try makeMediaMessage(secondsAfterBase: 10),
        ]

        XCTAssertTrue(ChatMediaAlbumPolicy.albums(for: messages).isEmpty)
        XCTAssertTrue(ChatMediaAlbumPolicy.membership(for: messages).isEmpty)
    }

    func testPendingUploadStaysStandalone() throws {
        let messages = [
            try makeMediaMessage(secondsAfterBase: 0),
            try makeMediaMessage(
                secondsAfterBase: 5,
                pendingAttachment: LocalPendingAttachment(mediaType: "image/jpeg", caption: nil)
            ),
            try makeMediaMessage(secondsAfterBase: 10),
        ]

        XCTAssertTrue(ChatMediaAlbumPolicy.albums(for: messages).isEmpty)
        XCTAssertTrue(ChatMediaAlbumPolicy.membership(for: messages).isEmpty)
    }

    func testRunOfThirteenSplitsIntoTwelveItemAlbumPlusStandaloneSingle() throws {
        let messages = try (0 ..< 13).map { index in
            try makeMediaMessage(secondsAfterBase: TimeInterval(index) * 5)
        }

        let albums = ChatMediaAlbumPolicy.albums(for: messages)
        XCTAssertEqual(albums.count, 1, "a leftover single is never an album")
        XCTAssertEqual(albums[0].items.count, ChatMediaAlbumPolicy.maximumAlbumItems)
        XCTAssertEqual(
            albums[0].items.map(\.messageID),
            messages.prefix(12).map(\.id)
        )

        let membership = ChatMediaAlbumPolicy.membership(for: messages)
        XCTAssertEqual(membership.count, 12)
        XCTAssertNil(membership[messages[12].id])
    }

    func testRunOfFourteenSplitsIntoTwelvePlusAlbumOfTwo() throws {
        let messages = try (0 ..< 14).map { index in
            try makeMediaMessage(secondsAfterBase: TimeInterval(index) * 5)
        }

        let albums = ChatMediaAlbumPolicy.albums(for: messages)
        XCTAssertEqual(albums.count, 2)
        XCTAssertEqual(albums[0].items.count, 12)
        XCTAssertEqual(albums[1].items.map(\.messageID), [messages[12].id, messages[13].id])
    }

    func testMembershipMapMarksExactlyOneLeaderPerAlbum() throws {
        let messages = [
            try makeMediaMessage(secondsAfterBase: 0),
            try makeMediaMessage(secondsAfterBase: 5),
            try makeMediaMessage(secondsAfterBase: 10),
            makeTextMessage(secondsAfterBase: 15),
            try makeMediaMessage(secondsAfterBase: 20),
            try makeMediaMessage(secondsAfterBase: 25),
        ]

        let albums = ChatMediaAlbumPolicy.albums(for: messages)
        let membership = ChatMediaAlbumPolicy.membership(for: messages)

        XCTAssertEqual(membership.count, albums.reduce(0) { $0 + $1.items.count })
        for album in albums {
            XCTAssertEqual(membership[album.items[0].messageID], .leader(album))
            XCTAssertEqual(album.id, album.items[0].messageID)
            for follower in album.items.dropFirst() {
                XCTAssertEqual(membership[follower.messageID], .follower)
            }
        }
    }

    func testNonMediaMessagesAreAbsentFromMembership() throws {
        let text = makeTextMessage(secondsAfterBase: 5)
        let messages = [
            try makeMediaMessage(secondsAfterBase: 0),
            text,
            try makeMediaMessage(secondsAfterBase: 10),
        ]

        let membership = ChatMediaAlbumPolicy.membership(for: messages)
        XCTAssertNil(membership[text.id])
        XCTAssertTrue(membership.isEmpty, "text breaks the run, leaving two standalone photos")

        XCTAssertTrue(
            ChatMediaAlbumPolicy.membership(
                for: [makeTextMessage(secondsAfterBase: 0), makeTextMessage(secondsAfterBase: 1)]
            ).isEmpty
        )
    }

    func testAlbumItemsCarryTheParseableDescriptorText() throws {
        let messages = [
            try makeMediaMessage(secondsAfterBase: 0),
            try makeMediaMessage(mediaType: "video/quicktime", secondsAfterBase: 5),
        ]

        let albums = ChatMediaAlbumPolicy.albums(for: messages)
        XCTAssertEqual(albums.count, 1)
        for (item, message) in zip(albums[0].items, messages) {
            XCTAssertEqual(item.descriptorText, message.body)
            XCTAssertEqual(item.isOutgoing, message.isOutgoing)
            XCTAssertEqual(item.createdAt, message.createdAt)
            let parsed = KitMediaMessageDescriptor.parse(item.descriptorText)
            XCTAssertNotNil(parsed)
            XCTAssertEqual(parsed?.mediaType, item.mediaType)
            XCTAssertNil(parsed?.caption)
        }
    }
}
