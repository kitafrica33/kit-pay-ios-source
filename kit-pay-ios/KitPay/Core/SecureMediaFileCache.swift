import CryptoKit
import Foundation

/// Encrypted-at-rest cache for large decrypted chat media (videos, documents, long voice notes).
///
/// The single AES-GCM state file must stay small — every `SecureLocalStore.update` rewrites it in
/// full, so even a multi-megabyte video inline in `LocalMessage.attachmentData` would make each
/// wallet-balance tweak rewrite the blob. Large plaintext therefore lives here: one ChaChaPoly-sealed
/// file per attachment storage key, keyed by a device-only Keychain key, protected class B, and
/// excluded from device backups because every blob is re-downloadable from the encrypted server copy.
actor SecureMediaFileCache {
    static let shared = SecureMediaFileCache()

    private let rootDirectoryURL: URL
    private let keyAccountPrefix: String
    private var cachedKeys: [String: SymmetricKey] = [:]

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
              let fileURL = fileURL(forStorageKey: storageKey, accountID: accountID),
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
        guard let accountID = canonicalAccountID(userID),
              let fileURL = fileURL(forStorageKey: storageKey, accountID: accountID),
              let sealedData = try? Data(contentsOf: fileURL),
              let sealed = try? ChaChaPoly.SealedBox(combined: sealedData),
              let key = try? encryptionKey(for: accountID),
              let plaintext = try? ChaChaPoly.open(sealed, using: key)
        else { return nil }
        return plaintext
    }

    func remove(forStorageKey storageKey: String, userID: String) {
        guard let accountID = canonicalAccountID(userID),
              let fileURL = fileURL(forStorageKey: storageKey, accountID: accountID)
        else { return }
        try? FileManager.default.removeItem(at: fileURL)
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

    private func canonicalAccountID(_ userID: String) -> String? {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: trimmed) else { return nil }
        return uuid.uuidString.lowercased()
    }

    private func accountDirectoryURL(for accountID: String) -> URL {
        rootDirectoryURL.appendingPathComponent(accountID, isDirectory: true)
    }

    private func fileURL(forStorageKey storageKey: String, accountID: String) -> URL? {
        // Storage keys are server-issued UUIDs; anything else must never touch the filesystem.
        guard let canonical = UUID(uuidString: storageKey)?.uuidString.lowercased() else {
            return nil
        }
        return accountDirectoryURL(for: accountID)
            .appendingPathComponent("\(canonical).sealed", isDirectory: false)
    }

    private func ensureDirectory(for accountID: String) throws {
        let directoryURL = accountDirectoryURL(for: accountID)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
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
