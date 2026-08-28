import Foundation

// KITMEDIA2 — multi-attachment media message core (contract v0.4,
// SHA-256 449925d9a614c4b4d93dfd42bd2f363d177fab89c4100014e331e3c63c1c7097).
//
// Everything in this file is deliberately Foundation-only and self-contained: it must compile
// and run on Linux so the byte-exact wire grammar can be executed against the contract's test
// vectors outside Xcode. The few small duplicates of `MessagingAPIModels.swift` definitions
// (percent encoder, allowed media types, key-material size) are pinned byte/element-identical
// by `test_media_message_v2_contract.py`; do not let them drift.

/// The exact six-codepoint boundary set of the KITMEDIA2 contract, with the helpers both the
/// caption rule and reserved-family detection are required to use.
///
/// No platform trim matches this set: `.whitespacesAndNewlines` also strips U+00A0, U+0085,
/// U+2028/U+2029 and more, so it MUST NOT be used anywhere on the v2 caption path. Receivers
/// reject — never re-trim — captions that violate the boundary rule, which is why the sender-side
/// strip and the receiver-side predicate live together here.
enum KitMediaMessageCaptionPolicy {
    /// {U+0009, U+000A, U+000B, U+000C, U+000D, U+0020} — exactly these, nothing else.
    static let boundaryScalars: Set<Unicode.Scalar> = [
        "\u{0009}", "\u{000A}", "\u{000B}", "\u{000C}", "\u{000D}", "\u{0020}",
    ]

    /// Sender-side normalization: strip leading and trailing scalars from the exact boundary
    /// set. Operates on Unicode scalars, not `Character`s, because CR LF folds into a single
    /// grapheme and a combining mark can hide a boundary scalar inside one.
    static func strippingBoundaryScalars(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let start = scalars.firstIndex(where: { !boundaryScalars.contains($0) }),
              let end = scalars.lastIndex(where: { !boundaryScalars.contains($0) })
        else { return "" }
        var stripped = ""
        stripped.unicodeScalars.append(contentsOf: scalars[start ... end])
        return stripped
    }

    /// Receiver-side rule for a decoded `cap` value: present, no U+0000 anywhere, no boundary
    /// scalar at either end, and at least one scalar outside the boundary set. Byte budgets are
    /// enforced by the descriptor, not here. Bytes are preserved as typed — no NFC/NFKC.
    static func isCanonicalCaption(_ caption: String) -> Bool {
        let scalars = caption.unicodeScalars
        guard let first = scalars.first, let last = scalars.last,
              !scalars.contains("\u{0000}"),
              !boundaryScalars.contains(first),
              !boundaryScalars.contains(last),
              scalars.contains(where: { !boundaryScalars.contains($0) })
        else { return false }
        return true
    }
}

/// Canonical multi-attachment media descriptor encrypted as the Signal message body.
///
/// `KITMEDIA2:v=2&n=<N>` followed, for each item k = 0…N−1 in display order, by the group
/// `id<k>`, `sk<k>`, `mt<k>`, `bs<k>`, `sha<k>`, `key<k>`, `ps<k>` (the KITMEDIA1 intra-group
/// order), then optionally `cap` last. Fixed field order, exact field count, and byte-exact
/// re-encode equality make first sends, retries, sync events, and Android/iOS parsing
/// byte-identical — there is exactly one spelling of every valid message.
///
/// The descriptor item order is the authoritative display order. Outer wire rows deliberately
/// carry no order (§5: ascending attachment-id serialization, uncorrelated with display).
struct KitMediaMessageV2Descriptor: Equatable, Hashable, Sendable {
    static let prefix = "KITMEDIA2:"
    /// Byte-based on both platforms — this deliberately resolves the KITMEDIA1
    /// iOS(4096 chars)/Android(3584 bytes) ceiling discrepancy for v2.
    static let maximumDescriptorUTF8Bytes = 7_680
    static let maximumCaptionUTF8Bytes = 2_048
    /// A single attachment stays `KITMEDIA1`; `n=1` is malformed by contract.
    static let minimumAttachmentCount = 2
    /// The audited cross-platform staging ceiling and raised backend unclaimed-upload quota.
    static let maximumAttachmentCount = 8
    static let minimumAttachmentCiphertextBytes: Int64 = 64
    static let maximumAttachmentCiphertextBytes: Int64 = 200 * 1_024 * 1_024 + 64
    static let maximumPlaintextBytes = 200 * 1_024 * 1_024
    /// Σ bs over all items — aligned with the rolling 24 h upload quota.
    static let maximumAggregateCiphertextBytes: Int64 = 256 * 1_024 * 1_024
    static let keyMaterialBytes = 64
    private static let prefixUTF8 = Array(prefix.utf8)

