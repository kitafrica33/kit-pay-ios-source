import CryptoKit
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// In-memory profile photos, readable synchronously from the main actor.
///
/// Kept separate from the disk actor so a row that already has its photo can draw it in the same
/// frame it appears. Going through the actor for every row would put an `await` hop between the
/// cell appearing and the photo arriving, which reads as a flash of initials on every scroll.
final class ProfileAvatarMemoryCache: @unchecked Sendable {
    static let shared = ProfileAvatarMemoryCache()

    private let cache = NSCache<NSString, UIImage>()

    init(countLimit: Int = 240) {
        cache.countLimit = countLimit
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

/// Encrypted-at-rest cache for profile photos, so faces survive relaunches and offline sessions.
///
/// `AsyncImage` backed every avatar before this, which meant photos lived in `URLCache.shared`:
/// unencrypted on disk, evicted by HTTP cache headers rather than by us, and gone the moment the
/// customer opened the app on a plane. Avatar URLs are immutable — a new upload gets a new URL —
/// so a URL-keyed cache never needs revalidation, and a hit is correct even with no network at all.
///
/// Storage mirrors `SecureMediaFileCache`: one ChaChaPoly-sealed file per URL under an
/// account-scoped directory, wrapped by a device-only Keychain key, protected class B, and excluded
/// from device backups because every photo is re-downloadable.
actor ProfileAvatarCache {
    static let shared = ProfileAvatarCache()

    /// Avatars render at most around 128pt, so 512px covers a 3x screen with room to spare.
    /// Downsampling on the way in also caps what a hostile image can cost to decode later.
    private static let maximumPixelSize = 512
    /// A profile photo the app itself produced is well under 300 KB. The ceiling is for photos
    /// this build did not create — it stops a decompression bomb before any decode happens.
    private static let maximumDownloadBytes = 6 * 1024 * 1024
    private static let maximumStoredFiles = 400
    private static let maximumStoredBytes = 48 * 1024 * 1024
    /// Enough for the handful of faces a first screen can show before the projection publishes.
    private static let maximumPendingWrites = 12
    /// How long a photo request waits for the owner to be decided. Long enough to cover a launch,
    /// short enough that a signed-out screen still draws its avatars.
    private static let accountResolutionTimeout: Duration = .seconds(2)

    private let rootDirectoryURL: URL
    private let keyAccountPrefix: String
    private let session: URLSession
    private let memory: ProfileAvatarMemoryCache
    private var cachedKeys: [String: SymmetricKey] = [:]
    private var accountID: String?
    /// Whether the owner has been decided at all, which is not the same as having one. Sign-out
    /// resolves to "nobody"; a launch that has not published its projection yet has resolved
    /// nothing, and a photo asked for in that window must wait rather than assume there is no
    /// account to read from disk.
    private var accountIsResolved = false
    private var accountWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Photos downloaded before the owner was known, held until it is.
    ///
    /// The account holder's own photo is the first avatar the app asks for — the home header draws
    /// while the account projection is still one actor hop away — so without this it would be the
    /// single avatar in the app that never reached disk, re-downloading on every launch and
    /// disappearing entirely offline.
    private var pendingWrites: [String: Data] = [:]
    /// One download per URL no matter how many rows ask. Unstructured, so a row scrolling away
    /// mid-flight does not cancel the fetch the next row is waiting on.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init(
        directoryURL: URL? = nil,
        keyAccount: String = "kit-pay-avatar-cache-key-v1",
        memory: ProfileAvatarMemoryCache = .shared
    ) {
        keyAccountPrefix = keyAccount
        self.memory = memory
        if let directoryURL {
            rootDirectoryURL = directoryURL
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            rootDirectoryURL = base
                .appendingPathComponent("KitPay", isDirectory: true)
                .appendingPathComponent("avatar-cache", isDirectory: true)
        }

        let configuration = URLSessionConfiguration.ephemeral
        // This cache is the only place an avatar is allowed to persist. Leaving `URLCache` on
        // would keep a second, unencrypted copy that sign-out has to hunt down separately.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = ["Accept": "image/*"]
        session = URLSession(configuration: configuration)
    }

    /// Points the on-disk half of the cache at the signed-in account. Photos still load without
    /// an account — they just stay in memory, because there is no account to scope a file to.
    func setAccount(_ userID: String?) {
        let canonical = userID.flatMap { canonicalAccountID($0) }
        let wasResolved = accountIsResolved
        accountIsResolved = true
        defer { resumeAccountWaiters() }
        guard !wasResolved || canonical != accountID else { return }
        let previous = accountID
        accountID = canonical
        // Only a real change of owner may drop decoded faces. Clearing on the launch-time
        // "nobody yet → the account holder" step would throw away the photos this launch has
        // already drawn, starting with the customer's own.
        if previous != nil, previous != canonical { memory.removeAll() }
        guard let canonical else {
            pendingWrites.removeAll()
            return
        }
        flushPendingWrites(for: canonical)
    }

    /// Waits, briefly, for the owner to be decided.
    private func awaitAccountResolution() async {
        guard !accountIsResolved else { return }
        let waiterID = UUID()
        let timeout = Self.accountResolutionTimeout
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            accountWaiters[waiterID] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.resumeAccountWaiter(waiterID)
            }
        }
    }

    private func resumeAccountWaiter(_ waiterID: UUID) {
        accountWaiters.removeValue(forKey: waiterID)?.resume()
    }

    private func resumeAccountWaiters() {
        guard !accountWaiters.isEmpty else { return }
        let waiters = accountWaiters
        accountWaiters.removeAll()
        for continuation in waiters.values { continuation.resume() }
    }

    /// A photo if one is already in memory or on disk, downloading it once if not.
    ///
    /// Returns `nil` rather than throwing: a missing avatar is a cosmetic outcome, and every
    /// caller's fallback is the initials placeholder it is already showing.
    func image(for urlString: String) async -> UIImage? {
        guard let url = Self.validatedURL(urlString) else { return nil }
        let key = Self.cacheKey(for: url)

        if let cached = memory.image(forKey: key) { return cached }
        // Files are sealed with an account-scoped key, so reading disk before the owner is known
        // would miss a photo this device already has and re-download it — or, with no network,
        // show initials for a face that was sitting in the cache all along.
        if !accountIsResolved { await awaitAccountResolution() }
        if let cached = memory.image(forKey: key) { return cached }
        if let stored = storedImage(forKey: key) {
            memory.insert(stored, forKey: key)
            return stored
        }
        if let existing = inFlight[key] { return await existing.value }

        // Detached on purpose: the fetch must outlive the row that asked for it, so scrolling a
        // face off screen never cancels the download the next row is already waiting on.
        let session = self.session
        let task: Task<UIImage?, Never> = Task.detached(priority: .userInitiated) { [weak self] in
            guard let downloaded = await Self.download(url, session: session) else { return nil }
            await self?.persist(downloaded, forKey: key)
            return downloaded.image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight.removeValue(forKey: key)
        return image
    }

    /// Removes every photo and the wrapping key for exactly one account. The canonical account
    /// component keeps a malformed identifier from reaching another account's directory.
    func purge(forUserID userID: String) throws {
        memory.removeAll()
        inFlight.removeAll()
        pendingWrites.removeAll()
        guard let account = canonicalAccountID(userID) else { return }
        let directoryURL = accountDirectoryURL(for: account)
        if FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.removeItem(at: directoryURL)
        }
        try KeychainStore.remove(keyAccount(for: account))
        cachedKeys.removeValue(forKey: account)
        if accountID == account { accountID = nil }
    }

    func totalBytes(forUserID userID: String) -> Int {
        guard let account = canonicalAccountID(userID) else { return 0 }
        return storedFiles(in: accountDirectoryURL(for: account))
            .reduce(0) { $0 + $1.size }
    }

    // MARK: - Disk

    private func storedImage(forKey key: String) -> UIImage? {
        guard let account = accountID,
              let fileURL = fileURL(forKey: key, accountID: account),
              let sealedData = try? Data(contentsOf: fileURL),
              let sealed = try? ChaChaPoly.SealedBox(combined: sealedData),
              let sealKey = try? encryptionKey(for: account),
              let plaintext = try? ChaChaPoly.open(sealed, using: sealKey)
        else { return nil }
        return UIImage(data: plaintext)
    }

    private func persist(_ downloaded: DownloadedAvatar, forKey key: String) {
        memory.insert(downloaded.image, forKey: key)
        guard !downloaded.storageData.isEmpty else { return }
        guard let account = accountID else {
            // No owner yet to scope a file to. Hold the bytes rather than drop them: the owner is
            // usually a fraction of a second away, and this is the customer's own photo.
            guard pendingWrites.count < Self.maximumPendingWrites else { return }
            pendingWrites[key] = downloaded.storageData
            return
        }
        write(downloaded.storageData, forKey: key, account: account)
    }

    private func flushPendingWrites(for account: String) {
        let pending = pendingWrites
        pendingWrites.removeAll()
        for (key, data) in pending {
            write(data, forKey: key, account: account)
        }
    }

    private func write(_ data: Data, forKey key: String, account: String) {
        guard let fileURL = fileURL(forKey: key, accountID: account) else { return }
        do {
            try ensureDirectory(for: account)
            let sealed = try ChaChaPoly.seal(data, using: encryptionKey(for: account))
            try sealed.combined.write(
                to: fileURL,
                options: [.atomic, .completeFileProtectionUnlessOpen]
            )
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var excludedURL = fileURL
            try? excludedURL.setResourceValues(resourceValues)
            trimStorage(for: account)
        } catch {
            // A photo that cannot be written is still on screen from memory; the next launch
            // simply re-downloads it. Nothing here is worth surfacing to the customer.
        }
    }

    /// Keeps the directory bounded by dropping the least recently written photos first.
    private func trimStorage(for account: String) {
        let files = storedFiles(in: accountDirectoryURL(for: account)).sorted {
            $0.modified < $1.modified
        }
        var remainingCount = files.count
        var remainingBytes = files.reduce(0) { $0 + $1.size }
        for file in files {
            guard remainingCount > Self.maximumStoredFiles
                || remainingBytes > Self.maximumStoredBytes
            else { break }
            do {
                try FileManager.default.removeItem(at: file.url)
            } catch {
                continue
            }
            remainingCount -= 1
            remainingBytes -= file.size
        }
    }

    private func storedFiles(in directoryURL: URL) -> [StoredFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: keys
        ) else { return [] }
        return entries.compactMap { url -> StoredFile? in
            guard url.pathExtension == "sealed" else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return StoredFile(
                url: url,
                size: values?.fileSize ?? 0,
                modified: values?.contentModificationDate ?? .distantPast
            )
        }
    }

    private struct StoredFile {
        let url: URL
        let size: Int
        let modified: Date
    }

    private func accountDirectoryURL(for account: String) -> URL {
        rootDirectoryURL.appendingPathComponent(account, isDirectory: true)
    }

    private func fileURL(forKey key: String, accountID account: String) -> URL? {
        // The key is a hex digest this file produced; refuse anything else rather than let a
        // caller-supplied string decide a path.
        guard key.count == 64, key.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            return nil
        }
        return accountDirectoryURL(for: account)
            .appendingPathComponent("\(key).sealed", isDirectory: false)
    }

    private func ensureDirectory(for account: String) throws {
        try FileManager.default.createDirectory(
            at: accountDirectoryURL(for: account),
            withIntermediateDirectories: true
        )
    }

    private func canonicalAccountID(_ userID: String) -> String? {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: trimmed) else { return nil }
        return uuid.uuidString.lowercased()
    }

    private func keyAccount(for account: String) -> String {
        "\(keyAccountPrefix)-\(account)"
    }

    private func encryptionKey(for account: String) throws -> SymmetricKey {
        if let cachedKey = cachedKeys[account] { return cachedKey }
        let keychainAccount = keyAccount(for: account)
        if let stored = try KeychainStore.data(for: keychainAccount), stored.count == 32 {
            let key = SymmetricKey(data: stored)
            cachedKeys[account] = key
            return key
        }
        let key = SymmetricKey(size: .bits256)
        try KeychainStore.set(key.withUnsafeBytes { Data($0) }, for: keychainAccount)
        cachedKeys[account] = key
        return key
    }

    // MARK: - Network

    private struct DownloadedAvatar {
        let image: UIImage
        /// The downsampled re-encode, not the bytes off the wire — a 4 MB original becomes a few
        /// tens of kilobytes at the size an avatar is ever drawn.
        let storageData: Data
    }

    private static func download(
        _ url: URL,
        session: URLSession
    ) async -> DownloadedAvatar? {
        guard let result = try? await session.data(from: url) else { return nil }
        let (data, response) = result
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            return nil
        }
        guard !data.isEmpty, data.count <= maximumDownloadBytes else { return nil }
        return downsample(data)
    }

    /// Decodes straight to the display size through ImageIO, so a large source image never gets
    /// expanded to full-resolution bitmap first.
    private static func downsample(_ data: Data) -> DownloadedAvatar? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            sourceOptions as CFDictionary
        ) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else { return nil }
        let image = UIImage(cgImage: cgImage)
        guard let encoded = encode(cgImage) else { return nil }
        return DownloadedAvatar(image: image, storageData: encoded)
    }

    /// JPEG for opaque photos, PNG for anything carrying alpha — re-encoding a transparent
    /// avatar as JPEG would fill its cut-out corners with black.
    private static func encode(_ cgImage: CGImage) -> Data? {
        let opaque: Set<CGImageAlphaInfo> = [.none, .noneSkipFirst, .noneSkipLast]
        let isOpaque = opaque.contains(cgImage.alphaInfo)
        let type = isOpaque ? UTType.jpeg : UTType.png
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            type.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let properties: [CFString: Any] = isOpaque
            ? [kCGImageDestinationLossyCompressionQuality: 0.85]
            : [:]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - Keys

    // Static members of an actor are not isolated, so the view layer calls these directly on the
    // main thread with no hop.

    /// HTTPS only, and only where a host is actually present — an avatar URL arrives from the
    /// server but is still untrusted input by the time it reaches a `URLSession`.
    static func validatedURL(_ avatarURL: String?) -> URL? {
        guard let avatarURL,
              let url = URL(string: avatarURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    /// The already-decoded photo, if there is one, without an `await`.
    ///
    /// Lets a row that scrolls back into view draw its photo in its first frame instead of
    /// flashing initials for one hop while the actor answers.
    static func cachedImage(for avatarURL: String?) -> UIImage? {
        guard let url = validatedURL(avatarURL) else { return nil }
        return ProfileAvatarMemoryCache.shared.image(forKey: cacheKey(for: url))
    }

    static func cacheKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
