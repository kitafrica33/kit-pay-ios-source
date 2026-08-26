import Foundation

/// The hand-off between the iOS share sheet and Kit Pay.
///
/// Kit Pay now appears wherever iOS offers "share to", so a photo in Photos, a PDF in Files, or a
/// clip in another app can be sent to a chat without going back to Kit Pay and finding the file
/// again. The share extension cannot send anything itself — it has no access to the account's
/// keys and it must not — so it does the one thing it is allowed to do: it copies what the user
/// picked into the app group container and steps aside. The app picks it up, asks who it is for,
/// and stages it in that chat's composer exactly as if the user had attached it there.
///
/// Everything staged here is plaintext the user has just chosen to send, so it is written with
/// complete file protection and deleted the moment it has been staged. A batch nobody ever
/// delivered is not kept: ``SharedInboxPolicy/retention`` retires it on the next launch.
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
struct SharedInboxItem: Codable, Identifiable, Equatable {
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
struct SharedInboxBatch: Codable, Identifiable, Equatable {
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

    init(
        id: UUID,
        ownerAccountID: String,
        receivedAt: Date,
        items: [SharedInboxItem],
        text: String? = nil
    ) {
        self.id = id
        self.ownerAccountID = ownerAccountID
        self.receivedAt = receivedAt
        self.items = items
        self.text = text
    }

    /// True when there is something for a chat to receive.
    var isDeliverable: Bool { !items.isEmpty || !(text ?? "").isEmpty }
}

/// A share that has been given a destination and is on its way to that chat's composer.
struct SharedInboxDelivery: Identifiable, Equatable {
    let id = UUID()
    let conversationID: String
    let batch: SharedInboxBatch
}

/// The link the share extension opens to bring Kit Pay forward once a share is staged.
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

/// The rules both sides of the hand-off agree on. Pure, so the app can test what the extension
/// will do without running the extension.
enum SharedInboxPolicy {
    /// Same hard cap as any other attachment (`SecureMediaAttachmentCipher.maximumPlaintextBytes`).
    /// Pinned to that constant by `SharedInboxTests`; the extension cannot see it directly, because
    /// the messaging wire is not compiled into the extension.
    static let maximumBytes = 200 * 1_024 * 1_024

    /// Matches `ConversationAttachmentStagingPolicy.maximumStagedAttachments`, so a share that the
    /// extension accepted is always a share the composer can hold.
    static let maximumItems = 8

    /// An undelivered share is a file the user has forgotten about. It goes.
    static let retention: TimeInterval = 24 * 60 * 60

    static let fallbackMediaType = "application/octet-stream"

    static func canonicalAccountID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = UUID(uuidString: trimmed) else { return nil }
        return value.uuidString.lowercased()
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
        let trimmed = (suggestedName ?? "")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\0"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return String(trimmed.prefix(120)) }
        if mediaType.hasPrefix("image/") { return "Photo" }
        if mediaType.hasPrefix("video/") { return "Video" }
        if mediaType.hasPrefix("audio/") { return "Audio" }
        return "Document"
    }

    /// The longest shared text Kit Pay will carry into the composer. Long enough for a link and a
    /// sentence about it, short enough that a whole document pasted as "text" is not silently
    /// turned into a message.
    static let maximumTextCharacters = 4_000

    static func normalizedText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumTextCharacters))
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

    private struct AccountBinding: Codable {
        let accountID: String
    }

    var rootURL: URL? {
        containerURL?.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    private var accountBindingURL: URL? {
        containerURL?.appendingPathComponent(Self.accountBindingName, isDirectory: false)
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
        guard let accountBindingURL else { return }
        try? fileManager.removeItem(at: accountBindingURL)
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
        batchID: UUID
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
        receivedAt: Date
    ) throws {
        guard let rootURL else { throw SharedInboxError.unavailable }
        guard let ownerAccountID = SharedInboxPolicy.canonicalAccountID(rawOwnerAccountID)
        else { throw SharedInboxError.signedOut }
        let normalizedText = SharedInboxPolicy.normalizedText(text)
        guard !items.isEmpty || normalizedText != nil else {
            remove(batchID: id)
            throw SharedInboxError.empty
        }
        guard items.count <= SharedInboxPolicy.maximumItems,
              Set(items.map(\.id)).count == items.count,
              Set(items.map(\.fileName)).count == items.count,
              items.allSatisfy({
                  SharedInboxPolicy.isSafeFileName($0.fileName)
                      && SharedInboxPolicy.fits($0.byteCount)
              })
        else {
            remove(batchID: id)
            throw SharedInboxError.unreadable
        }
        let batch = SharedInboxBatch(
            id: id,
            ownerAccountID: ownerAccountID,
            receivedAt: receivedAt,
            items: items,
            text: normalizedText
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(batch)
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
        return batches.sorted { $0.receivedAt < $1.receivedAt }
    }

    func data(for item: SharedInboxItem, in batchID: UUID) throws -> Data {
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
        return try Data(contentsOf: url)
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
              batch.isDeliverable,
              batch.items.count <= SharedInboxPolicy.maximumItems,
              batch.items.allSatisfy({
                  SharedInboxPolicy.isSafeFileName($0.fileName)
                      && SharedInboxPolicy.fits($0.byteCount)
              })
        else { return nil }
        return batch
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
    case empty
    case unreadable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Kit Pay could not open its shared storage. Try sharing again."
        case .signedOut:
            "Open Kit Pay and sign in before sharing to a chat."
        case .tooLarge:
            "Files up to \(SharedInboxPolicy.maximumBytes / (1_024 * 1_024)) MB can be shared to Kit Pay."
        case .empty:
            "Nothing in that share could be sent through Kit Pay."
        case .unreadable:
            "That shared file could no longer be read."
        }
    }
}
