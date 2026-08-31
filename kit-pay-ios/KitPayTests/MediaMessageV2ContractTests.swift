import XCTest

#if canImport(UIKit)
    @testable import KitPay
#endif

/// KITMEDIA2 contract v0.4 (449925d9…) §9: canonical vectors V1/V2, every malformed class, the
/// six-codepoint helpers, family classification, outer set-match, canonical wire order, caption
/// budget, and capability-block coherence.
///
/// This file also runs on Linux against the same production source (see
/// `.github/scripts/tests/run_media_v2_linux_gate.sh`), which is why it declares `allTests` and
/// imports the app module only conditionally. Keep it free of UIKit and of symbols outside
/// `MediaMessageV2Models.swift`.
final class MediaMessageV2ContractTests: XCTestCase {
    // MARK: - Contract vectors (§9), byte-for-byte

    private static let key0Raw = String(repeating: "A", count: 86) + "=="
    private static let key0Encoded = String(repeating: "A", count: 86) + "%3D%3D"
    private static let key1Raw = String(repeating: "/", count: 85) + "w=="
    private static let key1Encoded = String(repeating: "%2F", count: 85) + "w%3D%3D"

    private enum V1 {
        static let id0 = "11111111-1111-4111-8111-111111111111"
        static let sk0 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        static let sha0 = String(repeating: "1", count: 64)
        static let id1 = "22222222-2222-4222-8222-222222222222"
        static let sk1 = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        static let sha1 = String(repeating: "2", count: 64)
    }

    private enum V2 {
        static let id0 = "33333333-3333-4333-8333-333333333333"
        static let sk0 = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        static let sha0 = String(repeating: "3", count: 64)
        static let id1 = "44444444-4444-4444-8444-444444444444"
        static let sk1 = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        static let sha1 = String(repeating: "4", count: 64)
        static let id2 = "55555555-5555-4555-8555-555555555555"
        static let sk2 = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        static let sha2 = String(repeating: "5", count: 64)
    }

    private static func group(
        _ index: Int, id: String, sk: String, mt: String, bs: String,
        sha: String, key: String, ps: String
    ) -> String {
        "&id\(index)=\(id)&sk\(index)=\(sk)&mt\(index)=\(mt)&bs\(index)=\(bs)"
            + "&sha\(index)=\(sha)&key\(index)=\(key)&ps\(index)=\(ps)"
    }

    private static let vector1Group0 = group(
        0, id: V1.id0, sk: V1.sk0, mt: "image%2Fjpeg", bs: "1088",
        sha: V1.sha0, key: key0Encoded, ps: "1024"
    )
    private static let vector1Group1 = group(
        1, id: V1.id1, sk: V1.sk1, mt: "video%2Fmp4", bs: "5242944",
        sha: V1.sha1, key: key1Encoded, ps: "5242880"
    )
    /// §9 V1 — two items + caption, exactly the contract string.
    private static let vector1 =
        "KITMEDIA2:v=2&n=2" + vector1Group0 + vector1Group1 + "&cap=Family%20photos"

    /// §9 V2 — three items, no `cap` key at all.
    private static let vector2 = "KITMEDIA2:v=2&n=3"
        + group(0, id: V2.id0, sk: V2.sk0, mt: "application%2Fpdf", bs: "64",
                sha: V2.sha0, key: key0Encoded, ps: "5")
        + group(1, id: V2.id1, sk: V2.sk1, mt: "audio%2Fogg", bs: "80",
                sha: V2.sha1, key: key1Encoded, ps: "16")
        + group(2, id: V2.id2, sk: V2.sk2, mt: "image%2Fpng", bs: "1048640",
                sha: V2.sha2, key: key0Encoded, ps: "1048576")

    private func assertRejected(_ text: String, _ note: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(KitMediaMessageV2Descriptor.parse(text), note, file: file, line: line)
    }

    // MARK: - Canonical vectors

    func testVectorV1CanonicalRoundTrip() {
        guard let descriptor = KitMediaMessageV2Descriptor.parse(Self.vector1) else {
            return XCTFail("V1 vector must parse")
        }
        XCTAssertEqual(descriptor.items.count, 2)
        XCTAssertEqual(descriptor.items[0].attachmentID, V1.id0)
        XCTAssertEqual(descriptor.items[0].storageKey, V1.sk0)
        XCTAssertEqual(descriptor.items[0].mediaType, "image/jpeg")
        XCTAssertEqual(descriptor.items[0].ciphertextByteSize, 1_088)
        XCTAssertEqual(descriptor.items[0].ciphertextSHA256, V1.sha0)
        XCTAssertEqual(descriptor.items[0].plaintextByteSize, 1_024)
        XCTAssertEqual(descriptor.items[0].keyMaterial, Data(repeating: 0x00, count: 64))
        XCTAssertEqual(descriptor.items[1].attachmentID, V1.id1)
        XCTAssertEqual(descriptor.items[1].mediaType, "video/mp4")
        XCTAssertEqual(descriptor.items[1].ciphertextByteSize, 5_242_944)
        XCTAssertEqual(descriptor.items[1].plaintextByteSize, 5_242_880)
        XCTAssertEqual(descriptor.items[1].keyMaterial, Data(repeating: 0xFF, count: 64))
        XCTAssertEqual(descriptor.caption, "Family photos")
        XCTAssertEqual(Array(descriptor.encoded.utf8), Array(Self.vector1.utf8))
    }

