import CryptoKit
import Darwin
import Foundation

enum SecureMediaLocalFilePolicy {
    static func fileExtension(for mediaType: String) -> String {
        switch mediaType.lowercased() {
        case "image/jpeg": "jpg"
        case "image/png": "png"
        case "image/webp": "webp"
        case "image/gif": "gif"
        case "image/heic": "heic"
        case "image/heif": "heif"
        case "audio/mp4": "m4a"
        case "audio/aac": "aac"
        case "audio/mpeg": "mp3"
        case "audio/ogg": "ogg"
        case "video/mp4": "mp4"
        case "video/quicktime": "mov"
        case "video/webm": "webm"
        case "application/pdf": "pdf"
        case "application/zip": "zip"
        case "application/msword": "doc"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx"
        case "application/vnd.ms-excel": "xls"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx"
        case "application/vnd.ms-powerpoint": "ppt"
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx"
        case "text/plain": "txt"
        case "text/csv": "csv"
        default: "bin"
        }
    }

    static func isSafeFileExtension(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 8
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0)
            }
    }
}

/// Result of the cache's atomic non-overwriting duplicate. `conflict` means byte-different
/// content already lives under the destination key — the caller must fail closed, never
/// overwrite.
enum SecureMediaDuplicateOutcome: Equatable, Sendable {
    case stored
    case alreadyIdentical
    case conflict
    case sourceMissing
}

/// Result of the cache's atomic non-overwriting insert. `alreadyPresent` means some copy —
/// even an unreadable one — already lives under the key; it stays untouched and the caller
/// does not own it. `stored` means this call created the entry, which licenses exactly that
/// caller to remove it if its own revalidation fails. `rejected` covers what the cache
/// refuses to hold (non-UUID key, empty payload, unwritable or unverifiable destination).
enum SecureMediaInsertOutcome: Equatable, Sendable {
    case stored
    case alreadyPresent
    case rejected
}

struct SecureMediaCiphertextSpool: Equatable, Sendable {
    let fileURL: URL
    let byteSize: Int64
    let sha256Hex: String
    let plaintextByteSize: Int
}

struct SecureMediaProtectedFile: Equatable, Sendable {
    let fileURL: URL
    let byteSize: Int
    let insertion: SecureMediaInsertOutcome
}

enum SecureMediaCacheOwnership: Equatable, Sendable {
    case senderOriginal
    case receivedCache
}

/// One state-authorized file considered by receiver-cache eviction. Sender originals may be
/// supplied by a caller building a complete ownership graph, but are deliberately never eligible.
struct SecureMediaCacheEvictionCandidate: Equatable, Sendable {
    let messageID: UUID
    let conversationID: String
    let attachmentID: String
    let storageKey: String
    let expectedPlaintextByteCount: Int
    let storageKind: LocalMediaRecord.LocalStorageKind
    let ownership: SecureMediaCacheOwnership
    let lastAccessedAt: Date
}

struct SecureMediaCacheEvictionReservation: Equatable, Sendable {
    let id: UUID
    let candidates: [SecureMediaCacheEvictionCandidate]
    let bytesBeforeEviction: Int64
    let projectedBytesAfterEviction: Int64
}

/// Keeps an app-owned media URL out of receiver-cache eviction while a presentation object holds
/// it. Callers that discard the wrapper immediately still receive a short recent-access grace;
/// long-lived video/document views retain the wrapper for their complete presentation lifetime.
final class SecureMediaOriginalAccessLease: @unchecked Sendable {
    let fileURL: URL

    fileprivate let id: UUID
    fileprivate let accountID: String
    fileprivate let storageKey: String
    private let lock = NSLock()
    private var isReleased = false
    private let releaseAction: @Sendable (UUID, String, String) -> Void

    fileprivate init(
        fileURL: URL,
        id: UUID,
        accountID: String,
        storageKey: String,
        releaseAction: @escaping @Sendable (UUID, String, String) -> Void
    ) {
        self.fileURL = fileURL
        self.id = id
        self.accountID = accountID
        self.storageKey = storageKey
        self.releaseAction = releaseAction
    }

    fileprivate func claimRelease() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isReleased else { return false }
        isReleased = true
        return true
    }

    deinit {
        guard claimRelease() else { return }
        releaseAction(id, accountID, storageKey)
    }
}

