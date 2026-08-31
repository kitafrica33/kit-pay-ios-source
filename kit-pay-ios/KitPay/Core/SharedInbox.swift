import Foundation

/// The hand-off between the iOS share sheet and Kit Pay.
///
/// Kit Pay now appears wherever iOS offers "share to", so a photo in Photos, a PDF in Files, or a
/// clip in another app can be sent to a chat without going back to Kit Pay and finding the file
/// again. The share extension cannot send anything itself — it has no access to the account's
/// keys and it must not — so it does the one thing it is allowed to do: it copies what the user
/// picked into the app group container and steps aside. A protected, account-bound snapshot lets
/// the extension ask who it is for without opening the app or reading its keys. The app later
/// revalidates that requested route and stages it in the chat's composer exactly as if the user had
/// attached it there.
///
/// Everything staged here is plaintext the user has just chosen to send, so it is written with
/// complete file protection and deleted only after every chosen item has reached the durable
/// local outbox (or the customer explicitly discards it). A batch nobody ever delivered is not
/// kept: ``SharedInboxPolicy/retention`` retires it on the next launch.
enum KitAppGroup {
    /// Must match the `com.apple.security.application-groups` entitlement on BOTH the app and the
    /// share extension. Without it the extension's container is private and the hand-off silently
    /// writes to a directory the app cannot read.
    static let identifier = "group.africa.kit.pay.ios"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

/// One file the user shared into Kit Pay.
struct SharedInboxItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// Name of the file inside the batch directory. Never a path.
    let fileName: String
    /// Wire MIME type, already normalized by ``SharedInboxPolicy/normalizedMediaType(_:)``.
    let mediaType: String
    /// What the composer chip should call it — the original filename for documents.
    let displayName: String
    let byteCount: Int
}

/// Everything one trip through the share sheet produced.
struct SharedInboxBatch: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// The account that owned the app when the share was created. Without this binding, plaintext
    /// staged before sign-out could be offered to the next person who signs in on the device.
    let ownerAccountID: String
    let receivedAt: Date
    let items: [SharedInboxItem]
    /// A shared link or selection of text. Safari and Notes hand over text rather than a file, and
    /// a link saved as a `.txt` attachment would be useless to the person receiving it — so text
    /// lands in the composer, as the message, where the user can add to it before sending.
    let text: String?
    /// A destination chosen inside the extension. It is only a requested route: the containing
    /// app revalidates it against protected current conversation/contact state before staging.
    let destination: SharedInboxDestinationRequest?

    init(
        id: UUID,
        ownerAccountID: String,
        receivedAt: Date,
        items: [SharedInboxItem],
        text: String? = nil,
        destination: SharedInboxDestinationRequest? = nil
    ) {
        self.id = id
        self.ownerAccountID = ownerAccountID
        self.receivedAt = receivedAt
        self.items = items
        self.text = text
        self.destination = destination
    }

    /// True when there is something for a chat to receive.
    var isDeliverable: Bool { !items.isEmpty || !(text ?? "").isEmpty }
}

/// The requested route persisted with a staged share.
struct SharedInboxDestinationRequest: Codable, Equatable, Sendable {
    let kind: SharedInboxDestination.Kind
    let conversationID: String?
    let recipientUserID: String?
    let displayName: String
}

/// One safe-to-display row published by the containing app for the extension's picker.
///
/// The snapshot intentionally contains only presentation text, a validated public avatar address,
/// and opaque routing UUIDs. It never contains phone numbers, a group roster, authentication
/// material, encryption keys, message history, or avatar bytes. The address is optional so the
/// extension always has its generated person/group fallback while offline.
struct SharedInboxDestination: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case direct
        case group
        case contact
    }

    let conversationID: String?
    let recipientUserID: String?
    let displayName: String
    let kind: Kind
    let memberCount: Int?
    let avatarURL: String?
    /// Optional only for backward decoding of snapshots written before the combined Recent
    /// section existed. New snapshots always write true/false explicitly.
    let isRecent: Bool?

    init(
        conversationID: String?,
        recipientUserID: String?,
        displayName: String,
        kind: Kind,
        memberCount: Int?,
        avatarURL: String? = nil,
        isRecent: Bool = false
    ) {
        self.conversationID = conversationID
        self.recipientUserID = recipientUserID
        self.displayName = displayName
        self.kind = kind
        self.memberCount = memberCount
        self.avatarURL = avatarURL
        self.isRecent = isRecent
    }

    var id: String {
        if let conversationID { return "conversation:\(conversationID)" }
        return "contact:\(recipientUserID ?? "invalid")"
    }

    var request: SharedInboxDestinationRequest {
        SharedInboxDestinationRequest(
            kind: kind,
            conversationID: conversationID,
            recipientUserID: recipientUserID,
            displayName: displayName
        )
    }
}

/// Account-bound recipient directory consumed by the share extension while the app is suspended.
struct SharedInboxDestinationSnapshot: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let version: Int
    let ownerAccountID: String
    let generatedAt: Date
    let destinations: [SharedInboxDestination]

    init(
        ownerAccountID: String,
        generatedAt: Date,
        destinations: [SharedInboxDestination]
    ) {
        version = Self.schemaVersion
        self.ownerAccountID = ownerAccountID
        self.generatedAt = generatedAt
        self.destinations = destinations
    }
}

/// A share that has been given a destination and is on its way to that chat's composer.
struct SharedInboxDelivery: Identifiable, Equatable, Sendable {
    let id = UUID()
    let conversationID: String
    let batch: SharedInboxBatch
}