    func testVectorV1BuildsFromComponents() {
        XCTAssertEqual(Data(repeating: 0x00, count: 64).base64EncodedString(), Self.key0Raw)
        XCTAssertEqual(Data(repeating: 0xFF, count: 64).base64EncodedString(), Self.key1Raw)
        let items = [
            KitMediaMessageV2Descriptor.Item(
                attachmentID: V1.id0, storageKey: V1.sk0, mediaType: "image/jpeg",
                ciphertextByteSize: 1_088, ciphertextSHA256: V1.sha0,
                keyMaterial: Data(repeating: 0x00, count: 64), plaintextByteSize: 1_024
            ),
            KitMediaMessageV2Descriptor.Item(
                attachmentID: V1.id1, storageKey: V1.sk1, mediaType: "video/mp4",
                ciphertextByteSize: 5_242_944, ciphertextSHA256: V1.sha1,
                keyMaterial: Data(repeating: 0xFF, count: 64), plaintextByteSize: 5_242_880
            ),
        ]
        let descriptor = KitMediaMessageV2Descriptor(items: items, caption: "Family photos")
        XCTAssertEqual(descriptor.map { Array($0.encoded.utf8) }, Array(Self.vector1.utf8))
    }

    func testVectorV2CanonicalRoundTrip() {
        guard let descriptor = KitMediaMessageV2Descriptor.parse(Self.vector2) else {
            return XCTFail("V2 vector must parse")
        }
        XCTAssertEqual(descriptor.items.count, 3)
        XCTAssertNil(descriptor.caption)
        XCTAssertEqual(descriptor.items[0].mediaType, "application/pdf")
        XCTAssertEqual(descriptor.items[0].ciphertextByteSize, 64)
        XCTAssertEqual(descriptor.items[0].plaintextByteSize, 5)
        XCTAssertEqual(descriptor.items[1].mediaType, "audio/ogg")
        XCTAssertEqual(descriptor.items[1].ciphertextByteSize, 80)
        XCTAssertEqual(descriptor.items[2].mediaType, "image/png")
        XCTAssertEqual(descriptor.items[2].plaintextByteSize, 1_048_576)
        XCTAssertEqual(Array(descriptor.encoded.utf8), Array(Self.vector2.utf8))
        XCTAssertEqual(
            KitMediaMessageV2Descriptor(items: descriptor.items, caption: nil)?.encoded,
            Self.vector2
        )
    }

    // MARK: - Malformed classes (§9)

    func testMalformedAttachmentCounts() {
        assertRejected("KITMEDIA2:v=2&n=1" + Self.vector1Group0,
                       "class 1: n=1 must stay KITMEDIA1")
        assertRejected("KITMEDIA2:v=2&n=0", "class 1: n=0")
        var nine = "KITMEDIA2:v=2&n=9"
        for index in 0 ..< 9 {
            nine += Self.group(
                index,
                id: "0000000\(index)-0000-4000-8000-000000000000",
                sk: "0000000\(index)-1111-4000-8000-000000000000",
                mt: "image%2Fpng", bs: "80", sha: String(repeating: "6", count: 64),
                key: Self.key0Encoded, ps: "16"
            )
        }
        assertRejected(nine, "class 2: n=9")
        assertRejected("KITMEDIA2:v=2&n=2" + Self.vector1Group0,
                       "class 3: n=2 with one group")
        let extra = Self.group(
            2, id: V2.id2, sk: V2.sk2, mt: "image%2Fpng", bs: "80",
            sha: V2.sha2, key: Self.key0Encoded, ps: "16"
        )
        assertRejected(
            "KITMEDIA2:v=2&n=2" + Self.vector1Group0 + Self.vector1Group1 + extra
                + "&cap=Family%20photos",
            "class 3: n=2 with three groups"
        )
    }

    func testMalformedOversizedDescriptor() {
        let oversized = Self.vector1.replacingOccurrences(
            of: "&cap=Family%20photos",
            with: "&cap=" + String(repeating: "a", count: 7_000)
        )
        XCTAssertGreaterThan(oversized.utf8.count, 7_680)
        assertRejected(oversized, "class 2: total UTF-8 length above 7680")
    }

    func testMalformedDuplicateIdentity() {
        assertRejected(
            Self.vector1.replacingOccurrences(of: V1.id1, with: V1.id0),
            "class 4: duplicate attachment id"
        )
        assertRejected(
            Self.vector1.replacingOccurrences(of: V1.sk1, with: V1.sk0),
            "class 4: duplicate storage key"
        )
    }