    /// Mirror of `SecureMessagingWire.allowedAttachmentMediaTypes`, duplicated so this file
    /// stays Foundation-only; the contract test asserts the two sets are element-identical.
    static let allowedAttachmentMediaTypes: Set<String> = [
        "image/jpeg",
        "image/png",
        "image/webp",
        "image/gif",
        "audio/mp4",
        "audio/aac",
        "audio/mpeg",
        "audio/ogg",
        "video/mp4",
        "video/quicktime",
        "video/webm",
        "application/pdf",
        "application/zip",
        "application/msword",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.ms-excel",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.ms-powerpoint",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "text/plain",
        "text/csv",
        "application/octet-stream",
    ]

    /// One attachment of the logical message, in display position. Field names and widths match
    /// `KitMediaMessageDescriptor`; all validation happens in the descriptor initializer so no
    /// construction path can skip it.
    struct Item: Equatable, Hashable, Sendable {
        let attachmentID: String
        let storageKey: String
        let mediaType: String
        let ciphertextByteSize: Int64
        let ciphertextSHA256: String
        let keyMaterialBase64: String
        let plaintextByteSize: Int

        init(
            attachmentID: String,
            storageKey: String,
            mediaType: String,
            ciphertextByteSize: Int64,
            ciphertextSHA256: String,
            keyMaterialBase64: String,
            plaintextByteSize: Int
        ) {
            self.attachmentID = attachmentID
            self.storageKey = storageKey
            self.mediaType = mediaType
            self.ciphertextByteSize = ciphertextByteSize
            self.ciphertextSHA256 = ciphertextSHA256
            self.keyMaterialBase64 = keyMaterialBase64
            self.plaintextByteSize = plaintextByteSize
        }

        init(
            attachmentID: String,
            storageKey: String,
            mediaType: String,
            ciphertextByteSize: Int64,
            ciphertextSHA256: String,
            keyMaterial: Data,
            plaintextByteSize: Int
        ) {
            self.init(
                attachmentID: attachmentID,
                storageKey: storageKey,
                mediaType: mediaType,
                ciphertextByteSize: ciphertextByteSize,
                ciphertextSHA256: ciphertextSHA256,
                keyMaterialBase64: keyMaterial.base64EncodedString(),
                plaintextByteSize: plaintextByteSize
            )
        }

        /// Decoded 64-byte AES+HMAC key material, only when the stored base64 is canonical.
        var keyMaterial: Data? {
            KitMediaMessageV2Descriptor.canonicalKeyMaterial(keyMaterialBase64)
        }
    }

    /// Items in authoritative display order.
    let items: [Item]
    let caption: String?

    /// Validates the complete §3/§4 field contract. The caption must already be canonical —
    /// senders strip via `KitMediaMessageCaptionPolicy.strippingBoundaryScalars` first; a
    /// receiver-side violation is a rejection here, never a re-trim.
    init?(items: [Item], caption: String?) {
        guard (Self.minimumAttachmentCount ... Self.maximumAttachmentCount).contains(items.count)
        else { return nil }
        var attachmentIDs = Set<String>()
        var storageKeys = Set<String>()
        var aggregateCiphertextBytes: Int64 = 0
        for item in items {
            guard Self.isCanonicalUUID(item.attachmentID),
                  attachmentIDs.insert(item.attachmentID).inserted,
                  Self.isCanonicalUUID(item.storageKey),
                  storageKeys.insert(item.storageKey).inserted,
                  Self.allowedAttachmentMediaTypes.contains(item.mediaType),
                  (Self.minimumAttachmentCiphertextBytes
                      ... Self.maximumAttachmentCiphertextBytes)
                      .contains(item.ciphertextByteSize),
                  (1 ... Self.maximumPlaintextBytes).contains(item.plaintextByteSize),
                  // IV(16) ‖ CBC-PKCS7 ‖ HMAC(32): both endpoints control both numbers, so the
                  // exact padding arithmetic is a cheap authenticated cross-check.
                  item.ciphertextByteSize
                      == Int64(item.plaintextByteSize + 64 - (item.plaintextByteSize % 16)),
                  Self.isLowercaseSHA256(item.ciphertextSHA256),
                  Self.canonicalKeyMaterial(item.keyMaterialBase64) != nil
            else { return nil }
            aggregateCiphertextBytes += item.ciphertextByteSize
        }
        guard aggregateCiphertextBytes <= Self.maximumAggregateCiphertextBytes else { return nil }
        if let caption {
            guard KitMediaMessageCaptionPolicy.isCanonicalCaption(caption),
                  caption.utf8.count <= Self.maximumCaptionUTF8Bytes
            else { return nil }
        }
        self.items = items
        self.caption = caption
        guard encoded.utf8.count <= Self.maximumDescriptorUTF8Bytes else { return nil }
    }