/// The no-payload link the share extension opens to bring Kit Pay forward once a share is queued.
///
/// Deliberately not a ``KitDeepLink``: that type only ever selects a pre-authentication screen and
/// refuses anything else, and a share must not widen it. This URL carries no payload at all — it
/// only says "look in the inbox", and the inbox is in our own container.
enum KitShareHandoffLink {
    static let url = URL(string: "kitwallet://share")

    static func matches(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "kitwallet" && url.host?.lowercased() == "share"
    }
}

/// What the share sheet does next while walking a queued batch into the host app.
///
/// `extensionContext.open` is best-effort from a share extension: iOS may decline it, answer
/// late, or never answer at all during a transition. These transitions encode the contract the
/// controller follows — complete the extension only after iOS accepts the open (completing first
/// tears the process down and races, usually beating, the open request), resolve a missing
/// answer through a timeout, keep the sheet alive for an explicit user-initiated retry, and
/// treat "Not now" as safe because the batch is already durable. An acceptance that arrives
/// after the timeout already resolved the attempt is ignored: the sheet is showing the manual
/// hand-off by then, and completing underneath it would dismiss UI the customer may be reading.
/// Pure, so `SharedInboxTests` drives every path without UIKit or a live extension context.
enum KitShareHandoffAttempt {
    /// `queued`: the batch is durable and no open is in flight. `opening`: `open(_:)` was issued
    /// and its completion or the timeout is pending. `finished`: the extension request completed.
    enum Phase: Equatable {
        case queued
        case opening
        case finished
    }

    enum Event: Equatable {
        /// The automatic post-publish attempt or the customer's explicit retry; `canOpen` is
        /// whether a hand-off URL and extension context are actually available.
        case attemptRequested(canOpen: Bool)
        /// iOS answered the open request, or the timeout resolved it as declined.
        case openResolved(opened: Bool)
        case notNowTapped
    }

    enum Decision: Equatable {
        case ignore
        /// Issue `extensionContext.open` and start the timeout.
        case attemptOpen
        /// Keep the sheet alive showing the queued state with retry and "Not now".
        case offerManualHandoff
        /// Only now is it safe to complete the extension request.
        case finishExtension
    }

    /// An open with no answer by now is treated as declined, rather than leaving the customer
    /// staring at an endless spinner if SpringBoard fails to answer during a transition.
    static let openTimeout: TimeInterval = 4

    static func decide(phase: Phase, event: Event) -> (phase: Phase, decision: Decision) {
        switch (phase, event) {
        case (.finished, _):
            return (.finished, .ignore)
        case (.queued, .attemptRequested(canOpen: true)):
            return (.opening, .attemptOpen)
        case (.queued, .attemptRequested(canOpen: false)):
            return (.queued, .offerManualHandoff)
        case (.opening, .attemptRequested):
            return (.opening, .ignore)
        case (.opening, .openResolved(opened: true)):
            return (.finished, .finishExtension)
        case (.opening, .openResolved(opened: false)):
            return (.queued, .offerManualHandoff)
        case (.queued, .openResolved):
            return (.queued, .ignore)
        case (.queued, .notNowTapped):
            return (.finished, .finishExtension)
        case (.opening, .notNowTapped):
            return (.opening, .ignore)
        }
    }
}

/// The rules both sides of the hand-off agree on. Pure, so the app can test what the extension
/// will do without running the extension.
enum SharedInboxPolicy {
    /// Same hard cap as any other attachment (`SecureMediaAttachmentCipher.maximumPlaintextBytes`).
    /// Pinned to that constant by `SharedInboxTests`; the extension cannot see it directly, because
    /// the messaging wire is not compiled into the extension.
    static let maximumBytes = 200 * 1_024 * 1_024

    /// The composer currently materializes a batch while preparing previews and encrypted local
    /// queue records. Keep the whole handoff within the same bound as one supported attachment;
    /// otherwise eight individually valid 200 MiB files could transiently require well over a
    /// gigabyte and be terminated by iOS before any bubble appears.
    static let maximumBatchBytes = maximumBytes

    /// Keep abandoned plaintext shares bounded even when the containing app is not opened for a
    /// while. Existing confirmed shares win over a newer share: silently evicting something the
    /// extension already told the customer was queued would be data loss.
    static let maximumPendingBatches = 4
    static let maximumRetainedBytes = 400 * 1_024 * 1_024

    /// Matches `ConversationAttachmentStagingPolicy.maximumStagedAttachments`, so a share that the
    /// extension accepted is always a share the composer can hold.
    static let maximumItems = 8

    /// A bounded snapshot keeps extension decoding predictable even if local shared storage is
    /// corrupt. Most people have far fewer chats; the most recently active rows are retained.
    static let maximumDestinations = 500
    static let maximumRecentDestinations = 5
    static let maximumDestinationSnapshotBytes = 1 * 1_024 * 1_024

    /// Destination names remain useful while offline, but an old roster should not live forever.
    /// The containing app still validates a selected ID against protected current state, so a
    /// stale row can never authorize delivery to a conversation the account no longer has.
    static let destinationSnapshotRetention: TimeInterval = 30 * 24 * 60 * 60

    static let maximumDestinationNameCharacters = 120
    static let maximumDestinationAvatarURLCharacters = 2_048

    /// ImageIO normally downsamples without decoding a full-size bitmap, but an extension-provided
    /// source can still make CoreGraphics allocate aggressively while parsing. Larger images stay
    /// fully shareable as documents instead of risking a jetsam termination in the containing app.
    static let maximumImageDecodeBytes = 64 * 1_024 * 1_024

    /// An undelivered share is a file the user has forgotten about. It goes.
    static let retention: TimeInterval = 24 * 60 * 60

    static let fallbackMediaType = "application/octet-stream"