    func testMalformedFieldGrammar() {
        assertRejected(Self.vector1 + "&cap=b", "class 5: duplicate cap")
        assertRejected(Self.vector1 + "&zz=1", "class 5: unknown key")
        assertRejected(
            "KITMEDIA2:v=2&n=2" + Self.vector1Group0 + "&cap=Family%20photos"
                + Self.vector1Group1,
            "class 5: cap not last"
        )
        assertRejected(
            "KITMEDIA2:v=2&n=2&sk0=\(V1.sk0)&id0=\(V1.id0)&mt0=image%2Fjpeg&bs0=1088"
                + "&sha0=\(V1.sha0)&key0=\(Self.key0Encoded)&ps0=1024" + Self.vector1Group1
                + "&cap=Family%20photos",
            "class 5: sk0 before id0"
        )
        let gapGroup1 = Self.vector1Group1
            .replacingOccurrences(of: "id1=", with: "id2=")
            .replacingOccurrences(of: "sk1=", with: "sk2=")
            .replacingOccurrences(of: "mt1=", with: "mt2=")
            .replacingOccurrences(of: "bs1=", with: "bs2=")
            .replacingOccurrences(of: "sha1=", with: "sha2=")
            .replacingOccurrences(of: "key1=", with: "key2=")
            .replacingOccurrences(of: "ps1=", with: "ps2=")
        assertRejected(
            "KITMEDIA2:v=2&n=2" + Self.vector1Group0 + gapGroup1 + "&cap=Family%20photos",
            "class 5: index gap id0,id2"
        )
        assertRejected(
            Self.vector1.replacingOccurrences(of: "&id0=", with: "&id00="),
            "class 5: leading-zero index"
        )
        assertRejected(Self.vector1 + "&", "class 13: trailing ampersand")
        assertRejected("KITMEDIA2:", "class 13: empty descriptor")
        assertRejected(Self.vector1.replacingOccurrences(of: ":v=2&", with: ":v=1&"),
                       "class 13: v=1")
        assertRejected(Self.vector1.replacingOccurrences(of: ":v=2&", with: ":v=3&"),
                       "class 13: v=3")
        assertRejected(Self.vector1.replacingOccurrences(of: "&n=2&", with: "&n=02&"),
                       "non-canonical n spelling")
        assertRejected(Self.vector1 + "&zz", "token without =")
        assertRejected(Self.vector1 + "&=1", "token with empty key")
    }

    func testMalformedCaptions() {
        func withCap(_ encoded: String) -> String {
            Self.vector1.replacingOccurrences(of: "&cap=Family%20photos",
                                              with: "&cap=" + encoded)
        }
        assertRejected(withCap(""), "class 6: empty cap value")
        assertRejected(withCap("%20%09%0A"), "class 6: whitespace-only caption")
        assertRejected(withCap("%20Family"), "class 6: leading space")
        assertRejected(withCap("Family%20"), "class 6: trailing space")
        assertRejected(withCap("%09Family"), "class 6: leading tab")
        assertRejected(withCap("Family%0D"), "class 6: trailing carriage return")
        assertRejected(withCap("Fam%00ily"), "class 6: U+0000 inside caption")
        assertRejected(withCap(String(repeating: "a", count: 2_049)),
                       "class 6: caption of 2049 UTF-8 bytes")
        XCTAssertNotNil(
            KitMediaMessageV2Descriptor.parse(
                withCap(String(repeating: "a", count: 2_048))
            ),
            "control: a 2048-byte caption inside budget is valid"
        )
    }