    var encoded: String {
        var value = Self.prefix
        value += "v=2"
        value += "&n=\(items.count)"
        for (index, item) in items.enumerated() {
            value += "&id\(index)=\(Self.percentEncode(item.attachmentID))"
            value += "&sk\(index)=\(Self.percentEncode(item.storageKey))"
            value += "&mt\(index)=\(Self.percentEncode(item.mediaType))"
            value += "&bs\(index)=\(item.ciphertextByteSize)"
            value += "&sha\(index)=\(Self.percentEncode(item.ciphertextSHA256))"
            value += "&key\(index)=\(Self.percentEncode(item.keyMaterialBase64))"
            value += "&ps\(index)=\(item.plaintextByteSize)"
        }
        if let caption { value += "&cap=\(Self.percentEncode(caption))" }
        return value
    }

    /// Items in the canonical outer wire-row order: ascending lexicographic lowercase
    /// attachment id — never display order, so the server learns nothing about arrangement.
    var canonicalOuterOrderItems: [Item] {
        items.sorted { $0.attachmentID < $1.attachmentID }
    }

    /// Whether an outer `attachments` id sequence is in the canonical strictly-ascending order
    /// the server's gate 0 enforces before its idempotent-replay shortcut.
    static func isCanonicalOuterOrder(attachmentIDs: [String]) -> Bool {
        zip(attachmentIDs, attachmentIDs.dropFirst()).allSatisfy { $0 < $1 }
    }

    /// Strict closed-world parser (§4). The input must start with the exact prefix bytes — no
    /// leading whitespace — decode strictly, match the fixed key sequence exactly, satisfy every
    /// field constraint, and re-encode byte-for-byte to the input. Anything else is nil, and the
    /// caller renders the generic placeholder rather than the raw text.
    static func parse(_ text: String) -> KitMediaMessageV2Descriptor? {
        guard text.utf8.count <= maximumDescriptorUTF8Bytes,
              Array(text.utf8.prefix(prefixUTF8.count)) == prefixUTF8
        else { return nil }
        var pairs: [(key: String, value: String)] = []
        for pair in text.dropFirst(prefix.count)
            .split(separator: "&", omittingEmptySubsequences: false) {
            guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else {
                return nil
            }
            let key = String(pair[..<separator])
            let encodedValue = String(pair[pair.index(after: separator)...])
            guard let value = encodedValue.removingPercentEncoding else { return nil }
            pairs.append((key: key, value: value))
        }
        guard pairs.count >= 2,
              pairs[0].key == "v", pairs[0].value == "2",
              pairs[1].key == "n", let count = Int(pairs[1].value),
              (minimumAttachmentCount ... maximumAttachmentCount).contains(count)
        else { return nil }
        var expectedKeys = ["v", "n"]
        for index in 0 ..< count {
            expectedKeys += [
                "id\(index)", "sk\(index)", "mt\(index)", "bs\(index)",
                "sha\(index)", "key\(index)", "ps\(index)",
            ]
        }
        let hasCaption: Bool
        switch pairs.count {
        case expectedKeys.count: hasCaption = false
        case expectedKeys.count + 1: hasCaption = true; expectedKeys.append("cap")
        default: return nil
        }
        guard pairs.map({ $0.key }) == expectedKeys else { return nil }
        var items: [Item] = []
        for index in 0 ..< count {
            let base = 2 + 7 * index
            guard let ciphertextByteSize = Int64(pairs[base + 3].value),
                  let plaintextByteSize = Int(pairs[base + 6].value)
            else { return nil }
            items.append(Item(
                attachmentID: pairs[base].value,
                storageKey: pairs[base + 1].value,
                mediaType: pairs[base + 2].value,
                ciphertextByteSize: ciphertextByteSize,
                ciphertextSHA256: pairs[base + 4].value,
                keyMaterialBase64: pairs[base + 5].value,
                plaintextByteSize: plaintextByteSize
            ))
        }
        guard let descriptor = KitMediaMessageV2Descriptor(
            items: items,
            caption: hasCaption ? pairs[pairs.count - 1].value : nil
        ), Array(descriptor.encoded.utf8) == Array(text.utf8) else { return nil }
        return descriptor
    }