    static func canonicalAccountID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = UUID(uuidString: trimmed) else { return nil }
        return value.uuidString.lowercased()
    }

    static func canonicalConversationID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = UUID(uuidString: trimmed) else { return nil }
        return value.uuidString.lowercased()
    }

    static func destinationDisplayName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let withoutControls = raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let collapsed = String(String.UnicodeScalarView(withoutControls))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumDestinationNameCharacters))
    }

    /// Avatar addresses are public presentation data, but still arrive from an untrusted server
    /// projection by the time the extension reads them. Keep credentials, fragments, non-HTTPS
    /// schemes, and unbounded strings out of the app-group snapshot and extension URLSession.
    static func destinationAvatarURL(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= maximumDestinationAvatarURLCharacters,
              let url = URL(string: trimmed),
              url.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil,
              url.fragment == nil
        else { return nil }
        return url.absoluteString
    }

    static func isValidDestination(_ destination: SharedInboxDestination) -> Bool {
        let conversationID = destination.conversationID.flatMap {
            canonicalConversationID($0)
        }
        let recipientUserID = destination.recipientUserID.flatMap { canonicalAccountID($0) }
        guard conversationID == destination.conversationID,
              recipientUserID == destination.recipientUserID,
              destinationDisplayName(destination.displayName) == destination.displayName,
              destination.avatarURL == nil
                || destinationAvatarURL(destination.avatarURL) == destination.avatarURL,
              destination.kind != .contact || destination.isRecent != true
        else { return false }
        switch destination.kind {
        case .direct:
            return conversationID != nil && recipientUserID != nil && destination.memberCount == nil
        case .group:
            guard conversationID != nil,
                  recipientUserID == nil,
                  let memberCount = destination.memberCount
            else { return false }
            return (2 ... 1_024).contains(memberCount)
        case .contact:
            return conversationID == nil
                && recipientUserID != nil
                && destination.memberCount == nil
        }
    }

    static func isValidDestinationRequest(_ request: SharedInboxDestinationRequest) -> Bool {
        isValidDestination(SharedInboxDestination(
            conversationID: request.conversationID,
            recipientUserID: request.recipientUserID,
            displayName: request.displayName,
            kind: request.kind,
            memberCount: request.kind == .group ? 2 : nil,
            avatarURL: nil,
            isRecent: false
        ))
    }

    /// Revalidates an extension route against the app's protected current conversation. A forged
    /// identifier cannot turn a direct recipient into a group (or vice versa), and a stale group
    /// from which the account was removed no longer qualifies.
    static func destinationRequest(
        _ request: SharedInboxDestinationRequest,
        matchesConversationID rawConversationID: String,
        isGroup: Bool,
        participantUserIDs: [String],
        currentAccountID rawCurrentAccountID: String
    ) -> Bool {
        guard isValidDestinationRequest(request),
              let conversationID = canonicalConversationID(rawConversationID),
              request.conversationID == conversationID,
              let currentAccountID = canonicalAccountID(rawCurrentAccountID)
        else { return false }
        let canonicalParticipants = participantUserIDs.compactMap { canonicalAccountID($0) }
        let participants = Set(canonicalParticipants)
        guard canonicalParticipants.count == participantUserIDs.count,
              participants.count == participantUserIDs.count,
              participants.contains(currentAccountID)
        else { return false }
        switch request.kind {
        case .group:
            return isGroup && participants.count >= 2
        case .direct:
            guard !isGroup, let recipientUserID = request.recipientUserID else { return false }
            return participants == Set([currentAccountID, recipientUserID])
        case .contact:
            return false
        }
    }

    /// Five chats by activity, then every other eligible Kit Pay contact and group alphabetically.
    /// A direct chat in the recent section suppresses its duplicate contact row. A recent group is
    /// likewise not repeated in the final group section.
    static func orderedDestinations(
        recentCandidates: [(destination: SharedInboxDestination, updatedAt: Date)],
        contacts: [SharedInboxDestination]
    ) -> [SharedInboxDestination] {
        let orderedConversations = recentCandidates
            .filter { $0.destination.kind != .contact && isValidDestination($0.destination) }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.destination.id < $1.destination.id
            }
        let recent = orderedConversations
            .prefix(maximumRecentDestinations)
            .map { candidate in
                let destination = candidate.destination
                return SharedInboxDestination(
                    conversationID: destination.conversationID,
                    recipientUserID: destination.recipientUserID,
                    displayName: destination.displayName,
                    kind: destination.kind,
                    memberCount: destination.memberCount,
                    avatarURL: destination.avatarURL,
                    isRecent: true
                )
            }
        var seenRecipientIDs = Set(recent.compactMap(\.recipientUserID))
        let recentConversationIDs = Set(recent.compactMap(\.conversationID))
        let sortedContacts = contacts
            .filter {
                $0.kind == .contact
                    && isValidDestination($0)
            }
            .sorted {
                let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return $0.id < $1.id
            }
        var otherContacts: [SharedInboxDestination] = []
        for contact in sortedContacts {
            guard let recipientUserID = contact.recipientUserID,
                  seenRecipientIDs.insert(recipientUserID).inserted
            else { continue }
            otherContacts.append(contact)
        }
        let otherGroups = orderedConversations
            .map(\.destination)
            .filter {
                $0.kind == .group
                    && $0.conversationID.map { !recentConversationIDs.contains($0) } == true
            }
            .sorted {
                let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return $0.id < $1.id
            }
        return Array((recent + otherContacts + otherGroups).prefix(maximumDestinations))
    }

    static func destinationSnapshotIsExpired(generatedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(generatedAt) >= destinationSnapshotRetention
            || generatedAt.timeIntervalSince(now) > destinationSnapshotRetention
    }

    /// The media types the encrypted wire accepts. Duplicated from
    /// `SecureMessagingWire.allowedAttachmentMediaTypes` because the extension must stay small;
    /// `SharedInboxTests` fails if the two ever drift apart.
    static let allowedMediaTypes: Set<String> = [
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

    /// What a shared file will travel as.
    ///
    /// Images are the exception to the allowlist: the app re-encodes every shared image to JPEG
    /// before it is staged, so a camera-native HEIC is kept as an image here rather than being
    /// demoted to an opaque document the recipient cannot preview. Anything else the wire does not
    /// accept is sent as a document, which is lossless and always works.
    static func normalizedMediaType(_ raw: String?) -> String {
        let normalized = (raw ?? "")
            .components(separatedBy: ";")[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return fallbackMediaType }
        if allowedMediaTypes.contains(normalized) { return normalized }
        if normalized.hasPrefix("image/") { return normalized }
        return fallbackMediaType
    }

    static func fits(_ byteCount: Int) -> Bool {
        byteCount > 0 && byteCount <= maximumBytes
    }

    static func batchFits(_ items: [SharedInboxItem]) -> Bool {
        var total = 0
        for item in items {
            let (next, overflow) = total.addingReportingOverflow(item.byteCount)
            guard !overflow, next <= maximumBatchBytes else { return false }
            total = next
        }
        return true
    }

    static func payloadByteCount(_ batch: SharedInboxBatch) -> Int {
        batch.items.reduce(0) { $0 + $1.byteCount }
    }

    /// The oldest confirmed prefix that fits the retained-inbox limits. Once one batch no longer
    /// fits, every newer batch is discarded too; this is deliberately newest-first pruning rather
    /// than cherry-picking small recent shares ahead of an older share already promised to the
    /// customer.
    static func retainedPrefix(_ batches: [SharedInboxBatch]) -> [SharedInboxBatch] {
        let ordered = batches.sorted {
            if $0.receivedAt != $1.receivedAt { return $0.receivedAt < $1.receivedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        var retained: [SharedInboxBatch] = []
        var retainedBytes = 0
        for batch in ordered {
            guard retained.count < maximumPendingBatches else { break }
            let batchBytes = payloadByteCount(batch)
            guard batchBytes <= maximumRetainedBytes - retainedBytes else { break }
            retained.append(batch)
            retainedBytes += batchBytes
        }
        return retained
    }

    static func shouldDecodeSharedImage(byteCount: Int) -> Bool {
        byteCount > 0 && byteCount <= maximumImageDecodeBytes
    }

    static func isExpired(receivedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(receivedAt) >= retention
            // A batch stamped in the future is a clock change, not a fresh share.
            || receivedAt.timeIntervalSince(now) > retention
    }

    /// A manifest is a file on disk, so it is read as untrusted input: a name that could climb out
    /// of the batch directory is refused rather than sanitized into something else.
    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty
            && name.count <= 255
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\\")
            && !name.contains("\0")
    }

    /// The filename a shared item is stored under: our own UUID plus the original extension, so a
    /// hostile name in another app's item provider never becomes a path in our container.
    static func storageFileName(id: UUID, suggestedName: String?) -> String {
        let ext = (suggestedName as NSString?)?.pathExtension.lowercased() ?? ""
        let safeExtension = ext.count <= 12 && ext.allSatisfy { $0.isLetter || $0.isNumber }
            ? ext
            : ""
        return safeExtension.isEmpty
            ? id.uuidString
            : "\(id.uuidString).\(safeExtension)"
    }

    /// What the composer chip and the destination picker call the file.
    static func displayName(suggestedName: String?, mediaType: String) -> String {
        let withoutUnsafeScalars = (suggestedName ?? "").unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet(charactersIn: "/\\:").contains(scalar)
                ? "-"
                : String(scalar)
        }.joined()
        let trimmed = withoutUnsafeScalars
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        if !trimmed.isEmpty {
            return String(trimmed.prefix(maximumDestinationNameCharacters))
        }
        if mediaType.hasPrefix("image/") { return "Photo" }
        if mediaType.hasPrefix("video/") { return "Video" }
        if mediaType.hasPrefix("audio/") { return "Audio" }
        return "Document"
    }

    /// The longest shared text Kit Pay will carry into the composer. Long enough for a link and a
    /// sentence about it, short enough that a whole document pasted as "text" is not turned into
    /// a message. Exceeding it fails the share visibly with shorten-and-retry guidance — the text
    /// is never silently cut to fit, because a truncated caption reads as something its author
    /// did not say.
    static let maximumTextCharacters = 4_000

    /// More providers than any legitimate handoff carries (eight files plus a text, a link, and
    /// a few mirrored representations). A bound on untrusted enumeration only: exceeding it fails
    /// the share visibly rather than silently choosing a subset to send.
    static let maximumEnumeratedProviders = 24

    /// The exact six caption-boundary scalars of the KITMEDIA2 contract: HT, LF, VT, FF, CR, SP.
    /// This restates `KitMediaMessageCaptionPolicy.boundaryScalars` because the share extension
    /// compiles this file but not the wire models; `SharedInboxTests` pins the two sets equal.
    /// Foundation's `.whitespacesAndNewlines` is wider — NBSP, U+0085, U+2028, U+2029 — and those
    /// scalars are contract-valid caption content, so no Foundation trim may ever touch shared
    /// text: the V2 queue applies the six-scalar normalization once, at seal, and nowhere earlier.
    static let captionBoundaryScalars: Set<Unicode.Scalar> = [
        "\u{0009}", "\u{000A}", "\u{000B}", "\u{000C}", "\u{000D}", "\u{0020}",
    ]

    /// True when `text` holds nothing a sealed caption could keep — it is empty or consists
    /// entirely of boundary scalars. This is the only emptiness test shared text is ever put to;
    /// text that passes it always travels byte-for-byte.
    static func carriesNoContent(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { captionBoundaryScalars.contains($0) }
    }

    /// Companion storage bound to `maximumTextCharacters`. `Character` counts graphemes, and one
    /// extended grapheme can chain thousands of scalars — a byte bound is what actually keeps the
    /// manifest allocation finite. Sized for a fully four-byte text (all emoji) at the character
    /// limit, so no legitimate share can hit the byte bound before the character one.
    static let maximumTextUTF8Bytes = 4 * maximumTextCharacters

    /// Exceeding either reading fails the share visibly; accepted text is never reshaped to fit.
    static func exceedsTextLimit(_ text: String) -> Bool {
        text.count > maximumTextCharacters || text.utf8.count > maximumTextUTF8Bytes
    }

    /// The text a share hands onward: nil when there is nothing to carry, otherwise the source
    /// app's string exactly as provided. No trimming and no truncation happen here — a caption's
    /// bytes must survive unchanged into the composer so the V2 queue can apply the one permitted
    /// normalization at seal, and over-limit text must stay visible and fail with edit guidance
    /// rather than be quietly shortened.
    static func carriedText(_ raw: String?) -> String? {
        guard let raw, !carriesNoContent(raw) else { return nil }
        return raw
    }

    /// Mirrors how the conversation composer appends shared text, and gives the explicit
    /// re-route action a conservative inverse. If the customer edited inside the inserted span we
    /// return nil rather than guessing at, and possibly deleting, their words. The existing draft
    /// rides byte-for-byte — no Foundation trim, which would mutate contract-valid NBSP/U+0085/
    /// U+2028/U+2029 the customer already typed — and is replaced outright only when it carries
    /// no content at all under the contract's own six-scalar test.
    static func composerDraft(existingDraft: String, sharedText: String) -> String {
        if draft(existingDraft, containsSharedTextBlock: sharedText) {
            return existingDraft
        }
        if carriesNoContent(existingDraft) { return sharedText }
        return "\(existingDraft)\n\(sharedText)"
    }

    private static func draft(_ draft: String, containsSharedTextBlock sharedText: String) -> Bool {
        draft == sharedText
            || draft.hasPrefix("\(sharedText)\n")
            || draft.contains("\n\(sharedText)\n")
            || draft.hasSuffix("\n\(sharedText)")
    }

    static func draftAfterRemovingShare(
        currentDraft: String,
        originalDraft: String,
        sharedText: String
    ) -> String? {
        if currentDraft == originalDraft { return currentDraft }
        let applied = composerDraft(existingDraft: originalDraft, sharedText: sharedText)
        if currentDraft == applied { return originalDraft }
        guard currentDraft.hasPrefix(applied) else { return nil }
        let suffix = currentDraft.dropFirst(applied.count)
        guard suffix.first?.isWhitespace == true else { return nil }
        return originalDraft + suffix
    }

    static func isValidItemMetadata(_ item: SharedInboxItem) -> Bool {
        guard isSafeFileName(item.fileName),
              fits(item.byteCount),
              normalizedMediaType(item.mediaType) == item.mediaType,
              displayName(suggestedName: item.displayName, mediaType: item.mediaType)
                == item.displayName
        else { return false }
        let ownName = item.id.uuidString
        return item.fileName == ownName || item.fileName.hasPrefix("\(ownName).")
    }

    /// The one line the destination picker shows above the chat list.
    static func summary(itemCount: Int, hasText: Bool) -> String {
        switch (itemCount, hasText) {
        case (0, true): "Text ready to send"
        case (0, false): "Nothing to send"
        case (1, false): "1 item ready to send"
        case (1, true): "1 item and text ready to send"
        case (_, false): "\(itemCount) items ready to send"
        default: "\(itemCount) items and text ready to send"
        }
    }
}