    func testMalformedEncodingStrictness() {
        assertRejected(
            Self.vector1.replacingOccurrences(of: "&sha0=" + V1.sha0,
                                              with: "&sha0=" + "A" + String(repeating: "1", count: 63)),
            "class 7: uppercase hex in descriptor sha is a parse failure, never normalized"
        )
        XCTAssertNotNil(
            KitMediaMessageV2Descriptor.parse(
                Self.vector1.replacingOccurrences(of: "&sha0=" + V1.sha0,
                                                  with: "&sha0=" + "a" + String(repeating: "1", count: 63))
            ),
            "control: same digest lowercased is valid"
        )
        assertRejected(
            Self.vector1.replacingOccurrences(of: V1.sk0, with: V1.sk0.uppercased()),
            "class 7: uppercase UUID"
        )
        assertRejected(
            Self.vector1.replacingOccurrences(of: V1.id1, with: V1.id1 + "0"),
            "class 7: 37-character non-UUID id"
        )
        assertRejected(
            Self.vector1.replacingOccurrences(of: "&key0=" + Self.key0Encoded,
                                              with: "&key0=" + String(repeating: "A", count: 86)),
            "class 7: base64 missing padding"
        )
        assertRejected(
            Self.vector1.replacingOccurrences(of: "&key0=" + Self.key0Encoded,
                                              with: "&key0=" + String(repeating: "A", count: 84)),
            "class 7: key decodes to 63 bytes"
        )
        assertRejected(
            Self.vector1.replacingOccurrences(of: "&key0=" + Self.key0Encoded,
                                              with: "&key0=" + String(repeating: "A", count: 87) + "%3D"),
            "class 7: key decodes to 65 bytes"
        )
        assertRejected(
            Self.vector1.replacingOccurrences(of: "cap=Family%20photos",
                                              with: "cap=Family+photos"),
            "class 10: literal + for space"
        )
        assertRejected(
            Self.vector1.replacingOccurrences(of: "mt0=image%2Fjpeg",
                                              with: "mt0=image%2fjpeg"),
            "class 10: lowercase hex escape"
        )
        assertRejected(
            Self.vector1.replacingOccurrences(of: "mt0=image%2Fjpeg",
                                              with: "mt0=image/jpeg"),
            "class 10: raw slash in media type"
        )
        assertRejected(
            Self.vector1.replacingOccurrences(of: "cap=Family%20photos",
                                              with: "cap=Family%zzphotos"),
            "invalid percent escape"
        )
        assertRejected(
            Self.vector1.replacingOccurrences(of: "cap=Family%20photos",
                                              with: "cap=Familé"),
            "raw non-ASCII byte re-encodes differently"
        )
        assertRejected(
            Self.vector1.replacingOccurrences(of: "mt0=image%2Fjpeg",
                                              with: "mt0=image%2Ftiff"),
            "class 11: unsupported media type"
        )
    }

    func testMalformedArithmetic() {
        assertRejected(
            Self.vector1.replacingOccurrences(of: "&bs0=1088", with: "&bs0=1089"),
            "class 8: bs must equal ps + 64 − (ps mod 16)"
        )
        assertRejected(
            Self.vector1
                .replacingOccurrences(of: "&bs0=1088", with: "&bs0=63")
                .replacingOccurrences(of: "&ps0=1024", with: "&ps0=1"),
            "class 8: bs below 64"
        )
        assertRejected(
            Self.vector1
                .replacingOccurrences(of: "&bs0=1088", with: "&bs0=64")
                .replacingOccurrences(of: "&ps0=1024", with: "&ps0=0"),
            "class 8: ps=0"
        )
        assertRejected(
            Self.vector1
                .replacingOccurrences(of: "&bs0=1088", with: "&bs0=209715264")
                .replacingOccurrences(of: "&ps0=1024", with: "&ps0=209715201"),
            "class 8: ps above 200 MiB"
        )
        XCTAssertNotNil(
            KitMediaMessageV2Descriptor.parse(
                Self.vector1
                    .replacingOccurrences(of: "&bs0=1088", with: "&bs0=64")
                    .replacingOccurrences(of: "&ps0=1024", with: "&ps0=1")
            ),
            "control: ps=1 ⇒ bs=64 is the exact minimum"
        )
        XCTAssertNotNil(
            KitMediaMessageV2Descriptor.parse(
                Self.vector1
                    .replacingOccurrences(of: "&bs0=1088", with: "&bs0=209715264")
                    .replacingOccurrences(of: "&ps0=1024", with: "&ps0=209715200")
            ),
            "control: ps=200 MiB ⇒ bs=200 MiB+64 is the exact maximum"
        )
    }

    func testMalformedAggregate() {
        let bothMaximum = Self.vector1
            .replacingOccurrences(of: "&bs0=1088", with: "&bs0=209715264")
            .replacingOccurrences(of: "&ps0=1024", with: "&ps0=209715200")
            .replacingOccurrences(of: "&bs1=5242944", with: "&bs1=209715264")
            .replacingOccurrences(of: "&ps1=5242880", with: "&ps1=209715200")
        assertRejected(bothMaximum, "class 9: aggregate above 256 MiB")
        let exactAggregate = Self.vector1
            .replacingOccurrences(of: "&bs0=1088", with: "&bs0=209715264")
            .replacingOccurrences(of: "&ps0=1024", with: "&ps0=209715200")
            .replacingOccurrences(of: "&bs1=5242944", with: "&bs1=58720192")
            .replacingOccurrences(of: "&ps1=5242880", with: "&ps1=58720128")
        XCTAssertNotNil(KitMediaMessageV2Descriptor.parse(exactAggregate),
                        "control: aggregate of exactly 256 MiB is valid")
        let sixteenOver = exactAggregate
            .replacingOccurrences(of: "&bs1=58720192", with: "&bs1=58720208")
            .replacingOccurrences(of: "&ps1=58720128", with: "&ps1=58720144")
        assertRejected(sixteenOver, "class 9: aggregate 16 bytes above 256 MiB")
    }

    // MARK: - Outer set-match and canonical wire order