    /// Encoded bytes left for `&cap=<enc(caption)>` after the fixed per-item fields — the number
    /// the sender must check before sealing. 2 048 raw caption bytes is a ceiling, not a
    /// guaranteed allowance; nil when the items themselves are invalid.
    static func remainingEncodedCaptionBudget(forItems items: [Item]) -> Int? {
        guard let base = KitMediaMessageV2Descriptor(items: items, caption: nil) else {
            return nil
        }
        return maximumDescriptorUTF8Bytes - base.encoded.utf8.count - "&cap=".utf8.count
    }

    /// Sender-side pre-flight for a caption already normalized by
    /// `strippingBoundaryScalars`. False means the send must fail visibly with the draft
    /// preserved — never truncate, never split the caption into a separate message.
    static func canEncodeCaption(_ caption: String, withItems items: [Item]) -> Bool {
        guard KitMediaMessageCaptionPolicy.isCanonicalCaption(caption),
              caption.utf8.count <= maximumCaptionUTF8Bytes,
              let remaining = remainingEncodedCaptionBudget(forItems: items)
        else { return false }
        return percentEncode(caption).utf8.count <= remaining
    }

    // MARK: - Self-contained field validators (Linux-compilable duplicates)

    // (fileprivate, not private: the outbound batch in this file validates decoded persisted
    // state against the identical canonical forms.)
    fileprivate static func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    /// Exactly 64 lowercase hex characters. The descriptor digest is never normalized —
    /// uppercase here is a parse failure, unlike the outer row where receivers lowercase first.
    fileprivate static func isLowercaseSHA256(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 64 && bytes.allSatisfy {
            (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
        }
    }

    private static func canonicalKeyMaterial(_ base64: String) -> Data? {
        guard let data = Data(base64Encoded: base64),
              data.count == keyMaterialBytes,
              data.base64EncodedString() == base64
        else { return nil }
        return data
    }

    static func percentEncode(_ value: String) -> String {
        // Match Android's URLEncoder(UTF-8).replace("+", "%20") exactly. Foundation's
        // URL-unreserved set differs for `*`, `~`, and non-ASCII letters, which would make each
        // client reject the other's otherwise valid authenticated descriptor as non-canonical.
        let hex = Array("0123456789ABCDEF".utf8)
        var encoded = String()
        encoded.reserveCapacity(value.utf8.count * 3)
        for byte in value.utf8 {
            switch byte {
            case 0x41 ... 0x5A, 0x61 ... 0x7A, 0x30 ... 0x39,
                 0x2D, 0x2E, 0x2A, 0x5F:
                encoded.unicodeScalars.append(UnicodeScalar(byte))
            case 0x20:
                encoded += "%20"
            default:
                encoded.unicodeScalars.append("%")
                encoded.unicodeScalars.append(UnicodeScalar(hex[Int(byte >> 4)]))
                encoded.unicodeScalars.append(UnicodeScalar(hex[Int(byte & 0x0F)]))
            }
        }
        return encoded
    }
}

/// One outer wire `attachments` row as the receiver sees it, reduced to the five authenticated
/// fields the §4 set-match compares. The digest field name spells out the §4 rule: the receiver
/// lowercases the OUTER value before matching (defense-in-depth; senders are required to put
/// lowercase on the wire for multi-row), while a non-lowercase descriptor digest was already a
/// parse failure.
struct KitMediaMessageOuterAttachmentRow: Equatable, Hashable, Sendable {
    let id: String
    let storageKey: String
    let mediaType: String
    let byteSize: Int64
    let ciphertextSHA256Lowercased: String
}

extension KitMediaMessageV2Descriptor {
    /// §4 rule 4: outer rows and descriptor items must be the same set — match on
    /// id + sk + mt + bs + sha, same cardinality, no extras or repeats on either side. Outer
    /// rows carry no order; display order comes only from the descriptor.
    func matchesOuterRows(_ rows: [KitMediaMessageOuterAttachmentRow]) -> Bool {
        guard rows.count == items.count else { return false }
        let received = Set(rows)
        guard received.count == rows.count else { return false }
        let expected = Set(items.map { item in
            KitMediaMessageOuterAttachmentRow(
                id: item.attachmentID,
                storageKey: item.storageKey,
                mediaType: item.mediaType,
                byteSize: item.ciphertextByteSize,
                ciphertextSHA256Lowercased: item.ciphertextSHA256
            )
        })
        return received == expected
    }
}

/// Reserved-family classification for `KITMEDIA<k>:` bodies.
///
/// Two deliberately different strips serve two different duties. Input blocking uses the
/// existing `SecureMessageReservedPrefixPolicy` whitespace superset, so nothing a user can type,
/// paste, share in, or smuggle through an edit payload begins a reserved media descriptor.
/// Placeholder rendering uses the contract's exact six-codepoint strip, so both platforms
/// classify byte-identical inbound text identically. Render safety is feature-flag independent:
/// none of these predicates consult any capability.
enum KitMediaMessageFamilyPolicy {
    static let familyPrefix = "KITMEDIA"

