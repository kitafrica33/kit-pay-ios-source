import BackgroundTasks
import CloudKit
import Foundation

/// Stores the end-to-end encrypted chat backup in the user's private CloudKit database.
///
/// CloudKit only ever receives ciphertext produced by `MessageBackupCrypto`; the key stays in the
/// user's iCloud Keychain. One record per Kit Pay account keeps storage bounded — each backup
/// replaces the previous one.
actor MessageBackupManager {
    static let shared = MessageBackupManager()
    static let containerIdentifier = "iCloud.africa.kit.pay.ios"
    static let recordType = "KitMessageBackup"

    private enum Field {
        static let payload = "payload"
        static let createdAt = "createdAt"
        static let byteSize = "byteSize"
        static let messageCount = "messageCount"
        static let deviceName = "deviceName"
        static let schemaVersion = "schemaVersion"
        static let generation = "generation"
        static let contentDigest = "contentDigest"
        static let newestMessageAt = "newestMessageAt"
    }

    private static let maximumConflictAttempts = 5

    private let makeContainer: @Sendable () -> CKContainer

    init(makeContainer: @escaping @Sendable () -> CKContainer = {
        CKContainer(identifier: MessageBackupManager.containerIdentifier)
    }) {
        self.makeContainer = makeContainer
    }

    private var database: CKDatabase { makeContainer().privateCloudDatabase }

    static func recordID(forUserID userID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "kit-message-backup-\(userID.lowercased())")
    }

    func isICloudAvailable() async -> Bool {
        (try? await makeContainer().accountStatus()) == .available
    }

    /// Metadata only — the encrypted asset is not downloaded.
    func latestBackupSummary(forUserID userID: String) async throws -> MessageBackupSummary? {
        do {
            let record = try await database.record(for: Self.recordID(forUserID: userID))
            return summary(from: record)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch let error as CKError where error.code == .notAuthenticated {
            throw MessageBackupError.iCloudUnavailable
        }
    }

    @discardableResult
    func upload(_ payload: MessageBackupPayload) async throws -> MessageBackupSummary {
        guard await isICloudAvailable() else { throw MessageBackupError.iCloudUnavailable }
        try MessageBackupValidationPolicy.validate(payload, expectedUserID: payload.userID)
        let key = try MessageBackupKeyStore.key(forUserID: payload.userID)

        for _ in 0..<Self.maximumConflictAttempts {
            let existing = try await recordIfPresent(forUserID: payload.userID)
            let archive: MessageBackupPayload
            if let existing {
                let remote = try self.payload(
                    from: existing,
                    key: key,
                    expectedUserID: payload.userID
                )
                archive = try MessageBackupConflictPolicy.merge(remote, payload)
                let remoteMetadata = try MessageBackupContentMetadata.make(for: remote)
                let archiveMetadata = try MessageBackupContentMetadata.make(for: archive)
                if archiveMetadata.digest == remoteMetadata.digest {
                    return summary(from: existing) ?? MessageBackupSummary(
                        createdAt: remote.createdAt,
                        byteSize: encryptedByteSize(in: existing) ?? 0,
                        messageCount: remote.messages.count,
                        deviceName: remote.deviceName,
                        generation: generation(in: existing),
                        contentDigest: remoteMetadata.digest
                    )
                }
            } else {
                archive = payload
            }

            let metadata = try MessageBackupContentMetadata.make(for: archive)
            let encrypted = try MessageBackupCrypto.encrypt(archive, key: key)
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("kit-backup-\(UUID().uuidString).bin", isDirectory: false)
            // Class B: background-refresh backups run while the device is locked, and CloudKit
            // must still be able to read the staged asset.
            try encrypted.write(
                to: temporaryURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            defer { try? FileManager.default.removeItem(at: temporaryURL) }

            let record = existing ?? CKRecord(
                recordType: Self.recordType,
                recordID: Self.recordID(forUserID: payload.userID)
            )
            let nextGeneration = generation(in: existing) + 1
            record[Field.payload] = CKAsset(fileURL: temporaryURL)
            record[Field.createdAt] = archive.createdAt as NSDate
            record[Field.byteSize] = encrypted.count as NSNumber
            record[Field.messageCount] = archive.messages.count as NSNumber
            record[Field.deviceName] = archive.deviceName as NSString
            record[Field.schemaVersion] = archive.schemaVersion as NSNumber
            record[Field.generation] = nextGeneration as NSNumber
            record[Field.contentDigest] = metadata.digest as NSString
            if let newestMessageAt = metadata.newestMessageAt {
                record[Field.newestMessageAt] = newestMessageAt as NSDate
            } else {
                record[Field.newestMessageAt] = nil
            }

            do {
                let saved = try await database.save(record)
                guard let summary = summary(from: saved) else {
                    throw MessageBackupError.invalidBackup
                }
                return summary
            } catch {
                if Self.isServerRecordConflict(error) { continue }
                if let cloudError = error as? CKError,
                   cloudError.code == .notAuthenticated {
                    throw MessageBackupError.iCloudUnavailable
                }
                throw error
            }
        }
        throw MessageBackupError.conflictRetryLimitExceeded
    }

    func downloadPayload(forUserID userID: String) async throws -> MessageBackupPayload {
        let record: CKRecord
        do {
            record = try await database.record(for: Self.recordID(forUserID: userID))
        } catch let error as CKError where error.code == .unknownItem {
            throw MessageBackupError.backupNotFound
        } catch let error as CKError where error.code == .notAuthenticated {
            throw MessageBackupError.iCloudUnavailable
        }
        guard let key = try MessageBackupKeyStore.existingKey(forUserID: userID) else {
            throw MessageBackupError.keyUnavailable
        }
        return try payload(from: record, key: key, expectedUserID: userID)
    }

    func deleteBackup(forUserID userID: String) async throws {
        do {
            try await database.deleteRecord(withID: Self.recordID(forUserID: userID))
        } catch let error as CKError where error.code == .unknownItem {
            // Nothing to delete.
        } catch let error as CKError where error.code == .notAuthenticated {
            throw MessageBackupError.iCloudUnavailable
        }
    }

    private func summary(from record: CKRecord) -> MessageBackupSummary? {
        guard let createdAt = record[Field.createdAt] as? Date,
              let byteSize = record[Field.byteSize] as? Int,
              let messageCount = record[Field.messageCount] as? Int,
              byteSize > MessageBackupCrypto.envelopePrefix.count,
              byteSize <= MessageBackupValidationPolicy.maximumEncryptedBytes,
              messageCount >= 0,
              messageCount <= MessageBackupValidationPolicy.maximumMessages
        else { return nil }
        let generation = generation(in: record)
        let contentDigest = record[Field.contentDigest] as? String
        guard generation >= 0,
              contentDigest.map(SecureMessagingWirePolicy.isLowercaseSHA256) ?? true
        else { return nil }
        return MessageBackupSummary(
            createdAt: createdAt,
            byteSize: byteSize,
            messageCount: messageCount,
            deviceName: record[Field.deviceName] as? String ?? "iPhone",
            generation: generation,
            contentDigest: contentDigest
        )
    }

    private func recordIfPresent(forUserID userID: String) async throws -> CKRecord? {
        do {
            return try await database.record(for: Self.recordID(forUserID: userID))
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch let error as CKError where error.code == .notAuthenticated {
            throw MessageBackupError.iCloudUnavailable
        }
    }

    private func payload(
        from record: CKRecord,
        key: Data,
        expectedUserID: String
    ) throws -> MessageBackupPayload {
        guard let asset = record[Field.payload] as? CKAsset,
              let fileURL = asset.fileURL,
              let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > MessageBackupCrypto.envelopePrefix.count,
              size <= MessageBackupValidationPolicy.maximumEncryptedBytes
        else { throw MessageBackupError.invalidBackup }
        let encrypted: Data
        do {
            encrypted = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw MessageBackupError.invalidBackup
        }
        let payload = try MessageBackupCrypto.decrypt(encrypted, key: key)
        try MessageBackupValidationPolicy.validate(payload, expectedUserID: expectedUserID)
        return payload
    }

    private func generation(in record: CKRecord?) -> Int64 {
        guard let record else { return 0 }
        if let value = record[Field.generation] as? Int64 { return max(0, value) }
        if let value = record[Field.generation] as? NSNumber { return max(0, value.int64Value) }
        return 0
    }

    private func encryptedByteSize(in record: CKRecord) -> Int? {
        if let value = record[Field.byteSize] as? Int { return value }
        if let value = record[Field.byteSize] as? NSNumber { return value.intValue }
        return nil
    }

    private static func isServerRecordConflict(_ error: Error) -> Bool {
        guard let cloudError = error as? CKError else { return false }
        if cloudError.code == .serverRecordChanged { return true }
        guard cloudError.code == .partialFailure,
              let failures = cloudError.partialErrorsByItemID
        else { return false }
        return failures.values.contains { ($0 as? CKError)?.code == .serverRecordChanged }
    }
}

/// Ensures `setTaskCompleted` runs exactly once even when expiration races normal completion —
/// BackgroundTasks treats a second completion call as a programmer error.
final class BackgroundTaskCompletionLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var task: BGTask?

    init(_ task: BGTask) {
        self.task = task
    }

    func finish(success: Bool) {
        lock.lock()
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.setTaskCompleted(success: success)
    }
}

/// Mirrors `ContactBackgroundRefreshScheduler`: registration happens at launch before the handler
/// exists, so an early task is parked until `AppModel` installs the handler.
@MainActor
final class MessageBackupRefreshScheduler {
    static let shared = MessageBackupRefreshScheduler()
    static let identifier = "africa.kit.pay.ios.message-backup"

    private var handler: ((BGAppRefreshTask) -> Void)?
    private var pendingTask: BGAppRefreshTask?

    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.identifier,
            using: .main
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.schedule()
            if let handler = self?.handler {
                handler(refreshTask)
            } else {
                self?.pendingTask = refreshTask
            }
        }
    }

    func installHandler(_ handler: @escaping (BGAppRefreshTask) -> Void) {
        self.handler = handler
        if let pendingTask {
            self.pendingTask = nil
            handler(pendingTask)
        }
    }

    func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