    private func vector1Rows() -> [KitMediaMessageOuterAttachmentRow] {
        [
            KitMediaMessageOuterAttachmentRow(
                id: V1.id0, storageKey: V1.sk0, mediaType: "image/jpeg",
                byteSize: 1_088, ciphertextSHA256Lowercased: V1.sha0
            ),
            KitMediaMessageOuterAttachmentRow(
                id: V1.id1, storageKey: V1.sk1, mediaType: "video/mp4",
                byteSize: 5_242_944, ciphertextSHA256Lowercased: V1.sha1
            ),
        ]
    }

    func testOuterRowSetMatch() {
        guard let descriptor = KitMediaMessageV2Descriptor.parse(Self.vector1) else {
            return XCTFail("V1 vector must parse")
        }
        let rows = vector1Rows()
        XCTAssertTrue(descriptor.matchesOuterRows(rows))
        XCTAssertTrue(descriptor.matchesOuterRows(rows.reversed()),
                      "outer rows carry no order; the descriptor is the display order")
        XCTAssertFalse(descriptor.matchesOuterRows([rows[0]]), "class 12: outer omits an item")
        XCTAssertFalse(descriptor.matchesOuterRows(rows + [
            KitMediaMessageOuterAttachmentRow(
                id: V2.id2, storageKey: V2.sk2, mediaType: "image/png",
                byteSize: 80, ciphertextSHA256Lowercased: V2.sha2
            ),
        ]), "class 12: outer has an extra row")
        XCTAssertFalse(descriptor.matchesOuterRows([rows[0], rows[0]]),
                       "class 12: duplicated outer row")
        var altered = rows
        altered[1] = KitMediaMessageOuterAttachmentRow(
            id: V1.id1, storageKey: V1.sk1, mediaType: "video/mp4",
            byteSize: 5_242_945, ciphertextSHA256Lowercased: V1.sha1
        )
        XCTAssertFalse(descriptor.matchesOuterRows(altered), "class 12: outer bs differs")
        // Case sensitivity needs a digest with letters; 64×"1" uppercases to itself.
        let letterSHA = "abcdef" + String(repeating: "1", count: 58)
        guard let letterDescriptor = KitMediaMessageV2Descriptor.parse(
            Self.vector1.replacingOccurrences(of: "&sha0=" + V1.sha0,
                                              with: "&sha0=" + letterSHA)
        ) else {
            return XCTFail("letter-bearing digest variant must parse")
        }
        var letterRows = rows
        letterRows[0] = KitMediaMessageOuterAttachmentRow(
            id: V1.id0, storageKey: V1.sk0, mediaType: "image/jpeg",
            byteSize: 1_088, ciphertextSHA256Lowercased: letterSHA
        )
        XCTAssertTrue(letterDescriptor.matchesOuterRows(letterRows))
        letterRows[0] = KitMediaMessageOuterAttachmentRow(
            id: V1.id0, storageKey: V1.sk0, mediaType: "image/jpeg",
            byteSize: 1_088, ciphertextSHA256Lowercased: letterSHA.uppercased()
        )
        XCTAssertFalse(descriptor.matchesOuterRows(letterRows),
                       "callers must lowercase the outer digest before matching")
    }

    func testCanonicalOuterOrderPolicy() {
        XCTAssertTrue(KitMediaMessageV2Descriptor.isCanonicalOuterOrder(
            attachmentIDs: [V1.id0, V1.id1]
        ))
        XCTAssertFalse(KitMediaMessageV2Descriptor.isCanonicalOuterOrder(
            attachmentIDs: [V1.id1, V1.id0]
        ))
        XCTAssertFalse(KitMediaMessageV2Descriptor.isCanonicalOuterOrder(
            attachmentIDs: [V1.id0, V1.id0]
        ), "strictly ascending: equal ids are never canonical")
        XCTAssertTrue(KitMediaMessageV2Descriptor.isCanonicalOuterOrder(
            attachmentIDs: [V1.id0]
        ))
        guard let descriptor = KitMediaMessageV2Descriptor.parse(Self.vector1) else {
            return XCTFail("V1 vector must parse")
        }
        let reversedDisplay = KitMediaMessageV2Descriptor(
            items: descriptor.items.reversed(), caption: descriptor.caption
        )
        XCTAssertEqual(reversedDisplay?.items.map { $0.attachmentID }, [V1.id1, V1.id0],
                       "display order is whatever the sender arranged")
        XCTAssertEqual(
            reversedDisplay?.canonicalOuterOrderItems.map { $0.attachmentID },
            [V1.id0, V1.id1],
            "wire order is ascending id regardless of display order"
        )
    }