    /// Parses `KITMEDIA<digits>:` at the exact start of `text`; a digit run too large for `Int`
    /// still marks the family (clamped), because an absurd version is still not user prose.
    private static func familyVersion(atStartOf text: Substring) -> Int? {
        guard text.hasPrefix(familyPrefix) else { return nil }
        let afterPrefix = text.dropFirst(familyPrefix.count)
        let digits = afterPrefix.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, afterPrefix.dropFirst(digits.count).first == ":" else {
            return nil
        }
        return Int(digits) ?? Int.max
    }

    /// The family version visible after the contract's exact six-codepoint strip, or nil when
    /// the text is not reserved-family shaped.
    static func familyVersion(of text: String) -> Int? {
        familyVersion(
            atStartOf: Substring(KitMediaMessageCaptionPolicy.strippingBoundaryScalars(text))
        )
    }

    /// Input-boundary guard for composer text, shared-in text, pasted text, and edit payloads:
    /// blocks the entire family — every version, including 1 — behind any leading whitespace a
    /// composer would tolerate. It deliberately does NOT gate a validated v2 message itself:
    /// a successfully parsed media message stays first-class user content downstream.
    static func blocksUserAuthoredText(_ text: String) -> Bool {
        familyVersion(atStartOf: text.drop(while: { $0.isWhitespace })) != nil
            || familyVersion(of: text) != nil
    }

    /// §4 rule 6: a body that is `KITMEDIA2:`-shaped — or any unknown `KITMEDIA<k≥2>:` version —
    /// but fails the strict parse renders as the generic "Attachment" placeholder. Never the raw
    /// text, never quoted into replies, never in notification previews. `KITMEDIA1` keeps its
    /// audited legacy handling and is deliberately outside this predicate.
    static func requiresGenericAttachmentPlaceholder(_ text: String) -> Bool {
        guard let version = familyVersion(of: text), version >= 2 else { return false }
        return KitMediaMessageV2Descriptor.parse(text) == nil
    }

    /// Family-wide confinement predicate for the leak surfaces (copy, forward, search, abuse
    /// reports, share previews, accessibility): true for anything reserved-family shaped,
    /// parseable or not, any version. A descriptor is key material, not message text.
    static func isReservedFamilyText(_ text: String) -> Bool {
        blocksUserAuthoredText(text)
    }

    /// The canonical strictly-unparseable family spelling (malformed vector 13's empty
    /// descriptor), persisted in place of a v2 body that parsed cleanly but whose authenticated
    /// outer rows failed the set-match (malformed vector 12). Keeping the raw valid-parse text
    /// would make the row read as a working media message to every body-driven surface while
    /// retaining key material the server never tied to it; this spelling instead routes the row
    /// through the same `requiresGenericAttachmentPlaceholder` confinement as every other
    /// unparseable family body.
    static let confinedPlaceholderBody = "KITMEDIA2:"
}

/// Roster/feature keys and the advertised-profile constants for multi-attachment messages.
enum MessagingMediaMessageV2CapabilityPolicy {
    static let featureKey = "messaging_media_message_v2"
    static let deviceCapabilityKey = "messaging_media_message_v2"
    static let profile = "kit-media-v2"
}

/// `protocols.messaging.media_message` capability block. The contract's advertised numbers are
/// fixed — there are no dynamic lower maxima — so coherence is exact equality against the
/// compiled contract constants, `MessagingRichMediaProtocolCapabilityDTO.supportsIOSV1` style:
/// absent, not ready, wrong profile, or any incoherent number all read as "feature off".
struct MessagingMediaMessageProtocolCapabilityDTO: Decodable, Hashable, Sendable {
    let profile: String?
    let ready: Bool?
    let maxAttachments: Int?
    let maxDescriptorBytes: Int?
    let maxCaptionUTF8Bytes: Int?
    let minAttachmentCiphertextBytes: Int64?
    let maxAttachmentCiphertextBytes: Int64?
    let maxAggregateCiphertextBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case profile
        case ready
        case maxAttachments = "max_attachments"
        case maxDescriptorBytes = "max_descriptor_bytes"
        case maxCaptionUTF8Bytes = "max_caption_utf8_bytes"
        case minAttachmentCiphertextBytes = "min_attachment_ciphertext_bytes"
        case maxAttachmentCiphertextBytes = "max_attachment_ciphertext_bytes"
        case maxAggregateCiphertextBytes = "max_aggregate_ciphertext_bytes"
    }