/// Reads and writes the app group hand-off directory. Used by the app and by the share extension,
/// which is why it depends on nothing but Foundation.
struct SharedInboxStore {
    static let shared = SharedInboxStore()

    private let fileManager = FileManager.default
    private let containerURL: URL?

    init(containerURL: URL? = KitAppGroup.containerURL) {
        self.containerURL = containerURL
    }

    private static let directoryName = "SharedInbox"
    private static let manifestName = "manifest.json"
    private static let accountBindingName = "SharedInbox.account.json"
    private static let destinationSnapshotName = "SharedInbox.destinations.json"

    private struct AccountBinding: Codable {
        let accountID: String
    }

    var rootURL: URL? {
        containerURL?.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    private var accountBindingURL: URL? {
        containerURL?.appendingPathComponent(Self.accountBindingName, isDirectory: false)
    }

    private var destinationSnapshotURL: URL? {
        containerURL?.appendingPathComponent(Self.destinationSnapshotName, isDirectory: false)
    }

    /// Publishes the signed-in account to the extension without exposing credentials or keys.
    /// The value is only an opaque UUID used to prevent cross-account delivery on a shared device.
    @discardableResult
    func setActiveAccountID(_ rawAccountID: String) -> Bool {
        guard let accountID = SharedInboxPolicy.canonicalAccountID(rawAccountID),
              let accountBindingURL,
              let data = try? JSONEncoder().encode(AccountBinding(accountID: accountID))
        else { return false }
        do {
            try data.write(to: accountBindingURL, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            return false
        }
    }

    /// The extension reads only this account boundary from the app group. It receives no token,
    /// local store, message key, wallet material, or session credential.
    func activeAccountID() -> String? {
        guard let accountBindingURL,
              let values = try? accountBindingURL.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              (1 ... 512).contains(size),
              let data = try? Data(contentsOf: accountBindingURL),
              let binding = try? JSONDecoder().decode(AccountBinding.self, from: data),
              let canonical = SharedInboxPolicy.canonicalAccountID(binding.accountID),
              canonical == binding.accountID
        else { return nil }
        return canonical
    }

    func clearActiveAccount() {
        if let accountBindingURL { try? fileManager.removeItem(at: accountBindingURL) }
        clearDestinations()
    }

    /// Publishes the app's latest ordered destination rows without publishing protected chat state.
    @discardableResult
    func setDestinations(
        _ destinations: [SharedInboxDestination],
        forAccountID rawAccountID: String,
        generatedAt: Date = Date()
    ) -> Bool {
        guard let ownerAccountID = SharedInboxPolicy.canonicalAccountID(rawAccountID),
              destinations.count <= SharedInboxPolicy.maximumDestinations,
              destinations.filter({ $0.isRecent == true }).count
                <= SharedInboxPolicy.maximumRecentDestinations,
              Set(destinations.map(\.id)).count == destinations.count,
              destinations.allSatisfy(SharedInboxPolicy.isValidDestination),
              let destinationSnapshotURL
        else { return false }
        let snapshot = SharedInboxDestinationSnapshot(
            ownerAccountID: ownerAccountID,
            generatedAt: generatedAt,
            destinations: destinations
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot),
              data.count <= SharedInboxPolicy.maximumDestinationSnapshotBytes
        else { return false }
        do {
            try data.write(
                to: destinationSnapshotURL,
                options: [.atomic, .completeFileProtection]
            )
            return true
        } catch {
            return false
        }
    }

    /// Reads an account-bound, bounded and fresh picker snapshot. Any malformed or cross-account
    /// file is destroyed instead of allowing one person's chat names to appear for another.
    func destinations(
        forAccountID rawAccountID: String,
        now: Date = Date()
    ) -> [SharedInboxDestination] {
        guard let accountID = SharedInboxPolicy.canonicalAccountID(rawAccountID),
              let destinationSnapshotURL,
              let values = try? destinationSnapshotURL.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              (1 ... SharedInboxPolicy.maximumDestinationSnapshotBytes).contains(size),
              let data = try? Data(contentsOf: destinationSnapshotURL)
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(
                  SharedInboxDestinationSnapshot.self,
                  from: data
              ),
              snapshot.version == SharedInboxDestinationSnapshot.schemaVersion,
              snapshot.ownerAccountID == accountID,
              !SharedInboxPolicy.destinationSnapshotIsExpired(
                  generatedAt: snapshot.generatedAt,
                  now: now
              ),
              snapshot.destinations.count <= SharedInboxPolicy.maximumDestinations,
              Set(snapshot.destinations.map(\.id)).count == snapshot.destinations.count,
              snapshot.destinations.allSatisfy(SharedInboxPolicy.isValidDestination)
        else {
            clearDestinations()
            return []
        }
        return snapshot.destinations
    }

    func clearDestinations() {
        guard let destinationSnapshotURL else { return }
        try? fileManager.removeItem(at: destinationSnapshotURL)
    }

    // MARK: Writing (share extension)

    /// Copies one shared file into a batch directory. The manifest is written last, by
    /// ``finishBatch(id:items:)``, so a batch interrupted half way through is never delivered.
    @discardableResult
    func stage(
        data: Data,
        suggestedName: String?,
        mediaType rawMediaType: String?,
        batchID: UUID
    ) throws -> SharedInboxItem {
        guard let rootURL else { throw SharedInboxError.unavailable }
        guard SharedInboxPolicy.fits(data.count) else {
            throw data.isEmpty ? SharedInboxError.unreadable : SharedInboxError.tooLarge
        }
        let mediaType = SharedInboxPolicy.normalizedMediaType(rawMediaType)
        let id = UUID()
        let fileName = SharedInboxPolicy.storageFileName(id: id, suggestedName: suggestedName)
        let batchURL = try secureBatchURL(rootURL: rootURL, batchID: batchID)
        try data.write(
            to: batchURL.appendingPathComponent(fileName, isDirectory: false),
            options: [.atomic, .completeFileProtection]
        )
        return SharedInboxItem(
            id: id,
            fileName: fileName,
            mediaType: mediaType,
            displayName: SharedInboxPolicy.displayName(
                suggestedName: suggestedName,
                mediaType: mediaType
            ),
            byteCount: data.count
        )
    }

    /// Copies a shared file into a batch directory without reading it into memory.
    ///
    /// A share extension is given a fraction of an app's memory budget, and the files people share
    /// are videos. `Data(contentsOf:)` on a 200 MB clip is a crash, not an error, so the bytes go
    /// straight from one file to the other and only the size is ever inspected.
    @discardableResult
    func stage(
        fileAt sourceURL: URL,
        suggestedName: String?,
        mediaType rawMediaType: String?,
        batchID: UUID,
        maximumAcceptedBytes: Int = SharedInboxPolicy.maximumBatchBytes
    ) throws -> SharedInboxItem {
        guard let rootURL else { throw SharedInboxError.unavailable }
        let sourceValues = try sourceURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true
        else { throw SharedInboxError.unreadable }
        let byteCount = sourceValues.fileSize ?? 0
        guard SharedInboxPolicy.fits(byteCount) else {
            throw byteCount > 0 ? SharedInboxError.tooLarge : SharedInboxError.unreadable
        }
        guard maximumAcceptedBytes > 0, byteCount <= maximumAcceptedBytes else {
            throw SharedInboxError.batchTooLarge
        }
        let mediaType = SharedInboxPolicy.normalizedMediaType(rawMediaType)
        let id = UUID()
        let name = suggestedName ?? sourceURL.lastPathComponent
        let fileName = SharedInboxPolicy.storageFileName(id: id, suggestedName: name)
        let batchURL = try secureBatchURL(rootURL: rootURL, batchID: batchID)
        let destination = batchURL.appendingPathComponent(fileName, isDirectory: false)
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
            // `copyItem` keeps the source's protection class, which for another app's temporary
            // directory may be weaker than ours. Failing to strengthen it is a failed share, not a
            // reason to leave plaintext at the weaker class.
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: destination.path
            )
            let copied = try destination.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard copied.isRegularFile == true,
                  copied.isSymbolicLink != true,
                  copied.fileSize == byteCount
            else { throw SharedInboxError.unreadable }
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        return SharedInboxItem(
            id: id,
            fileName: fileName,
            mediaType: mediaType,
            displayName: SharedInboxPolicy.displayName(
                suggestedName: name,
                mediaType: mediaType
            ),
            byteCount: byteCount
        )
    }

    /// Publishes a batch to the app. Nothing before this point is visible to it.
    func finishBatch(
        id: UUID,
        items: [SharedInboxItem],
        text: String?,
        ownerAccountID rawOwnerAccountID: String,
        receivedAt: Date,
        destination: SharedInboxDestinationRequest? = nil
    ) throws {
        guard let rootURL else { throw SharedInboxError.unavailable }
        guard let ownerAccountID = SharedInboxPolicy.canonicalAccountID(rawOwnerAccountID)
        else { throw SharedInboxError.signedOut }
        let carriedText = SharedInboxPolicy.carriedText(text)
        guard destination.map(SharedInboxPolicy.isValidDestinationRequest) ?? true else {
            remove(batchID: id)
            throw SharedInboxError.unreadable
        }
        guard !items.isEmpty || carriedText != nil else {
            remove(batchID: id)
            throw SharedInboxError.empty
        }
        // Over-limit text fails the whole share here, visibly, with the text still in the source
        // app. Cutting it to fit would publish words the customer never chose to send.
        if let carriedText, SharedInboxPolicy.exceedsTextLimit(carriedText) {
            remove(batchID: id)
            throw SharedInboxError.textTooLong
        }
        guard items.count <= SharedInboxPolicy.maximumItems,
              Set(items.map(\.id)).count == items.count,
              Set(items.map(\.fileName)).count == items.count,
              SharedInboxPolicy.batchFits(items),
              items.allSatisfy(SharedInboxPolicy.isValidItemMetadata)
        else {
            remove(batchID: id)
            throw SharedInboxError.unreadable
        }
        let batch = SharedInboxBatch(
            id: id,
            ownerAccountID: ownerAccountID,
            receivedAt: receivedAt,
            items: items,
            text: carriedText,
            destination: destination
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(batch)
        let confirmed = confirmedBatches(
            at: rootURL,
            ownerAccountID: ownerAccountID,
            excluding: id
        )
        let retainedBytes = confirmed.reduce(0) {
            $0 + SharedInboxPolicy.payloadByteCount($1)
        }
        let batchBytes = SharedInboxPolicy.payloadByteCount(batch)
        guard confirmed.count < SharedInboxPolicy.maximumPendingBatches,
              batchBytes <= SharedInboxPolicy.maximumRetainedBytes - retainedBytes
        else {
            remove(batchID: id)
            throw SharedInboxError.inboxFull
        }
        // A text-only share never created the directory, because nothing was copied into it.
        let batchURL = try secureBatchURL(rootURL: rootURL, batchID: id)
        for item in items {
            _ = try verifiedFileURL(for: item, batchURL: batchURL)
        }
        try data.write(
            to: batchURL.appendingPathComponent(Self.manifestName, isDirectory: false),
            options: [.atomic, .completeFileProtection]
        )
    }

    /// Atomically records the containing app's validated conversation before the composer can
    /// queue the first item. The caller supplies the exact batch it read; a stale process or view
    /// cannot overwrite a newer route. This makes a partially queued multi-item share recover to
    /// the same conversation after process death instead of returning to a free destination
    /// picker.
    func pinDestination(
        for batch: SharedInboxBatch,
        to destination: SharedInboxDestinationRequest
    ) throws -> SharedInboxBatch {
        guard destination.kind != .contact,
              SharedInboxPolicy.isValidDestinationRequest(destination),
              let rootURL
        else { throw SharedInboxError.unreadable }
        let batchURL = rootURL.appendingPathComponent(batch.id.uuidString, isDirectory: true)
        guard let current = decodeBatch(at: batchURL), current == batch else {
            throw SharedInboxError.unreadable
        }
        if current.destination == destination { return current }

        let pinned = SharedInboxBatch(
            id: current.id,
            ownerAccountID: current.ownerAccountID,
            receivedAt: current.receivedAt,
            items: current.items,
            text: current.text,
            destination: destination
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(pinned)
        try data.write(
            to: batchURL.appendingPathComponent(Self.manifestName, isDirectory: false),
            options: [.atomic, .completeFileProtection]
        )
        return pinned
    }

    // MARK: Reading (app)

    /// Every complete, unexpired batch, oldest first. Incomplete and stale batches are removed as
    /// they are found, so nothing the user abandoned lingers on disk.
    func pendingBatches(forAccountID rawAccountID: String, now: Date = Date()) -> [SharedInboxBatch] {
        guard let accountID = SharedInboxPolicy.canonicalAccountID(rawAccountID) else { return [] }
        guard let rootURL,
              let entries = try? fileManager.contentsOfDirectory(
                  at: rootURL,
                  includingPropertiesForKeys: nil
              )
        else { return [] }
        var batches: [SharedInboxBatch] = []
        for entry in entries {
            guard let batch = decodeBatch(at: entry), batch.ownerAccountID == accountID else {
                try? fileManager.removeItem(at: entry)
                continue
            }
            guard !SharedInboxPolicy.isExpired(receivedAt: batch.receivedAt, now: now) else {
                try? fileManager.removeItem(at: entry)
                continue
            }
            batches.append(batch)
        }
        let retained = SharedInboxPolicy.retainedPrefix(batches)
        let retainedIDs = Set(retained.map(\.id))
        for batch in batches where !retainedIDs.contains(batch.id) {
            try? fileManager.removeItem(
                at: rootURL.appendingPathComponent(batch.id.uuidString, isDirectory: true)
            )
        }
        return retained
    }

    func data(for item: SharedInboxItem, in batchID: UUID) throws -> Data {
        try Data(contentsOf: fileURL(for: item, in: batchID))
    }

    /// Validated file lease for the containing app's file-first adoption path. The inbox keeps
    /// ownership until the exact outbox commit is acknowledged; callers may copy, never move.
    func fileURL(for item: SharedInboxItem, in batchID: UUID) throws -> URL {
        guard let rootURL else { throw SharedInboxError.unavailable }
        guard SharedInboxPolicy.isSafeFileName(item.fileName) else {
            throw SharedInboxError.unreadable
        }
        let batchURL = rootURL.appendingPathComponent(batchID.uuidString, isDirectory: true)
        let batchValues = try batchURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard batchValues.isDirectory == true, batchValues.isSymbolicLink != true else {
            throw SharedInboxError.unreadable
        }
        let url = try verifiedFileURL(for: item, batchURL: batchURL)
        return url
    }

    func remove(batchID: UUID) {
        guard let rootURL else { return }
        try? fileManager.removeItem(
            at: rootURL.appendingPathComponent(batchID.uuidString, isDirectory: true)
        )
    }

    func removeAll() {
        guard let rootURL else { return }
        try? fileManager.removeItem(at: rootURL)
    }

    private func decodeBatch(at directory: URL) -> SharedInboxBatch? {
        guard let directoryValues = try? directory.resourceValues(
                  forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true,
              let id = UUID(uuidString: directory.lastPathComponent),
              let data = try? Data(
                  contentsOf: directory.appendingPathComponent(
                      Self.manifestName,
                      isDirectory: false
                  )
              )
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let batch = try? decoder.decode(SharedInboxBatch.self, from: data),
              batch.id == id,
              SharedInboxPolicy.canonicalAccountID(batch.ownerAccountID) == batch.ownerAccountID,
              batch.destination.map(SharedInboxPolicy.isValidDestinationRequest) ?? true,
              batch.isDeliverable,
              batch.items.count <= SharedInboxPolicy.maximumItems,
              Set(batch.items.map(\.id)).count == batch.items.count,
              Set(batch.items.map(\.fileName)).count == batch.items.count,
              SharedInboxPolicy.batchFits(batch.items),
              batch.items.allSatisfy(SharedInboxPolicy.isValidItemMetadata),
              // Persisted text must be exactly what `carriedText` would carry — content-bearing
              // and within the visible-failure limit. A doctored manifest cannot smuggle a
              // contentless or over-limit caption past the extension's checks.
              batch.text.map({
                  SharedInboxPolicy.carriedText($0) == $0
                      && !SharedInboxPolicy.exceedsTextLimit($0)
              }) ?? true
        else { return nil }
        return batch
    }

    private func confirmedBatches(
        at rootURL: URL,
        ownerAccountID: String,
        excluding excludedID: UUID
    ) -> [SharedInboxBatch] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return entries.compactMap { entry in
            guard entry.lastPathComponent != excludedID.uuidString,
                  let batch = decodeBatch(at: entry),
                  batch.ownerAccountID == ownerAccountID
            else { return nil }
            return batch
        }
    }

    private func secureBatchURL(rootURL: URL, batchID: UUID) throws -> URL {
        let batchURL = rootURL.appendingPathComponent(batchID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: batchURL, withIntermediateDirectories: true)
        let values = try batchURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw SharedInboxError.unreadable
        }
        return batchURL
    }

    private func verifiedFileURL(
        for item: SharedInboxItem,
        batchURL: URL
    ) throws -> URL {
        guard SharedInboxPolicy.isSafeFileName(item.fileName),
              SharedInboxPolicy.fits(item.byteCount)
        else { throw SharedInboxError.unreadable }
        let url = batchURL.appendingPathComponent(item.fileName, isDirectory: false)
        let values = try url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.fileSize == item.byteCount
        else { throw SharedInboxError.unreadable }
        return url
    }
}

enum SharedInboxError: LocalizedError, Equatable {
    case unavailable
    case signedOut
    case tooLarge
    case batchTooLarge
    case inboxFull
    case empty
    case unreadable
    case tooManyItems
    case textTooLong

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Kit Pay could not open its shared storage. Try sharing again."
        case .signedOut:
            "Open Kit Pay and sign in before sharing to a chat."
        case .tooLarge:
            "Files up to \(SharedInboxPolicy.maximumBytes / (1_024 * 1_024)) MB can be shared to Kit Pay."
        case .batchTooLarge:
            "A single share can include up to \(SharedInboxPolicy.maximumBatchBytes / (1_024 * 1_024)) MB in total."
        case .inboxFull:
            "Open Kit Pay to send or discard your earlier shared items, then try again."
        case .empty:
            "Nothing in that share could be sent through Kit Pay."
        case .unreadable:
            "That shared file could no longer be read."
        case .tooManyItems:
            "This share includes too many items. Kit Pay can send up to \(SharedInboxPolicy.maximumItems) files and their text in one message."
        case .textTooLong:
            "That text is too long to send as one message. Shorten it and share again."
        }
    }
}