    func testReadyLeaseReplacementReopensOnlyServerDerivedUploadFacts() throws {
        let original = KitMediaMessageV2OutboundBatch.Item(
            attachmentID: V1.id0,
            mediaType: "image/jpeg",
            plaintextByteSize: 1_024,
            keyMaterialBase64: Data(repeating: 0x41, count: 64).base64EncodedString(),
            localStorageKey: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        )
        let uploaded = try XCTUnwrap(original.uploaded(
            storageKey: V1.sk0,
            ciphertextByteSize: 1_088,
            ciphertextSHA256: V1.sha0
        ))

        let reopened = uploaded.reopeningUpload()

        XCTAssertFalse(reopened.isUploaded)
        XCTAssertNil(reopened.storageKey)
        XCTAssertNil(reopened.ciphertextByteSize)
        XCTAssertNil(reopened.ciphertextSHA256)
        XCTAssertEqual(reopened.attachmentID, original.attachmentID)
        XCTAssertEqual(reopened.mediaType, original.mediaType)
        XCTAssertEqual(reopened.plaintextByteSize, original.plaintextByteSize)
        XCTAssertEqual(reopened.keyMaterialBase64, original.keyMaterialBase64)
        XCTAssertEqual(reopened.localStorageKey, original.localStorageKey)
    }

    // MARK: - Caption budget (§4 `cap`, client test 8 model layer)

    func testCaptionBudget() {
        guard let descriptor = KitMediaMessageV2Descriptor.parse(Self.vector1) else {
            return XCTFail("V1 vector must parse")
        }
        let items = descriptor.items
        guard let remaining = KitMediaMessageV2Descriptor
            .remainingEncodedCaptionBudget(forItems: items) else {
            return XCTFail("valid items must have a caption budget")
        }
        let baseBytes = KitMediaMessageV2Descriptor(items: items, caption: nil)?
            .encoded.utf8.count ?? 0
        XCTAssertEqual(remaining, 7_680 - baseBytes - 5)
        XCTAssertTrue(KitMediaMessageV2Descriptor.canEncodeCaption("Family photos",
                                                                   withItems: items))
        XCTAssertTrue(KitMediaMessageV2Descriptor.canEncodeCaption(
            String(repeating: "a", count: 2_048), withItems: items
        ), "the full 2048-byte ceiling fits above two items")
        XCTAssertFalse(KitMediaMessageV2Descriptor.canEncodeCaption(
            String(repeating: "a", count: 2_049), withItems: items
        ), "2048 raw bytes is an absolute ceiling")

        // Eight maximal fixed-field items: a caption within the 2048-byte ceiling can still
        // overflow the shared 7680-byte descriptor budget once percent-encoded (CJK ⇒ ×9).
        var heavyItems: [KitMediaMessageV2Descriptor.Item] = []
        for index in 0 ..< 8 {
            heavyItems.append(KitMediaMessageV2Descriptor.Item(
                attachmentID: "0000000\(index)-0000-4000-8000-000000000000",
                storageKey: "0000000\(index)-1111-4000-8000-000000000000",
                mediaType: "application/vnd.openxmlformats-officedocument"
                    + ".wordprocessingml.document",
                ciphertextByteSize: 80,
                ciphertextSHA256: String(repeating: "6", count: 64),
                keyMaterial: Data(repeating: 0x00, count: 64),
                plaintextByteSize: 16
            ))
        }
        let cjkCaption = String(repeating: "好", count: 682)
        XCTAssertEqual(cjkCaption.utf8.count, 2_046, "raw bytes stay inside the ceiling")
        XCTAssertTrue(KitMediaMessageV2Descriptor.canEncodeCaption(cjkCaption,
                                                                   withItems: items),
                      "the same caption fits above two items")
        XCTAssertFalse(KitMediaMessageV2Descriptor.canEncodeCaption(cjkCaption,
                                                                    withItems: heavyItems),
                       "over the remaining encoded budget ⇒ visible failure, never truncation")
        XCTAssertNil(KitMediaMessageV2Descriptor(items: heavyItems, caption: cjkCaption),
                     "the descriptor itself refuses to seal over budget")
        XCTAssertNotNil(KitMediaMessageV2Descriptor(items: heavyItems, caption: nil),
                        "the items alone stay valid — the draft survives the failure")
        XCTAssertTrue(KitMediaMessageV2Descriptor.canEncodeCaption(
            String(repeating: "a", count: 2_048), withItems: heavyItems
        ), "an ASCII caption at the ceiling still fits maximal fixed fields")
    }

    // MARK: - Six-codepoint helpers (client test 9)