    var supportsIOSV2: Bool {
        ready == true
            && profile == MessagingMediaMessageV2CapabilityPolicy.profile
            && maxAttachments == KitMediaMessageV2Descriptor.maximumAttachmentCount
            && maxDescriptorBytes == KitMediaMessageV2Descriptor.maximumDescriptorUTF8Bytes
            && maxCaptionUTF8Bytes == KitMediaMessageV2Descriptor.maximumCaptionUTF8Bytes
            && minAttachmentCiphertextBytes
                == KitMediaMessageV2Descriptor.minimumAttachmentCiphertextBytes
            && maxAttachmentCiphertextBytes
                == KitMediaMessageV2Descriptor.maximumAttachmentCiphertextBytes
            && maxAggregateCiphertextBytes
                == KitMediaMessageV2Descriptor.maximumAggregateCiphertextBytes
    }
}

/// Durable send-side state for one queued KITMEDIA2 message: §7 QUEUED through SEALED.
///
/// The whole batch is one message identity — one local message, one client message id, one wire
/// request. Items never split into separate sends. Attachment ids and the 64-byte key material
/// are minted once at queue time so (a) upload scheduling can order by ascending id, which is a
/// fresh random namespace uncorrelated with display position, and (b) the caption byte budget is
/// exact before anything uploads: every field the encoder sees is either the real value or a
/// placeholder of the same encoded width (storage key 36, digest 64).
///
/// Each item's UPLOADED fields are persisted together in one checkpoint, so a crash resumes
/// exactly at the first item that never durably finished — finished uploads are kept, per §7.
struct KitMediaMessageV2OutboundBatch: Codable, Hashable, Sendable {
    struct Item: Codable, Hashable, Sendable {
        /// Fresh random canonical UUID minted at queue time. Also the §5 outer-row sort key.
        let attachmentID: String
        let mediaType: String
        let plaintextByteSize: Int
        /// The 64-byte AES+HMAC key material, minted at queue time and kept across a blob-expiry
        /// re-upload (the ciphertext IV is fresh per encryption; the descriptor width is not).
        let keyMaterialBase64: String
        /// Where the plaintext lives in the local encrypted blob cache right now: the park key
        /// minted at queue time, or the previous server storage key after a blob-expiry reopen.
        var localStorageKey: String
        // UPLOADED fields — nil until the item's upload checkpoint persists all three at once.
        var storageKey: String? = nil
        var ciphertextByteSize: Int64? = nil
        var ciphertextSHA256: String? = nil

        var isUploaded: Bool {
            storageKey != nil && ciphertextByteSize != nil && ciphertextSHA256 != nil
        }

        /// The item with its server-verified upload result staged for the durable checkpoint;
        /// nil when the metadata violates §4 — non-canonical storage key, padding arithmetic
        /// that does not match the plaintext size, malformed digest — or when the storage key
        /// collides with the item's local plaintext key (removing one would destroy the other).
        func uploaded(
            storageKey: String,
            ciphertextByteSize: Int64,
            ciphertextSHA256: String
        ) -> Item? {
            guard KitMediaMessageV2Descriptor.isCanonicalUUID(storageKey),
                  storageKey != localStorageKey,
                  (1 ... KitMediaMessageV2Descriptor.maximumPlaintextBytes)
                      .contains(plaintextByteSize),
                  ciphertextByteSize
                      == Int64(plaintextByteSize + 64 - (plaintextByteSize % 16)),
                  KitMediaMessageV2Descriptor.isLowercaseSHA256(ciphertextSHA256)
            else { return nil }
            var staged = self
            staged.storageKey = storageKey
            staged.ciphertextByteSize = ciphertextByteSize
            staged.ciphertextSHA256 = ciphertextSHA256
            return staged
        }