/// Device-protected local store for chat media.
///
/// The single AES-GCM state file must stay small — every `SecureLocalStore.update` rewrites it in
/// full, so even a multi-megabyte video inline in `LocalMessage.attachmentData` would make each
/// wallet-balance tweak rewrite the blob. Downloaded/legacy `Data` values therefore live in a
/// ChaChaPoly-sealed file keyed by a device-only Keychain key. Large sender originals instead stay
/// file-backed under iOS Data Protection (`completeUntilFirstUserAuthentication`): AVFoundation and
/// Quick Look can open that original directly, so capture-to-playback never decrypts or copies a
/// 200 MB value through RAM. Both representations are account scoped and excluded from backups.
actor SecureMediaFileCache {
    static let shared = SecureMediaFileCache()

    private let rootDirectoryURL: URL
    private let keyAccountPrefix: String
    private var cachedKeys: [String: SymmetricKey] = [:]
    /// One bounded directory walk per account populates the legacy-extension index. Normal
    /// playback then resolves a media id in O(1) instead of enumerating the whole media library
    /// for every bubble. New writes update the index at publication time.
    private var originalURLIndex: [String: [String: Set<URL>]] = [:]
    private var indexedOriginalAccounts: Set<String> = []
    private var originalDirectoryScanCounts: [String: Int] = [:]
    /// A restart pays one full-file digest pass before trusting a resumable spool. Subsequent
    /// retries use this process-local lease only while path, size and modification time remain
    /// identical; every cache-owned mutation explicitly invalidates it.
    private struct VerifiedSpoolLease: Equatable {
        let fileURL: URL
        let byteSize: Int64
        let modificationDate: Date
        let sha256Hex: String
    }
    private var verifiedSpoolLeases: [String: VerifiedSpoolLease] = [:]
    private var spoolDigestVerificationCounts: [String: Int] = [:]
    private var activeOriginalLeases: [String: Set<UUID>] = [:]
    private var lastOriginalAccessDates: [String: Date] = [:]
    private var reservedEvictionKeys: Set<String> = []
    private struct EvictionReservationState {
        struct Entry {
            let storageKey: String
            let fileURL: URL
            let byteSize: Int64
            let modificationDate: Date
        }

        let accountID: String
        let entries: [Entry]
    }
    private var evictionReservations: [UUID: EvictionReservationState] = [:]

    init(directoryURL: URL? = nil, keyAccount: String = "kit-pay-media-cache-key-v1") {
        keyAccountPrefix = keyAccount
        if let directoryURL {
            rootDirectoryURL = directoryURL
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            rootDirectoryURL = base
                .appendingPathComponent("KitPay", isDirectory: true)
                .appendingPathComponent("media-cache", isDirectory: true)
        }
    }

    func store(_ data: Data, forStorageKey storageKey: String, userID: String) throws {
        guard let accountID = canonicalAccountID(userID),
              let fileURL = sealedFileURL(forStorageKey: storageKey, accountID: accountID),
              !data.isEmpty
        else { return }
        try ensureDirectory(for: accountID)
        let sealed = try ChaChaPoly.seal(data, using: encryptionKey(for: accountID))
        try sealed.combined.write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var excludedURL = fileURL
        try? excludedURL.setResourceValues(resourceValues)
    }

    func data(forStorageKey storageKey: String, userID: String) -> Data? {
        guard let accountID = canonicalAccountID(userID) else { return nil }
        let accessKey = cacheEntryKey(storageKey: storageKey, accountID: accountID)
        guard !reservedEvictionKeys.contains(accessKey) else { return nil }
        if let originalURL = originalFileURL(
            forStorageKey: storageKey,
            accountID: accountID
        ), regularFileByteCount(at: originalURL) != nil {
            guard let plaintext = try? Data(contentsOf: originalURL, options: [.mappedIfSafe])
            else { return nil }
            recordAccess(to: originalURL, storageKey: storageKey, accountID: accountID)
            return plaintext
        }
        guard let fileURL = sealedFileURL(forStorageKey: storageKey, accountID: accountID),
              let sealedData = try? Data(contentsOf: fileURL),
              let sealed = try? ChaChaPoly.SealedBox(combined: sealedData),
              let key = try? encryptionKey(for: accountID),
              let plaintext = try? ChaChaPoly.open(sealed, using: key)
        else { return nil }
        recordAccess(to: fileURL, storageKey: storageKey, accountID: accountID)
        return plaintext
    }

    /// Imports an already-file-backed capture/selection into the permanent local-original area.
    /// `moveSource` is used only for app-owned camera/editor scratch files and is normally a
    /// same-volume atomic rename. Security-scoped document sources are copied without ever being
    /// materialized as one `Data`. A canonical media id is immutable: an existing destination is
    /// accepted only when its cheap, durable size fact matches the caller's accepted source.
    func importProtectedOriginal(
        from sourceURL: URL,
        forStorageKey storageKey: String,
        userID: String,
        mediaType: String,
        expectedByteCount: Int,
        moveSource: Bool,
        requiresConstantTimeClone: Bool = false
    ) throws -> URL {
        guard expectedByteCount > 0,
              let accountID = canonicalAccountID(userID),
              let destination = originalFileURL(
                  forStorageKey: storageKey,
                  accountID: accountID,
                  mediaType: mediaType
              ),
              regularFileByteCount(at: sourceURL) == expectedByteCount
        else { throw CocoaError(.fileReadCorruptFile) }
        try ensureDirectory(for: accountID)
        // A permanent media id is immutable. Exact retries are accepted only after a bounded
        // byte-for-byte comparison; equal length is never treated as content authority.
        let exactExisting = FileManager.default.fileExists(atPath: destination.path)
            ? destination
            : nil
        if let existing = exactExisting
            ?? originalFileURL(forStorageKey: storageKey, accountID: accountID) {
            indexOriginalURL(existing, storageKey: storageKey, accountID: accountID)
            guard filesAreIdentical(sourceURL, existing) else {
                throw CocoaError(.fileWriteFileExists)
            }
            if moveSource, sourceURL.standardizedFileURL != existing.standardizedFileURL {
                try? FileManager.default.removeItem(at: sourceURL)
            }
            return existing
        }
        guard !FileManager.default.fileExists(
            atPath: sealedFileURL(forStorageKey: storageKey, accountID: accountID)?.path ?? ""
        ) else { throw CocoaError(.fileWriteFileExists) }

        let staging = accountDirectoryURL(for: accountID).appendingPathComponent(
            ".\(UUID().uuidString.lowercased()).importing",
            isDirectory: false
        )
        var sourceWasMoved = false
        do {
            if moveSource {
                do {
                    try FileManager.default.moveItem(at: sourceURL, to: staging)
                    sourceWasMoved = true
                } catch {
                    // A provider can hand back a file on another volume. Copying remains
                    // file-to-file and bounded-memory; remove the app-owned source only after
                    // the protected destination has been published successfully.
                    try FileManager.default.copyItem(at: sourceURL, to: staging)
                }
            } else if !cloneFile(sourceURL, to: staging) {
                // Shared-inbox files already live in Kit Pay's app group on the same APFS volume.
                // Their containing-app adoption is a strict latency boundary: if the filesystem
                // cannot make a copy-on-write clone, leave the durable inbox untouched for retry
                // instead of blocking the composer on a byte-for-byte copy.
                guard !requiresConstantTimeClone else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try FileManager.default.copyItem(at: sourceURL, to: staging)
            }
            try protectOriginal(at: staging)
            guard regularFileByteCount(at: staging) == expectedByteCount else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try FileManager.default.moveItem(at: staging, to: destination)
            try? excludeFromBackup(destination)
            indexOriginalURL(destination, storageKey: storageKey, accountID: accountID)
            if moveSource, !sourceWasMoved {
                try? FileManager.default.removeItem(at: sourceURL)
            }
            return destination
        } catch {
            if sourceWasMoved,
               FileManager.default.fileExists(atPath: staging.path),
               !FileManager.default.fileExists(atPath: sourceURL.path) {
                // Best-effort rollback keeps the only capture reachable by its caller. If the
                // rollback itself fails, leave the protected hidden scratch for recovery/sweep.
                try? FileManager.default.moveItem(at: staging, to: sourceURL)
            } else {
                try? FileManager.default.removeItem(at: staging)
            }
            throw error
        }
    }

    /// Direct playback/opening lease for a sender original. The URL is returned only when the
    /// current account/key resolves to one regular file of the exact persisted size.
    func protectedOriginalURL(
        forStorageKey storageKey: String,
        userID: String,
        expectedByteCount: Int
    ) -> URL? {
        guard let accountID = canonicalAccountID(userID),
              !reservedEvictionKeys.contains(
                  cacheEntryKey(storageKey: storageKey, accountID: accountID)
              ),
              let url = originalFileURL(forStorageKey: storageKey, accountID: accountID),
              regularFileByteCount(at: url) == expectedByteCount
        else { return nil }
        recordAccess(to: url, storageKey: storageKey, accountID: accountID)
        return url
    }

    /// Stronger form used by file-backed presentation. Reservation and lease acquisition happen
    /// in one actor step, so eviction cannot select the file between URL resolution and playback.
    func protectedOriginalLease(
        forStorageKey storageKey: String,
        userID: String,
        expectedByteCount: Int,
        now: Date = Date()
    ) -> SecureMediaOriginalAccessLease? {
        guard let accountID = canonicalAccountID(userID),
              let canonicalStorageKey = canonicalStorageKey(storageKey)
        else { return nil }
        let entryKey = cacheEntryKey(
            storageKey: canonicalStorageKey,
            accountID: accountID
        )
        guard !reservedEvictionKeys.contains(entryKey),
              let url = originalFileURL(
                  forStorageKey: canonicalStorageKey,
                  accountID: accountID
              ),
              regularFileByteCount(at: url) == expectedByteCount
        else { return nil }
        let leaseID = UUID()
        activeOriginalLeases[entryKey, default: []].insert(leaseID)
        recordAccess(
            to: url,
            storageKey: canonicalStorageKey,
            accountID: accountID,
            at: now
        )
        return SecureMediaOriginalAccessLease(
            fileURL: url,
            id: leaseID,
            accountID: accountID,
            storageKey: canonicalStorageKey
        ) { [weak self] id, releasedAccountID, releasedStorageKey in
            Task {
                await self?.releaseOriginalAccessLease(
                    id: id,
                    accountID: releasedAccountID,
                    storageKey: releasedStorageKey
                )
            }
        }
    }

    /// Deterministic release hook for owners that can explicitly finish a presentation and for
    /// tests. Deinitialization remains the safety net for ordinary SwiftUI lifetime management.
    func releaseProtectedOriginalLease(_ lease: SecureMediaOriginalAccessLease) {
        guard lease.claimRelease() else { return }
        releaseOriginalAccessLease(
            id: lease.id,
            accountID: lease.accountID,
            storageKey: lease.storageKey
        )
    }

    /// Reuses only a spool whose persisted digest and size still match the file. This is the
    /// restart path: metadata is committed to the encrypted state before upload starts, so a
    /// corrupt or half-written file can never be mistaken for resumable ciphertext.
    func ciphertextSpool(
        forStorageKey storageKey: String,
        userID: String,
        expectedByteCount: Int64,
        expectedSHA256: String
    ) async -> SecureMediaCiphertextSpool? {
        guard let accountID = canonicalAccountID(userID),
              SecureMessagingWirePolicy.isLowercaseSHA256(expectedSHA256),
              let url = ciphertextFileURL(forStorageKey: storageKey, accountID: accountID),
              let fingerprint = spoolFingerprint(
                  at: url,
                  byteSize: expectedByteCount,
                  sha256Hex: expectedSHA256
              )
        else { return nil }
        let leaseKey = spoolLeaseKey(storageKey: storageKey, accountID: accountID)
        if verifiedSpoolLeases[leaseKey] != fingerprint {
            spoolDigestVerificationCounts[leaseKey, default: 0] += 1
            let digest = await Task.detached(priority: .utility) {
                Self.sha256Hex(of: url)
            }.value
            // Hashing yields the cache actor so playback/cache metadata reads are never queued
            // behind a 200 MiB verification. Revalidate the complete fingerprint afterwards;
            // a file changed during the pass cannot acquire a lease.
            guard digest == expectedSHA256,
                  spoolFingerprint(
                      at: url,
                      byteSize: expectedByteCount,
                      sha256Hex: expectedSHA256
                  ) == fingerprint
            else {
                verifiedSpoolLeases.removeValue(forKey: leaseKey)
                return nil
            }
            verifiedSpoolLeases[leaseKey] = fingerprint
        }
        return SecureMediaCiphertextSpool(
            fileURL: url,
            byteSize: expectedByteCount,
            sha256Hex: expectedSHA256,
            plaintextByteSize: 0
        )
    }

    /// Deterministically encrypts a protected sender original into a durable, protected spool.
    /// Encryption itself is streaming and bounded; a hidden staging file is atomically renamed
    /// only after the complete frame, HMAC and SHA-256 have been finalized.
    func prepareCiphertextSpool(
        forStorageKey storageKey: String,
        userID: String,
        expectedPlaintextByteCount: Int,
        keyMaterial: Data,
        attachmentID: String
    ) async throws -> SecureMediaCiphertextSpool? {
        guard let accountID = canonicalAccountID(userID),
              let sourceURL = originalFileURL(
                  forStorageKey: storageKey,
                  accountID: accountID
              ),
              regularFileByteCount(at: sourceURL) == expectedPlaintextByteCount,
              let destination = ciphertextFileURL(
                  forStorageKey: attachmentID,
                  accountID: accountID
              )
        else { return nil }
        try ensureDirectory(for: accountID)
        // No state checkpoint means no existing spool is authoritative. Recreate it from the
        // immutable original and deterministic IV rather than trusting crash residue.
        verifiedSpoolLeases.removeValue(
            forKey: spoolLeaseKey(storageKey: attachmentID, accountID: accountID)
        )
        try? FileManager.default.removeItem(at: destination)
        let staging = accountDirectoryURL(for: accountID).appendingPathComponent(
            ".\(UUID().uuidString.lowercased()).encrypting",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: staging) }
        guard let sourceModificationDate = try sourceURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate else {
            throw SecureMediaAttachmentError.invalidMedia
        }
        let result = try await Task.detached(priority: .utility) {
            try SecureMediaAttachmentCipher.encryptFile(
                plaintextURL: sourceURL,
                ciphertextURL: staging,
                expectedPlaintextByteSize: expectedPlaintextByteCount,
                keyMaterial: keyMaterial,
                attachmentID: attachmentID
            )
        }.value
        try Task.checkCancellation()
        guard regularFileByteCount(at: sourceURL) == expectedPlaintextByteCount,
              try sourceURL.resourceValues(
                  forKeys: [.contentModificationDateKey]
              ).contentModificationDate == sourceModificationDate
        else { throw SecureMediaAttachmentError.invalidMedia }
        try protectOriginal(at: staging)
        try excludeFromBackup(staging)
        try FileManager.default.moveItem(at: staging, to: destination)
        if let fingerprint = spoolFingerprint(
            at: destination,
            byteSize: result.ciphertextByteSize,
            sha256Hex: result.ciphertextSHA256
        ) {
            verifiedSpoolLeases[
                spoolLeaseKey(storageKey: attachmentID, accountID: accountID)
            ] = fingerprint
        }
        return SecureMediaCiphertextSpool(
            fileURL: destination,
            byteSize: result.ciphertextByteSize,
            sha256Hex: result.ciphertextSHA256,
            plaintextByteSize: result.plaintextByteSize
        )
    }

    func ciphertextChunk(
        forStorageKey storageKey: String,
        userID: String,
        expectedByteCount: Int64,
        expectedSHA256: String,
        offset: Int64,
        maximumBytes: Int
    ) throws -> Data? {
        guard offset >= 0,
              offset < expectedByteCount,
              maximumBytes > 0,
              maximumBytes <= MessagingResumableAttachmentPolicy.maximumChunkBytes,
              SecureMessagingWirePolicy.isLowercaseSHA256(expectedSHA256),
              let accountID = canonicalAccountID(userID),
              let fileURL = ciphertextFileURL(
                  forStorageKey: storageKey,
                  accountID: accountID
              ),
              let fingerprint = spoolFingerprint(
                  at: fileURL,
                  byteSize: expectedByteCount,
                  sha256Hex: expectedSHA256
              ),
              verifiedSpoolLeases[
                  spoolLeaseKey(storageKey: storageKey, accountID: accountID)
              ] == fingerprint
        else { return nil }
        // The complete digest was validated once when the spool lease was opened. Each PATCH
        // binds its own SHA-256, and server completion binds the full digest, so rehashing the
        // entire file for every offset would turn an n-byte upload into O(n²) local I/O.
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let count = min(maximumBytes, Int(expectedByteCount - offset))
        guard let data = try handle.read(upToCount: count), data.count == count else {
            return nil
        }
        return data
    }

    func removeCiphertextSpool(forStorageKey storageKey: String, userID: String) {
        guard let accountID = canonicalAccountID(userID),
              let url = ciphertextFileURL(forStorageKey: storageKey, accountID: accountID)
        else { return }
        try? FileManager.default.removeItem(at: url)
        verifiedSpoolLeases.removeValue(
            forKey: spoolLeaseKey(storageKey: storageKey, accountID: accountID)
        )
    }

    /// Verifies a downloaded encrypted frame, decrypts it in bounded chunks, and publishes the
    /// plaintext cache entry atomically only after the complete HMAC/SHA/size checks pass.
    func storeVerifiedReceivedOriginal(
        ciphertextURL: URL,
        forStorageKey storageKey: String,
        userID: String,
        mediaType: String,
        ciphertextByteCount: Int64,
        ciphertextSHA256: String,
        plaintextByteCount: Int,
        keyMaterial: Data
    ) async throws -> SecureMediaProtectedFile {
        guard let accountID = canonicalAccountID(userID),
              !reservedEvictionKeys.contains(
                  cacheEntryKey(storageKey: storageKey, accountID: accountID)
              ),
              let destination = originalFileURL(
                  forStorageKey: storageKey,
                  accountID: accountID,
                  mediaType: mediaType
              )
        else { throw SecureMediaAttachmentError.invalidDescriptor }
        try ensureDirectory(for: accountID)
        let staging = accountDirectoryURL(for: accountID).appendingPathComponent(
            ".\(UUID().uuidString.lowercased()).hydrating",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: staging) }
        try await Task.detached(priority: .utility) {
            try SecureMediaAttachmentCipher.decryptFile(
                ciphertextURL: ciphertextURL,
                plaintextURL: staging,
                expectedCiphertextByteSize: ciphertextByteCount,
                expectedCiphertextSHA256: ciphertextSHA256,
                expectedPlaintextByteSize: plaintextByteCount,
                keyMaterial: keyMaterial
            )
        }.value
        try Task.checkCancellation()
        try protectOriginal(at: staging)
        try excludeFromBackup(staging)
        if let existing = originalFileURL(forStorageKey: storageKey, accountID: accountID) {
            guard regularFileByteCount(at: existing) == plaintextByteCount,
                  existing.standardizedFileURL == destination.standardizedFileURL
            else { throw SecureMediaAttachmentError.invalidCiphertext }
            if filesAreIdentical(existing, staging) {
                return SecureMediaProtectedFile(
                    fileURL: existing,
                    byteSize: plaintextByteCount,
                    insertion: .alreadyPresent
                )
            }
            // The network copy has already passed the authenticated decrypt above. Repair a
            // corrupt same-size cache entry atomically instead of leaving every future open to
            // fail against the same stale bytes forever.
            let backupName = ".\(UUID().uuidString.lowercased()).repairing"
            _ = try FileManager.default.replaceItemAt(
                existing,
                withItemAt: staging,
                backupItemName: backupName,
                options: []
            )
            let backup = accountDirectoryURL(for: accountID)
                .appendingPathComponent(backupName, isDirectory: false)
            try? FileManager.default.removeItem(at: backup)
            try protectOriginal(at: destination)
            try excludeFromBackup(destination)
            guard regularFileByteCount(at: destination) == plaintextByteCount else {
                throw SecureMediaAttachmentError.invalidCiphertext
            }
            indexOriginalURL(destination, storageKey: storageKey, accountID: accountID)
            return SecureMediaProtectedFile(
                fileURL: destination,
                byteSize: plaintextByteCount,
                insertion: .stored
            )
        }
        guard !hasAnyRepresentation(storageKey: storageKey, accountID: accountID) else {
            throw SecureMediaAttachmentError.invalidCiphertext
        }
        try FileManager.default.moveItem(at: staging, to: destination)
        guard regularFileByteCount(at: destination) == plaintextByteCount else {
            try? FileManager.default.removeItem(at: destination)
            throw SecureMediaAttachmentError.invalidCiphertext
        }
        indexOriginalURL(destination, storageKey: storageKey, accountID: accountID)
        return SecureMediaProtectedFile(
            fileURL: destination,
            byteSize: plaintextByteCount,
            insertion: .stored
        )
    }

    /// Metadata-only validation for queue admission. New file-backed sends use this instead of
    /// reading, decrypting and byte-comparing the entire original before a bubble can appear.
    func byteCount(forStorageKey storageKey: String, userID: String) -> Int? {
        guard let accountID = canonicalAccountID(userID) else { return nil }
        if let original = originalFileURL(forStorageKey: storageKey, accountID: accountID),
           let count = regularFileByteCount(at: original) {
            return count
        }
        return data(forStorageKey: storageKey, userID: userID)?.count
    }

    func remove(forStorageKey storageKey: String, userID: String) {
        guard let accountID = canonicalAccountID(userID),
              let sealedURL = sealedFileURL(forStorageKey: storageKey, accountID: accountID)
        else { return }
        try? FileManager.default.removeItem(at: sealedURL)
        for originalURL in originalFileURLs(forStorageKey: storageKey, accountID: accountID) {
            try? FileManager.default.removeItem(at: originalURL)
        }
        originalURLIndex[accountID]?[storageKey.lowercased()] = nil
        if let ciphertextURL = ciphertextFileURL(
            forStorageKey: storageKey,
            accountID: accountID
        ) {
            try? FileManager.default.removeItem(at: ciphertextURL)
        }
        verifiedSpoolLeases.removeValue(
            forKey: spoolLeaseKey(storageKey: storageKey, accountID: accountID)
        )
        let entryKey = cacheEntryKey(storageKey: storageKey, accountID: accountID)
        activeOriginalLeases.removeValue(forKey: entryKey)
        lastOriginalAccessDates.removeValue(forKey: entryKey)
        reservedEvictionKeys.remove(entryKey)
    }

    /// Atomic non-overwriting insert: writes `data` under `storageKey` only when the key is
    /// absent, never replacing existing bytes — whoever created an existing entry (a concurrent
    /// load, a pending-batch park, a forward duplication) keeps its copy authoritative. Runs as
    /// one uninterrupted actor step — no awaits — so no interleaved store or remove can slip
    /// between the existence check and the write. The outcome is the caller's ownership fact:
    /// only `.stored` licenses that caller to remove the entry on a failed revalidation.
    func insertIfAbsent(
        _ data: Data,
        forStorageKey storageKey: String,
        userID: String
    ) -> SecureMediaInsertOutcome {
        guard let accountID = canonicalAccountID(userID), !data.isEmpty,
              sealedFileURL(forStorageKey: storageKey, accountID: accountID) != nil
        else { return .rejected }
        if hasAnyRepresentation(storageKey: storageKey, accountID: accountID) {
            return .alreadyPresent
        }
        do {
            try store(data, forStorageKey: storageKey, userID: userID)
        } catch {
            return .rejected
        }
        // Only a byte-verified destination counts as stored, and an unverifiable write is
        // unwound as ours to unwind because the key was absent moments ago within this same
        // actor step.
        guard self.data(forStorageKey: storageKey, userID: userID) == data else {
            remove(forStorageKey: storageKey, userID: userID)
            return .rejected
        }
        return .stored
    }

    /// Non-overwriting duplication: copies `sourceKey`'s plaintext to `destinationKey` only
    /// when the destination is absent, and classifies an existing destination by byte
    /// comparison instead of replacing it. Runs as one uninterrupted actor step — no awaits —
    /// so no interleaved store or remove can slip between the existence check and the write;
    /// state-level ownership checks cannot close that window, only this boundary can.
    func duplicate(
        fromStorageKey sourceKey: String,
        toStorageKey destinationKey: String,
        userID: String
    ) -> SecureMediaDuplicateOutcome {
        guard let accountID = canonicalAccountID(userID) else { return .sourceMissing }
        if let sourceOriginal = originalFileURL(
            forStorageKey: sourceKey,
            accountID: accountID
        ), FileManager.default.fileExists(atPath: sourceOriginal.path),
           let sourceSize = regularFileByteCount(at: sourceOriginal),
           let destinationOriginal = originalFileURL(
               forStorageKey: destinationKey,
               accountID: accountID,
               fileExtension: sourceOriginal.pathExtension
           ) {
            if hasAnyRepresentation(storageKey: destinationKey, accountID: accountID) {
                guard let existingOriginal = originalFileURL(
                    forStorageKey: destinationKey,
                    accountID: accountID
                ), regularFileByteCount(at: existingOriginal) == sourceSize,
                   filesAreIdentical(sourceOriginal, existingOriginal)
                else { return .conflict }
                return .alreadyIdentical
            } else {
                do {
                    try ensureDirectory(for: accountID)
                    try FileManager.default.copyItem(
                        at: sourceOriginal,
                        to: destinationOriginal
                    )
                    try protectOriginal(at: destinationOriginal)
                    try excludeFromBackup(destinationOriginal)
                    guard regularFileByteCount(at: destinationOriginal) == sourceSize else {
                        remove(forStorageKey: destinationKey, userID: userID)
                        return .conflict
                    }
                    indexOriginalURL(
                        destinationOriginal,
                        storageKey: destinationKey,
                        accountID: accountID
                    )
                    return .stored
                } catch {
                    try? FileManager.default.removeItem(at: destinationOriginal)
                    return .conflict
                }
            }
        }
        guard let source = data(forStorageKey: sourceKey, userID: userID) else {
            return .sourceMissing
        }
        if let existing = data(forStorageKey: destinationKey, userID: userID) {
            return existing == source ? .alreadyIdentical : .conflict
        }
        do {
            try store(source, forStorageKey: destinationKey, userID: userID)
        } catch {
            return .conflict
        }
        // `store` silently declines invalid keys and empty payloads; only a byte-verified
        // destination counts as stored, and an unverifiable write is unwound as ours to unwind
        // because the destination was absent moments ago within this same actor step.
        guard data(forStorageKey: destinationKey, userID: userID) == source else {
            remove(forStorageKey: destinationKey, userID: userID)
            return .conflict
        }
        return .stored
    }

    /// Deletion license: removes `storageKey` only while its plaintext is byte-identical to
    /// the plaintext readable under `survivorKey`, so the delete can never destroy the last
    /// copy of anything. One uninterrupted actor step for the same reason as `duplicate`.
    func removeDuplicate(
        forStorageKey storageKey: String,
        keeping survivorKey: String,
        userID: String
    ) -> Bool {
        guard storageKey != survivorKey,
              let accountID = canonicalAccountID(userID)
        else { return false }
        let doomedOriginal = originalFileURL(
            forStorageKey: storageKey,
            accountID: accountID
        )
        let survivorOriginal = originalFileURL(
            forStorageKey: survivorKey,
            accountID: accountID
        )
        if let doomedOriginal, let survivorOriginal {
            guard filesAreIdentical(doomedOriginal, survivorOriginal) else { return false }
            remove(forStorageKey: storageKey, userID: userID)
            return true
        }
        // Never materialize a protected large file merely to compare it with another storage
        // representation. Mixed representation aliases fail closed and remain for bounded
        // orphan reconciliation.
        guard doomedOriginal == nil, survivorOriginal == nil,
              let doomed = data(forStorageKey: storageKey, userID: userID),
              let survivor = data(forStorageKey: survivorKey, userID: userID),
              doomed == survivor
        else { return false }
        remove(forStorageKey: storageKey, userID: userID)
        return true
    }

    /// Removes both ciphertext and the device-only wrapping key for exactly one account.
    /// The canonical account component prevents one sign-out from traversing into another
    /// account's directory even if a malformed identifier reaches this boundary.
    func purge(forUserID userID: String) throws {
        guard let accountID = canonicalAccountID(userID) else { return }
        let directoryURL = accountDirectoryURL(for: accountID)
        if FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.removeItem(at: directoryURL)
        }
        originalURLIndex.removeValue(forKey: accountID)
        indexedOriginalAccounts.remove(accountID)
        originalDirectoryScanCounts.removeValue(forKey: accountID)
        verifiedSpoolLeases = verifiedSpoolLeases.filter {
            !$0.key.hasPrefix("\(accountID):")
        }
        spoolDigestVerificationCounts = spoolDigestVerificationCounts.filter {
            !$0.key.hasPrefix("\(accountID):")
        }
        activeOriginalLeases = activeOriginalLeases.filter {
            !$0.key.hasPrefix("\(accountID):")
        }
        lastOriginalAccessDates = lastOriginalAccessDates.filter {
            !$0.key.hasPrefix("\(accountID):")
        }
        reservedEvictionKeys = Set(reservedEvictionKeys.filter {
            !$0.hasPrefix("\(accountID):")
        })
        evictionReservations = evictionReservations.filter {
            $0.value.accountID != accountID
        }
        try KeychainStore.remove(keyAccount(for: accountID))
        cachedKeys.removeValue(forKey: accountID)

        // Builds before account scoping wrote directly into the cache root under one shared key.
        // Those blobs cannot be assigned safely, so retire them on the first account purge.
        try? removeLegacyFiles()
        try? KeychainStore.remove(keyAccountPrefix)
    }

    func totalBytes(forUserID userID: String) -> Int {
        guard let accountID = canonicalAccountID(userID) else { return 0 }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: accountDirectoryURL(for: accountID),
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Selects receiver-owned files to bring the persistent cache below its low-water mark. No
    /// bytes are deleted here: selected keys become unavailable for new leases, then AppModel must
    /// atomically reconcile their records to remote-only before calling `commitEviction`.
    func reserveReceivedCacheEviction(
        candidates suppliedCandidates: [SecureMediaCacheEvictionCandidate],
        forUserID userID: String,
        maximumBytes: Int64,
        targetBytes: Int64,
        recentAccessProtection: TimeInterval,
        now: Date = Date()
    ) -> SecureMediaCacheEvictionReservation? {
        guard maximumBytes > 0,
              targetBytes >= 0,
              targetBytes <= maximumBytes,
              recentAccessProtection >= 0,
              let accountID = canonicalAccountID(userID)
        else { return nil }

        struct ResolvedCandidate {
            let candidates: [SecureMediaCacheEvictionCandidate]
            let storageKey: String
            let entryKey: String
            let fileURL: URL
            let byteSize: Int64
            let lastAccessedAt: Date
            let modificationDate: Date
        }

        let grouped = Dictionary(grouping: suppliedCandidates) { candidate in
            canonicalStorageKey(candidate.storageKey) ?? ""
        }
        var resolved: [ResolvedCandidate] = []
        resolved.reserveCapacity(grouped.count)
        for (storageKey, candidates) in grouped where !storageKey.isEmpty {
            guard !candidates.isEmpty,
                  candidates.allSatisfy({ candidate in
                      candidate.ownership == .receivedCache
                          && canonicalStorageKey(candidate.storageKey) == storageKey
                          && candidate.expectedPlaintextByteCount > 0
                          && [.protectedFile, .encryptedBlob].contains(candidate.storageKind)
                  })
            else { continue }
            let storageKinds = Set(candidates.map(\.storageKind))
            guard storageKinds.count == 1, let storageKind = storageKinds.first else { continue }
            let fileURL: URL?
            switch storageKind {
            case .protectedFile:
                guard Set(candidates.map(\.expectedPlaintextByteCount)).count == 1,
                      let expected = candidates.first?.expectedPlaintextByteCount,
                      let original = originalFileURL(
                          forStorageKey: storageKey,
                          accountID: accountID
                      ), regularFileByteCount(at: original) == expected
                else { continue }
                fileURL = original
            case .encryptedBlob:
                fileURL = sealedFileURL(forStorageKey: storageKey, accountID: accountID)
            case .encryptedState, .none:
                fileURL = nil
            }
            guard let fileURL,
                  let values = try? fileURL.resourceValues(
                      forKeys: [
                          .fileSizeKey,
                          .contentModificationDateKey,
                          .isRegularFileKey,
                          .isSymbolicLinkKey,
                      ]
                  ), values.isRegularFile == true, values.isSymbolicLink != true,
                  let byteSize = values.fileSize.map(Int64.init), byteSize > 0,
                  let modificationDate = values.contentModificationDate
            else { continue }
            let entryKey = cacheEntryKey(storageKey: storageKey, accountID: accountID)
            let stateAccessDate = candidates.map(\.lastAccessedAt).max() ?? .distantPast
            let lastAccessedAt = max(
                stateAccessDate,
                modificationDate,
                lastOriginalAccessDates[entryKey] ?? .distantPast
            )
            resolved.append(ResolvedCandidate(
                candidates: candidates,
                storageKey: storageKey,
                entryKey: entryKey,
                fileURL: fileURL,
                byteSize: byteSize,
                lastAccessedAt: lastAccessedAt,
                modificationDate: modificationDate
            ))
        }

        let bytesBefore = resolved.reduce(Int64(0)) { partial, item in
            let (next, overflow) = partial.addingReportingOverflow(item.byteSize)
            return overflow ? Int64.max : next
        }
        guard bytesBefore > maximumBytes else { return nil }

        var remaining = bytesBefore
        var selected: [ResolvedCandidate] = []
        let recentCutoff = now.addingTimeInterval(-recentAccessProtection)
        for candidate in resolved.sorted(by: {
            if $0.lastAccessedAt != $1.lastAccessedAt {
                return $0.lastAccessedAt < $1.lastAccessedAt
            }
            return $0.storageKey < $1.storageKey
        }) {
            guard remaining > targetBytes,
                  activeOriginalLeases[candidate.entryKey]?.isEmpty != false,
                  !reservedEvictionKeys.contains(candidate.entryKey),
                  candidate.lastAccessedAt <= recentCutoff
            else { continue }
            selected.append(candidate)
            remaining = max(0, remaining - candidate.byteSize)
        }
        guard !selected.isEmpty else { return nil }

        let reservationID = UUID()
        let entries = selected.map { candidate in
            EvictionReservationState.Entry(
                storageKey: candidate.storageKey,
                fileURL: candidate.fileURL,
                byteSize: candidate.byteSize,
                modificationDate: candidate.modificationDate
            )
        }
        for candidate in selected { reservedEvictionKeys.insert(candidate.entryKey) }
        evictionReservations[reservationID] = EvictionReservationState(
            accountID: accountID,
            entries: entries
        )
        return SecureMediaCacheEvictionReservation(
            id: reservationID,
            candidates: selected.flatMap(\.candidates),
            bytesBeforeEviction: bytesBefore,
            projectedBytesAfterEviction: remaining
        )
    }

    /// Commits only the exact files fingerprinted by a prior reservation. A changed/replaced path
    /// is left untouched; its already-remote-only state makes it a harmless orphan for the normal
    /// age-gated reconciliation pass instead of risking deletion of new bytes.
    @discardableResult
    func commitEviction(
        _ reservation: SecureMediaCacheEvictionReservation,
        forUserID userID: String
    ) -> Set<String> {
        guard let accountID = canonicalAccountID(userID),
              evictionReservations[reservation.id]?.accountID == accountID,
              let state = evictionReservations.removeValue(forKey: reservation.id)
        else { return [] }
        defer {
            for entry in state.entries {
                reservedEvictionKeys.remove(
                    cacheEntryKey(storageKey: entry.storageKey, accountID: accountID)
                )
            }
        }
        var removed: Set<String> = []
        for entry in state.entries {
            let values = try? entry.fileURL.resourceValues(
                forKeys: [
                    .fileSizeKey,
                    .contentModificationDateKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]
            )
            guard values?.isRegularFile == true,
                  values?.isSymbolicLink != true,
                  values?.fileSize.map(Int64.init) == entry.byteSize,
                  values?.contentModificationDate == entry.modificationDate
            else { continue }
            do {
                try FileManager.default.removeItem(at: entry.fileURL)
                removed.insert(entry.storageKey)
                originalURLIndex[accountID]?[entry.storageKey]?.remove(entry.fileURL)
                if originalURLIndex[accountID]?[entry.storageKey]?.isEmpty == true {
                    originalURLIndex[accountID]?[entry.storageKey] = nil
                }
                let entryKey = cacheEntryKey(
                    storageKey: entry.storageKey,
                    accountID: accountID
                )
                lastOriginalAccessDates.removeValue(forKey: entryKey)
                activeOriginalLeases.removeValue(forKey: entryKey)
            } catch {
                continue
            }
        }
        return removed
    }

    func cancelEviction(
        _ reservation: SecureMediaCacheEvictionReservation,
        forUserID userID: String
    ) {
        guard let accountID = canonicalAccountID(userID),
              evictionReservations[reservation.id]?.accountID == accountID,
              let state = evictionReservations.removeValue(forKey: reservation.id)
        else { return }
        for entry in state.entries {
            reservedEvictionKeys.remove(
                cacheEntryKey(storageKey: entry.storageKey, accountID: accountID)
            )
        }
    }

    /// Bounded crash-orphan reconciliation. Queueing deliberately writes the protected original
    /// before committing the message/outbox record, so a process death in that narrow window can
    /// leave an unreferenced blob. Only old, canonical, regular files are eligible: the grace
    /// window protects a concurrent just-staged write whose state commit has not happened yet,
    /// and the retained set protects every key reachable from any live message representation.
    @discardableResult
    func removeUnreferenced(
        retainingStorageKeys: Set<String>,
        retainingCiphertextSpoolKeys: Set<String> = [],
        forUserID userID: String,
        modifiedBefore cutoff: Date,
        maximumRemovals: Int = 64
    ) -> Int {
        guard maximumRemovals > 0,
              let accountID = canonicalAccountID(userID),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: accountDirectoryURL(for: accountID),
                  includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                  options: []
              )
        else { return 0 }
        let retained = Set(retainingStorageKeys.compactMap { key in
            UUID(uuidString: key)?.uuidString.lowercased()
        })
        let retainedSpools = Set(retainingCiphertextSpoolKeys.compactMap { key in
            UUID(uuidString: key)?.uuidString.lowercased()
        })
        var removed = 0
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if removed < maximumRemovals,
               ["importing", "encrypting", "hydrating", "verifying", "repairing"]
                  .contains(url.pathExtension),
               let values = try? url.resourceValues(
                   forKeys: [.contentModificationDateKey, .isRegularFileKey]
               ), values.isRegularFile == true,
               let modified = values.contentModificationDate,
               modified <= cutoff {
                do {
                    try FileManager.default.removeItem(at: url)
                    removed += 1
                } catch {}
                continue
            }
            guard removed < maximumRemovals,
                  (url.pathExtension == "sealed"
                      || url.pathExtension == "ciphertext"
                      || url.lastPathComponent.contains(".original.")),
                  let key = storageKey(fromFileURL: url),
                  !reservedEvictionKeys.contains(
                      cacheEntryKey(storageKey: key, accountID: accountID)
                  ),
                  activeOriginalLeases[
                      cacheEntryKey(storageKey: key, accountID: accountID)
                  ]?.isEmpty != false,
                  (url.pathExtension == "ciphertext"
                      ? !retainedSpools.contains(key)
                      : !retained.contains(key)),
                  let values = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified <= cutoff
            else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                if url.pathExtension == "ciphertext" {
                    verifiedSpoolLeases.removeValue(
                        forKey: spoolLeaseKey(storageKey: key, accountID: accountID)
                    )
                }
                if url.lastPathComponent.contains(".original.") {
                    originalURLIndex[accountID]?[key]?.remove(url)
                    if originalURLIndex[accountID]?[key]?.isEmpty == true {
                        originalURLIndex[accountID]?[key] = nil
                    }
                }
                removed += 1
            } catch {
                continue
            }
        }
        return removed
    }

    private func canonicalAccountID(_ userID: String) -> String? {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: trimmed) else { return nil }
        return uuid.uuidString.lowercased()
    }

    private func canonicalStorageKey(_ storageKey: String) -> String? {
        UUID(uuidString: storageKey)?.uuidString.lowercased()
    }

    private func cacheEntryKey(storageKey: String, accountID: String) -> String {
        "\(accountID):\(storageKey.lowercased())"
    }

    private func recordAccess(
        to fileURL: URL,
        storageKey: String,
        accountID: String,
        at now: Date = Date()
    ) {
        let entryKey = cacheEntryKey(storageKey: storageKey, accountID: accountID)
        let previous = lastOriginalAccessDates[entryKey]
        lastOriginalAccessDates[entryKey] = max(previous ?? .distantPast, now)
        // Persist an approximate LRU across process death without a second plaintext metadata
        // store. Coalescing avoids turning poster-frame probes into repeated filesystem writes.
        if let previous, now.timeIntervalSince(previous) < 60 { return }
        try? FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: fileURL.path
        )
    }

    private func releaseOriginalAccessLease(
        id: UUID,
        accountID: String,
        storageKey: String
    ) {
        let entryKey = cacheEntryKey(storageKey: storageKey, accountID: accountID)
        activeOriginalLeases[entryKey]?.remove(id)
        if activeOriginalLeases[entryKey]?.isEmpty == true {
            activeOriginalLeases.removeValue(forKey: entryKey)
        }
    }

    private func accountDirectoryURL(for accountID: String) -> URL {
        rootDirectoryURL.appendingPathComponent(accountID, isDirectory: true)
    }

    private func sealedFileURL(forStorageKey storageKey: String, accountID: String) -> URL? {
        // Storage keys are server-issued UUIDs; anything else must never touch the filesystem.
        guard let canonical = UUID(uuidString: storageKey)?.uuidString.lowercased() else {
            return nil
        }
        return accountDirectoryURL(for: accountID)
            .appendingPathComponent("\(canonical).sealed", isDirectory: false)
    }

    private func ciphertextFileURL(forStorageKey storageKey: String, accountID: String) -> URL? {
        guard let canonical = UUID(uuidString: storageKey)?.uuidString.lowercased() else {
            return nil
        }
        return accountDirectoryURL(for: accountID)
            .appendingPathComponent("\(canonical).ciphertext", isDirectory: false)
    }

    private func originalFileURL(
        forStorageKey storageKey: String,
        accountID: String,
        mediaType: String
    ) -> URL? {
        originalFileURL(
            forStorageKey: storageKey,
            accountID: accountID,
            fileExtension: SecureMediaLocalFilePolicy.fileExtension(for: mediaType)
        )
    }

    private func originalFileURL(
        forStorageKey storageKey: String,
        accountID: String,
        fileExtension: String
    ) -> URL? {
        guard let canonical = UUID(uuidString: storageKey)?.uuidString.lowercased(),
              SecureMediaLocalFilePolicy.isSafeFileExtension(fileExtension)
        else { return nil }
        return accountDirectoryURL(for: accountID).appendingPathComponent(
            "\(canonical).original.\(fileExtension)",
            isDirectory: false
        )
    }

    private func originalFileURL(forStorageKey storageKey: String, accountID: String) -> URL? {
        let matches = originalFileURLs(forStorageKey: storageKey, accountID: accountID)
        return matches.count == 1 ? matches[0] : nil
    }

    private func originalFileURLs(forStorageKey storageKey: String, accountID: String) -> [URL] {
        guard let canonical = UUID(uuidString: storageKey)?.uuidString.lowercased() else {
            return []
        }
        ensureOriginalIndex(for: accountID)
        return Array(originalURLIndex[accountID]?[canonical] ?? []).sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }

    private func ensureOriginalIndex(for accountID: String) {
        guard !indexedOriginalAccounts.contains(accountID) else { return }
        indexedOriginalAccounts.insert(accountID)
        originalDirectoryScanCounts[accountID, default: 0] += 1
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: accountDirectoryURL(for: accountID),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in entries where url.lastPathComponent.contains(".original.") {
            guard let key = storageKey(fromFileURL: url),
                  SecureMediaLocalFilePolicy.isSafeFileExtension(url.pathExtension)
            else { continue }
            originalURLIndex[accountID, default: [:]][key, default: []].insert(url)
        }
    }

    private func indexOriginalURL(_ url: URL, storageKey: String, accountID: String) {
        guard let key = UUID(uuidString: storageKey)?.uuidString.lowercased() else { return }
        indexedOriginalAccounts.insert(accountID)
        originalURLIndex[accountID, default: [:]][key, default: []].insert(url)
    }

    /// Test/performance instrumentation: normal playback may cause at most one legacy scan per
    /// account, regardless of how many media records it resolves.
    func originalDirectoryScanCount(forUserID userID: String) -> Int {
        guard let accountID = canonicalAccountID(userID) else { return 0 }
        return originalDirectoryScanCounts[accountID, default: 0]
    }

    /// Test/performance instrumentation: retries in one process must reuse a verified spool
    /// fingerprint instead of reading the complete ciphertext again.
    func ciphertextSpoolDigestVerificationCount(
        forStorageKey storageKey: String,
        userID: String
    ) -> Int {
        guard let accountID = canonicalAccountID(userID) else { return 0 }
        return spoolDigestVerificationCounts[
            spoolLeaseKey(storageKey: storageKey, accountID: accountID),
            default: 0
        ]
    }

    private func storageKey(fromFileURL url: URL) -> String? {
        let name = url.lastPathComponent
        let candidate: String
        if name.hasSuffix(".sealed") {
            candidate = String(name.dropLast(".sealed".count))
        } else if name.hasSuffix(".ciphertext") {
            candidate = String(name.dropLast(".ciphertext".count))
        } else if let range = name.range(of: ".original.") {
            candidate = String(name[..<range.lowerBound])
        } else {
            return nil
        }
        guard let uuid = UUID(uuidString: candidate) else { return nil }
        return uuid.uuidString.lowercased()
    }

    private func hasAnyRepresentation(storageKey: String, accountID: String) -> Bool {
        let manager = FileManager.default
        return sealedFileURL(forStorageKey: storageKey, accountID: accountID)
            .map { manager.fileExists(atPath: $0.path) } == true
            || originalFileURLs(forStorageKey: storageKey, accountID: accountID)
                .contains { manager.fileExists(atPath: $0.path) }
    }

    private func regularFileByteCount(at url: URL) -> Int? {
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        ), values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0
        else { return nil }
        return size
    }

    private func spoolLeaseKey(storageKey: String, accountID: String) -> String {
        "\(accountID):\(storageKey.lowercased())"
    }

    private func spoolFingerprint(
        at url: URL,
        byteSize: Int64,
        sha256Hex: String
    ) -> VerifiedSpoolLease? {
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        ), values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize.map(Int64.init) == byteSize,
              let modificationDate = values.contentModificationDate
        else { return nil }
        return VerifiedSpoolLease(
            fileURL: url.standardizedFileURL,
            byteSize: byteSize,
            modificationDate: modificationDate,
            sha256Hex: sha256Hex
        )
    }

    private static func sha256Hex(of url: URL, chunkBytes: Int = 256 * 1_024) -> String? {
        guard chunkBytes > 0, let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        var digest = SHA256()
        do {
            while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
                digest.update(data: chunk)
            }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            return nil
        }
    }

    private func filesAreIdentical(
        _ lhs: URL,
        _ rhs: URL,
        chunkBytes: Int = 256 * 1_024
    ) -> Bool {
        if lhs.standardizedFileURL == rhs.standardizedFileURL { return true }
        guard regularFileByteCount(at: lhs) == regularFileByteCount(at: rhs),
              chunkBytes > 0,
              let left = try? FileHandle(forReadingFrom: lhs),
              let right = try? FileHandle(forReadingFrom: rhs)
        else { return false }
        defer {
            try? left.close()
            try? right.close()
        }
        do {
            while true {
                let a = try left.read(upToCount: chunkBytes) ?? Data()
                let b = try right.read(upToCount: chunkBytes) ?? Data()
                guard a == b else { return false }
                if a.isEmpty { return true }
            }
        } catch {
            return false
        }
    }

    /// APFS copy-on-write clone: O(1) in source byte size and independently deletable from the
    /// source link. `clonefile` fails cleanly across volumes or on unsupported filesystems.
    private func cloneFile(_ source: URL, to destination: URL) -> Bool {
        let status = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                clonefile(sourcePath, destinationPath, 0)
            }
        }
        if status == 0 { return true }
        try? FileManager.default.removeItem(at: destination)
        return false
    }

    private func protectOriginal(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private func ensureDirectory(for accountID: String) throws {
        let directoryURL = accountDirectoryURL(for: accountID)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directoryURL.path
        )
    }

    private func keyAccount(for accountID: String) -> String {
        "\(keyAccountPrefix)-\(accountID)"
    }

    private func encryptionKey(for accountID: String) throws -> SymmetricKey {
        if let cachedKey = cachedKeys[accountID] { return cachedKey }
        let account = keyAccount(for: accountID)
        if let stored = try KeychainStore.data(for: account), stored.count == 32 {
            let key = SymmetricKey(data: stored)
            cachedKeys[accountID] = key
            return key
        }
        let key = SymmetricKey(size: .bits256)
        try KeychainStore.set(key.withUnsafeBytes { Data($0) }, for: account)
        cachedKeys[accountID] = key
        return key
    }

    private func removeLegacyFiles() throws {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootDirectoryURL,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in entries where url.pathExtension == "sealed" {
            try FileManager.default.removeItem(at: url)
        }
    }
}