    func testSixCodepointHelpers() {
        XCTAssertEqual(
            KitMediaMessageCaptionPolicy.strippingBoundaryScalars("\t\n\u{0B}\u{0C}\r x \r\n\t"),
            "x"
        )
        XCTAssertEqual(KitMediaMessageCaptionPolicy.strippingBoundaryScalars(""), "")
        XCTAssertEqual(KitMediaMessageCaptionPolicy.strippingBoundaryScalars(" \t\r\n"), "")
        XCTAssertEqual(KitMediaMessageCaptionPolicy.strippingBoundaryScalars("a b"), "a b")
        // The exact set is smaller than every platform trim: these four are whitespace to
        // Foundation but NOT boundary codepoints to the contract.
        for scalar in ["\u{00A0}", "\u{2028}", "\u{2029}", "\u{0085}"] {
            let text = scalar + "x" + scalar
            XCTAssertEqual(KitMediaMessageCaptionPolicy.strippingBoundaryScalars(text), text,
                           "helper must not strip U+\(String(scalar.unicodeScalars.first!.value, radix: 16))")
            XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "x",
                           "platform trim differs — it must never be used for v2")
            XCTAssertTrue(KitMediaMessageCaptionPolicy.isCanonicalCaption(text))
        }
        XCTAssertTrue(KitMediaMessageCaptionPolicy.isCanonicalCaption("x"))
        XCTAssertTrue(KitMediaMessageCaptionPolicy.isCanonicalCaption("a b"))
        XCTAssertTrue(KitMediaMessageCaptionPolicy.isCanonicalCaption("\u{00A0}"))
        for invalid in ["", " ", " x", "x ", "\tx", "x\n", "\u{0B}x", "x\u{0C}", "x\r",
                        "a\u{0000}b", " \t "] {
            XCTAssertFalse(KitMediaMessageCaptionPolicy.isCanonicalCaption(invalid),
                           "caption \(invalid.debugDescription) must be rejected, not re-trimmed")
        }
    }

    // MARK: - Family classification (client tests 12/13/14 model layer)

    func testFamilyInputGuard() {
        for blocked in [
            "KITMEDIA1:x", "KITMEDIA2:", "KITMEDIA2:v=2&n=2", "KITMEDIA34:z",
            " KITMEDIA2:x", "\n\tKITMEDIA1:v=1", "\u{00A0}KITMEDIA2:x",
            "KITMEDIA999999999999999999999999:x", Self.vector1,
        ] {
            XCTAssertTrue(KitMediaMessageFamilyPolicy.blocksUserAuthoredText(blocked),
                          "input guard must block \(blocked.prefix(40))…")
        }
        for allowed in [
            "hello", "KITMEDIA:", "KITMEDIAtwo:x", "kitmedia2:x", "xKITMEDIA2:",
            "KITMEDIA2", "KIT MEDIA2:", "KITMEDIAN culture", "",
        ] {
            XCTAssertFalse(KitMediaMessageFamilyPolicy.blocksUserAuthoredText(allowed),
                           "ordinary text \(allowed.debugDescription) must stay sendable")
        }
    }

    func testPlaceholderClassification() {
        for placeholder in [
            "KITMEDIA2:garbage",
            "KITMEDIA2:v=2&n=1" + Self.vector1Group0,
            "KITMEDIA3:v=3&n=2",
            "KITMEDIA10:x",
            "\tKITMEDIA2:garbage",
            "\r\n" + Self.vector1,
        ] {
            XCTAssertTrue(
                KitMediaMessageFamilyPolicy.requiresGenericAttachmentPlaceholder(placeholder),
                "must render a generic placeholder for \(placeholder.prefix(40))…"
            )
        }
        XCTAssertFalse(
            KitMediaMessageFamilyPolicy.requiresGenericAttachmentPlaceholder(Self.vector1),
            "a valid v2 message renders as media, not placeholder"
        )
        XCTAssertFalse(
            KitMediaMessageFamilyPolicy.requiresGenericAttachmentPlaceholder(Self.vector2)
        )
        XCTAssertFalse(
            KitMediaMessageFamilyPolicy.requiresGenericAttachmentPlaceholder("KITMEDIA1:garbage"),
            "KITMEDIA1 keeps its audited legacy handling"
        )
        XCTAssertFalse(
            KitMediaMessageFamilyPolicy.requiresGenericAttachmentPlaceholder("hello")
        )
        XCTAssertFalse(
            KitMediaMessageFamilyPolicy
                .requiresGenericAttachmentPlaceholder("\u{00A0}KITMEDIA2:x"),
            "the placeholder strip is exactly the six-codepoint set"
        )
    }

    func testReservedFamilyConfinementPredicate() {
        for confined in [
            Self.vector1, Self.vector2, "KITMEDIA1:garbage", "KITMEDIA2:garbage",
            "KITMEDIA7:x", " KITMEDIA1:x",
        ] {
            XCTAssertTrue(KitMediaMessageFamilyPolicy.isReservedFamilyText(confined),
                          "leak surfaces must treat \(confined.prefix(30))… as key material")
        }
        XCTAssertFalse(KitMediaMessageFamilyPolicy.isReservedFamilyText("Family photos"))
        XCTAssertFalse(KitMediaMessageFamilyPolicy.isReservedFamilyText("KITEDIT1:v=1&t=x&b=y"),
                       "other reserved namespaces have their own policies")
    }

    // MARK: - Capability block coherence (client test 11 model layer)

    private func decodeCapabilityBlock(_ json: String) -> MessagingMediaMessageProtocolCapabilityDTO? {
        try? JSONDecoder().decode(
            MessagingMediaMessageProtocolCapabilityDTO.self,
            from: Data(json.utf8)
        )
    }

    func testCapabilityBlockCoherence() {
        let canonical = """
        {"profile":"kit-media-v2","ready":true,"max_attachments":8,\
        "max_descriptor_bytes":7680,"max_caption_utf8_bytes":2048,\
        "min_attachment_ciphertext_bytes":64,"max_attachment_ciphertext_bytes":209715264,\
        "max_aggregate_ciphertext_bytes":268435456}
        """
        guard let block = decodeCapabilityBlock(canonical) else {
            return XCTFail("contract block must decode")
        }
        XCTAssertTrue(block.supportsIOSV2)
        let incoherent = [
            canonical.replacingOccurrences(of: "\"ready\":true", with: "\"ready\":false"),
            canonical.replacingOccurrences(of: "kit-media-v2", with: "kit-media-v3"),
            canonical.replacingOccurrences(of: "\"max_attachments\":8",
                                           with: "\"max_attachments\":20"),
            canonical.replacingOccurrences(of: "\"max_descriptor_bytes\":7680",
                                           with: "\"max_descriptor_bytes\":8000"),
            canonical.replacingOccurrences(of: "\"max_caption_utf8_bytes\":2048",
                                           with: "\"max_caption_utf8_bytes\":4096"),
            canonical.replacingOccurrences(of: "\"min_attachment_ciphertext_bytes\":64",
                                           with: "\"min_attachment_ciphertext_bytes\":0"),
            canonical.replacingOccurrences(of: "209715264", with: "209715265"),
            canonical.replacingOccurrences(of: "268435456", with: "536870912"),
            "{}",
            "{\"ready\":true}",
        ]
        for json in incoherent {
            guard let block = decodeCapabilityBlock(json) else {
                XCTFail("tolerant field decode should not throw for \(json.prefix(40))")
                continue
            }
            XCTAssertFalse(block.supportsIOSV2,
                           "incoherent numbers must read as unavailable: \(json.prefix(60))")
        }
    }

    func testKeyMaterialAccessorRejectsNonCanonicalStorage() {
        let item = KitMediaMessageV2Descriptor.Item(
            attachmentID: V1.id0, storageKey: V1.sk0, mediaType: "image/jpeg",
            ciphertextByteSize: 1_088, ciphertextSHA256: V1.sha0,
            keyMaterialBase64: "***not base64***", plaintextByteSize: 1_024
        )
        XCTAssertNil(item.keyMaterial)
        XCTAssertNil(KitMediaMessageV2Descriptor(items: [
            item,
            KitMediaMessageV2Descriptor.Item(
                attachmentID: V1.id1, storageKey: V1.sk1, mediaType: "video/mp4",
                ciphertextByteSize: 5_242_944, ciphertextSHA256: V1.sha1,
                keyMaterial: Data(repeating: 0xFF, count: 64), plaintextByteSize: 5_242_880
            ),
        ], caption: nil), "a non-canonical key never constructs a descriptor")
    }

    static var allTests = [
        ("testVectorV1CanonicalRoundTrip", testVectorV1CanonicalRoundTrip),
        ("testVectorV1BuildsFromComponents", testVectorV1BuildsFromComponents),
        ("testVectorV2CanonicalRoundTrip", testVectorV2CanonicalRoundTrip),
        ("testMalformedAttachmentCounts", testMalformedAttachmentCounts),
        ("testMalformedOversizedDescriptor", testMalformedOversizedDescriptor),
        ("testMalformedDuplicateIdentity", testMalformedDuplicateIdentity),
        ("testMalformedFieldGrammar", testMalformedFieldGrammar),
        ("testMalformedCaptions", testMalformedCaptions),
        ("testMalformedEncodingStrictness", testMalformedEncodingStrictness),
        ("testMalformedArithmetic", testMalformedArithmetic),
        ("testMalformedAggregate", testMalformedAggregate),
        ("testOuterRowSetMatch", testOuterRowSetMatch),
        ("testCanonicalOuterOrderPolicy", testCanonicalOuterOrderPolicy),
        ("testReadyLeaseReplacementReopensOnlyServerDerivedUploadFacts",
         testReadyLeaseReplacementReopensOnlyServerDerivedUploadFacts),
        ("testCaptionBudget", testCaptionBudget),
        ("testSixCodepointHelpers", testSixCodepointHelpers),
        ("testFamilyInputGuard", testFamilyInputGuard),
        ("testPlaceholderClassification", testPlaceholderClassification),
        ("testReservedFamilyConfinementPredicate", testReservedFamilyConfinementPredicate),
        ("testCapabilityBlockCoherence", testCapabilityBlockCoherence),
        ("testKeyMaterialAccessorRejectsNonCanonicalStorage",
         testKeyMaterialAccessorRejectsNonCanonicalStorage),
    ]
}