        /// Descriptor item for budget math and sealing. Placeholders stand in for the upload
        /// fields until they exist; both are the exact encoded width of any real value.
        func descriptorItem(placeholderIndex: Int) -> KitMediaMessageV2Descriptor.Item {
            let plaintext = plaintextByteSize
            // Bound before any derived-size arithmetic: a corrupt persisted size (Int.max) must
            // fail §4 validation downstream, not trap inside the validator's own path. The real
            // size is still forwarded, so the descriptor initializer rejects it.
            let boundedPlaintext = (1 ... KitMediaMessageV2Descriptor.maximumPlaintextBytes)
                .contains(plaintext) ? plaintext : 0
            return KitMediaMessageV2Descriptor.Item(
                attachmentID: attachmentID,
                storageKey: storageKey
                    ?? KitMediaMessageV2OutboundBatch.placeholderStorageKey(
                        forIndex: placeholderIndex
                    ),
                mediaType: mediaType,
                ciphertextByteSize: ciphertextByteSize
                    ?? Int64(boundedPlaintext + 64 - (boundedPlaintext % 16)),
                ciphertextSHA256: ciphertextSHA256
                    ?? KitMediaMessageV2OutboundBatch.placeholderCiphertextSHA256,
                keyMaterialBase64: keyMaterialBase64,
                plaintextByteSize: plaintext
            )
        }
    }

    /// What the composer hands over per attachment, in display order.
    struct DraftAttachment: Equatable, Sendable {
        let mediaType: String
        let plaintextByteSize: Int
        /// Queue-time park key in the local encrypted blob cache; canonical lowercase UUID.
        let localStorageKey: String

        init(mediaType: String, plaintextByteSize: Int, localStorageKey: String) {
            self.mediaType = mediaType
            self.plaintextByteSize = plaintextByteSize
            self.localStorageKey = localStorageKey
        }
    }

    enum QueueValidationError: Error, Equatable {
        /// The item set itself violates §4: count, media type, size, or aggregate ceiling.
        case invalidItems
        /// The items are valid but the caption cannot ride: the send must fail visibly with
        /// the draft preserved — never truncate, never split the caption into its own message.
        case captionOverBudget
        /// The caption begins with a reserved KITMEDIA-family prefix. User-authored text must
        /// never masquerade as a descriptor (§4 rule 6), on any surface a body reaches.
        case reservedCaption
    }

    /// Items in authoritative display order — the order the descriptor will carry.
    var items: [Item]
    /// Canonical caption (already boundary-stripped, non-empty), or nil to omit `cap` entirely.
    let caption: String?

    /// Validates and mints a queue-ready batch. `rawCaption` is the typed text before
    /// normalization; after the contract's exact six-codepoint strip an empty result means the
    /// message carries no caption. Any §4 violation throws — nothing is ever partially queued.
    static func queued(
        attachments: [DraftAttachment],
        rawCaption: String?,
        keyMaterialFactory: () throws -> Data
    ) throws -> KitMediaMessageV2OutboundBatch {
        // §4 count preflight before anything is minted: over-limit input fails with zero side
        // effects — no attachment ids assigned, no key material drawn from the factory.
        guard (KitMediaMessageV2Descriptor.minimumAttachmentCount
            ... KitMediaMessageV2Descriptor.maximumAttachmentCount)
            .contains(attachments.count)
        else { throw QueueValidationError.invalidItems }
        let items = try attachments.map { attachment in
            Item(
                attachmentID: UUID().uuidString.lowercased(),
                mediaType: attachment.mediaType,
                plaintextByteSize: attachment.plaintextByteSize,
                keyMaterialBase64: try keyMaterialFactory().base64EncodedString(),
                localStorageKey: attachment.localStorageKey
            )
        }
        let stripped = rawCaption.map(KitMediaMessageCaptionPolicy.strippingBoundaryScalars)
        let caption = stripped?.isEmpty == false ? stripped : nil
        if let caption, KitMediaMessageFamilyPolicy.blocksUserAuthoredText(caption) {
            throw QueueValidationError.reservedCaption
        }
        let batch = KitMediaMessageV2OutboundBatch(items: items, caption: caption)
        let placeholders = batch.placeholderDescriptorItems()
        // Items-only first, then the caption, so each failure carries its own visible reason.
        guard KitMediaMessageV2Descriptor(items: placeholders, caption: nil) != nil else {
            throw QueueValidationError.invalidItems
        }
        if let caption {
            guard KitMediaMessageV2Descriptor.canEncodeCaption(caption, withItems: placeholders)
            else { throw QueueValidationError.captionOverBudget }
        }
        // Park keys and upload-triple coherence sit outside the descriptor's view.
        guard batch.isStructurallyValid else { throw QueueValidationError.invalidItems }
        return batch
    }

    /// §7 blob-expiry recovery: the sealed descriptor alone reopens the batch. Ids, media
    /// types, sizes, key material, caption, and display order are all preserved; each item's
    /// previous storage key becomes its local plaintext pointer and the upload fields clear so
    /// every item re-uploads under a fresh storage key with the same client message id.
    static func reopened(
        from descriptor: KitMediaMessageV2Descriptor
    ) -> KitMediaMessageV2OutboundBatch {
        KitMediaMessageV2OutboundBatch(
            items: descriptor.items.map { item in
                Item(
                    attachmentID: item.attachmentID,
                    mediaType: item.mediaType,
                    plaintextByteSize: item.plaintextByteSize,
                    keyMaterialBase64: item.keyMaterialBase64,
                    localStorageKey: item.storageKey
                )
            },
            caption: descriptor.caption
        )
    }

    /// Indices of items still needing an upload, in the §5 upload schedule: ascending
    /// attachment id, never display order.
    var pendingUploadIndicesInUploadOrder: [Int] {
        items.indices
            .filter { !items[$0].isUploaded }
            .sorted { items[$0].attachmentID < items[$1].attachmentID }
    }

    /// Every local blob-cache key this batch may currently hold plaintext under: the park (or
    /// reopen) key of every item plus the storage-key copy staged at each upload checkpoint.
    /// Local deletion must remove all of them — a v2 message can hold up to 16.
    var allLocalStorageKeys: [String] {
        items.flatMap { item -> [String] in
            var keys = [item.localStorageKey]
            if let storageKey = item.storageKey { keys.append(storageKey) }
            return keys
        }
    }

    /// The §4-valid descriptor once every item is durably uploaded, in display order; nil while
    /// any upload is outstanding or any field fails validation.
    func sealedDescriptor() -> KitMediaMessageV2Descriptor? {
        guard items.allSatisfy({ $0.isUploaded }) else { return nil }
        return KitMediaMessageV2Descriptor(
            items: items.enumerated().map { $0.element.descriptorItem(placeholderIndex: $0.offset) },
            caption: caption
        )
    }

    /// Descriptor items with fixed-width placeholders for the not-yet-uploaded fields; the
    /// basis of the exact queue-time caption budget and the §4 envelope validation.
    func placeholderDescriptorItems() -> [KitMediaMessageV2Descriptor.Item] {
        items.enumerated().map { $0.element.descriptorItem(placeholderIndex: $0.offset) }
    }

    /// The decoded-state gate. Synthesized Codable admits whatever bytes were persisted —
    /// duplicate or non-canonical ids, malformed key material, torn upload triples — and a
    /// throwing decode here would instead reset the entire protected state (`decodeIfPresent`
    /// re-throws corruption; only absence is tolerated). So damage is contained per message:
    /// every consumer must pass this gate before touching any cache key, key material, or
    /// upload field, and retires the one message visibly when it fails.
    var isStructurallyValid: Bool {
        guard KitMediaMessageV2Descriptor(
            items: placeholderDescriptorItems(),
            caption: caption
        ) != nil else { return false }
        if let caption, KitMediaMessageFamilyPolicy.blocksUserAuthoredText(caption) {
            return false
        }
        var cacheKeys = Set<String>()
        for item in items {
            // A torn upload triple must read as damage, never as "retry this upload".
            let staged = [
                item.storageKey != nil,
                item.ciphertextByteSize != nil,
                item.ciphertextSHA256 != nil,
            ]
            guard staged.allSatisfy({ $0 == staged[0] }),
                  KitMediaMessageV2Descriptor.isCanonicalUUID(item.localStorageKey),
                  cacheKeys.insert(item.localStorageKey).inserted
            else { return false }
            if let storageKey = item.storageKey {
                guard cacheKeys.insert(storageKey).inserted else { return false }
            }
        }
        return true
    }

    /// A canonical lowercase UUID, 36 encoded bytes like every real storage key, and disjoint
    /// per index so the descriptor's storage-key uniqueness rule holds pre-upload.
    static func placeholderStorageKey(forIndex index: Int) -> String {
        let tail = String(format: "%012d", max(0, index) % 1_000_000_000_000)
        return "00000000-0000-4000-8000-\(tail)"
    }

    /// 64 lowercase hex zeros — the exact encoded width of any real digest.
    static let placeholderCiphertextSHA256 = String(repeating: "0", count: 64)
}
