import CryptoKit
import Dispatch
import Foundation
import OSLog

enum LocalMediaDiagnosticDirection: String, Codable, Sendable {
    case outgoing
    case incoming
}

enum LocalMediaPlaybackOutcome: String, Codable, Sendable {
    case preparationFailed = "preparation_failed"
    case started
    case stalled
    case failedToEnd = "failed_to_end"
    case completed
}

/// Runtime-only authority captured by the producer before asynchronous media work starts.
/// Rotating it at an account boundary makes late callbacks from the prior account harmless.
struct LocalMediaDiagnosticProducerScope: Equatable, Sendable {
    fileprivate let generation: UInt64
}

private enum LocalMediaDiagnosticEvent: String, Codable, Sendable {
    case mediaTiming = "media_timing"
    case textSendTiming = "text_send_timing"
    case videoPlayback = "video_playback"
}

private struct LocalMediaStoredDiagnosticRecord: Codable, Sendable {
    // Runtime-only row identity. Decoded records receive a fresh token; only the one-way digest
    // below is persisted so a durable upload can rebind without storing its media UUID.
    let id: UUID = UUID()
    let localCorrelationTokenSHA256: String?
    let recordedAt: Date
    let event: LocalMediaDiagnosticEvent
    var direction: LocalMediaDiagnosticDirection
    var kind: KitChatMediaKind?
    var byteCount: Int?
    var durationSeconds: Double?
    var captureToVisibleMilliseconds: Double?
    var captureToPlayableMilliseconds: Double?
    var captureToEncryptedMilliseconds: Double?
    var captureToServerAcceptedMilliseconds: Double?
    var recipientDescriptorToLocalMilliseconds: Double?
    var actionToDurableOutboxCommitMilliseconds: Double?
    var actionToVisibleLocalBubbleMilliseconds: Double?
    var playbackOutcome: LocalMediaPlaybackOutcome?
    var playbackPositionSeconds: Double?

    private enum CodingKeys: String, CodingKey {
        case localCorrelationTokenSHA256
        case recordedAt
        case event
        case direction
        case kind
        case byteCount
        case durationSeconds
        case captureToVisibleMilliseconds
        case captureToPlayableMilliseconds
        case captureToEncryptedMilliseconds
        case captureToServerAcceptedMilliseconds
        case recipientDescriptorToLocalMilliseconds
        case actionToDurableOutboxCommitMilliseconds
        case actionToVisibleLocalBubbleMilliseconds
        case playbackOutcome
        case playbackPositionSeconds
    }
}

private struct LocalMediaPersistedDiagnostics: Codable, Sendable {
    let schemaVersion: Int
    var records: [LocalMediaStoredDiagnosticRecord]
}

/// Serializes only the latest pending snapshot. At most one write and one replacement snapshot
/// are retained even if playback produces a burst of events.
private final class LocalMediaDiagnosticsPersistenceWriter: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(
        label: "africa.kit.pay.ios.local-media-diagnostics",
        qos: .utility
    )
    private let lock = NSLock()
    private var pending: LocalMediaPersistedDiagnostics?
    private var isDraining = false

    init(url: URL) {
        self.url = url
    }

    func submit(_ payload: LocalMediaPersistedDiagnostics) {
        lock.lock()
        pending = payload
        guard !isDraining else {
            lock.unlock()
            return
        }
        isDraining = true
        lock.unlock()
        queue.async { [self] in drain() }
    }

    func flush() {
        queue.sync {}
    }

    func clear() -> Bool {
        lock.lock()
        pending = nil
        lock.unlock()
        return queue.sync {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: url.path) else { return true }
            do {
                try fileManager.removeItem(at: url)
                return true
            } catch {
                // Some protection/filesystem transitions can reject unlink while still allowing
                // an atomic replacement. An empty protected payload is equally safe to reload.
                return Self.write(
                    LocalMediaPersistedDiagnostics(schemaVersion: 1, records: []),
                    to: url
                )
            }
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let payload = pending else {
                isDraining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            _ = Self.write(payload, to: url)
        }
    }

    private static func write(
        _ payload: LocalMediaPersistedDiagnostics,
        to persistenceURL: URL
    ) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(payload) else {
            logPersistenceFailure()
            return false
        }
        let fileManager = FileManager.default
        let directory = persistenceURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            var directoryResourceValues = URLResourceValues()
            directoryResourceValues.isExcludedFromBackup = true
            var mutableDirectory = directory
            try mutableDirectory.setResourceValues(directoryResourceValues)
            try data.write(
                to: persistenceURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            var fileResourceValues = URLResourceValues()
            fileResourceValues.isExcludedFromBackup = true
            var mutablePersistenceURL = persistenceURL
            try mutablePersistenceURL.setResourceValues(fileResourceValues)
            return true
        } catch {
            logPersistenceFailure()
            return false
        }
    }

    private static func logPersistenceFailure() {
        Logger(
            subsystem: "africa.kit.pay.ios",
            category: "LocalFirstMedia"
        ).error("media_diagnostics_persistence_failed")
    }
}

struct LocalMediaLatencyMeasurement: Equatable, Sendable {
    let captureToVisibleMilliseconds: Double?
    let captureToPlayableMilliseconds: Double?
    let captureToEncryptedMilliseconds: Double?
    let captureToServerAcceptedMilliseconds: Double?
    let recipientDescriptorToLocalMilliseconds: Double?

    init(
        captureToVisibleMilliseconds: Double? = nil,
        captureToPlayableMilliseconds: Double? = nil,
        captureToEncryptedMilliseconds: Double? = nil,
        captureToServerAcceptedMilliseconds: Double? = nil,
        recipientDescriptorToLocalMilliseconds: Double? = nil
    ) {
        self.captureToVisibleMilliseconds = captureToVisibleMilliseconds
        self.captureToPlayableMilliseconds = captureToPlayableMilliseconds
        self.captureToEncryptedMilliseconds = captureToEncryptedMilliseconds
        self.captureToServerAcceptedMilliseconds = captureToServerAcceptedMilliseconds
        self.recipientDescriptorToLocalMilliseconds = recipientDescriptorToLocalMilliseconds
    }

    static func milliseconds(from start: Date, to end: Date) -> Double {
        max(0, end.timeIntervalSince(start) * 1_000)
    }
}

struct LocalTextSendLatencyMeasurement: Equatable, Sendable {
    let actionToDurableOutboxCommitMilliseconds: Double?
    let actionToVisibleLocalBubbleMilliseconds: Double?
}

/// Lightweight, privacy-safe timing for local availability and the independent background
/// encryption/upload/recipient-hydration milestones. Media IDs index in-memory state only; the
/// bounded protected store contains only a one-way correlation digest, measurements, and coarse
/// media metadata. The exported report omits that digest as well as all identifiers, filenames,
/// URLs, MIME payloads, contacts, conversations, and content.
@MainActor
final class LocalMediaPerformanceMonitor {
    static let shared = LocalMediaPerformanceMonitor(
        persistenceURL: defaultPersistenceURL()
    )
    private static let maximumTrackedItems = 256

    private struct ExportApplication: Encodable {
        let version: String
        let build: String
        let operatingSystem: String
    }

    private struct ExportPrivacy: Encodable {
        let notice: String
        let excludedData: [String]
    }

    private struct ExportDiagnosticRecord: Encodable {
        let recordedAt: Date
        let event: LocalMediaDiagnosticEvent
        let direction: LocalMediaDiagnosticDirection
        let kind: KitChatMediaKind?
        let byteCount: Int?
        let durationSeconds: Double?
        let captureToVisibleMilliseconds: Double?
        let captureToPlayableMilliseconds: Double?
        let captureToEncryptedMilliseconds: Double?
        let captureToServerAcceptedMilliseconds: Double?
        let recipientDescriptorToLocalMilliseconds: Double?
        let actionToDurableOutboxCommitMilliseconds: Double?
        let actionToVisibleLocalBubbleMilliseconds: Double?
        let playbackOutcome: LocalMediaPlaybackOutcome?
        let playbackPositionSeconds: Double?
    }

    private struct ExportReport: Encodable {
        let schemaVersion: Int
        let generatedAt: Date
        let application: ExportApplication
        let privacy: ExportPrivacy
        let recordLimit: Int
        let recordCount: Int
        let records: [ExportDiagnosticRecord]
    }

    private struct Milestones {
        var capturedAt: Date
        var visibleAt: Date? = nil
        var playableAt: Date? = nil
        var encryptedAt: Date? = nil
        var serverAcceptedAt: Date? = nil
    }

    private struct TextSendMilestones {
        let actionStartedAtUptimeNanoseconds: UInt64
        let recordID: UUID
        var durableCommitAtUptimeNanoseconds: UInt64?
        var visibleBubbleAtUptimeNanoseconds: UInt64?
    }

    private let logger = Logger(subsystem: "africa.kit.pay.ios", category: "LocalFirstMedia")
    private let persistenceWriter: LocalMediaDiagnosticsPersistenceWriter?
    private var recordingGeneration: UInt64 = 0
    private var isRecordingSuspended = false
    private var hasClearedSuspendedBoundary = false
    private var milestones: [UUID: Milestones] = [:]
    private var recipientDescriptorDates: [UUID: Date] = [:]
    private var diagnosticRecordIDs: [UUID: UUID] = [:]
    private var diagnosticRecordGenerations: [UUID: UInt64] = [:]
    private var textSendMilestones: [UUID: TextSendMilestones] = [:]
    private var diagnosticRecords: [LocalMediaStoredDiagnosticRecord]

    init(persistenceURL: URL? = nil) {
        persistenceWriter = persistenceURL.map {
            LocalMediaDiagnosticsPersistenceWriter(url: $0)
        }
        diagnosticRecords = Self.loadRecords(from: persistenceURL)
    }

    var reportRecordCount: Int {
        diagnosticRecords.count
    }

    func captureProducerScope() -> LocalMediaDiagnosticProducerScope? {
        guard !isRecordingSuspended else { return nil }
        return LocalMediaDiagnosticProducerScope(generation: recordingGeneration)
    }

    func begin(
        mediaID: UUID,
        at date: Date = Date(),
        direction: LocalMediaDiagnosticDirection = .outgoing,
        kind: KitChatMediaKind? = nil,
        byteCount: Int? = nil,
        duration: TimeInterval? = nil,
        producerScope: LocalMediaDiagnosticProducerScope?
    ) {
        guard accepts(producerScope) else { return }
        rehydrateOutgoingMilestonesIfNeeded(mediaID: mediaID)
        let alreadyHasDiagnosticRecord = diagnosticRecordIDs[mediaID]
            .flatMap { recordIndex(id: $0) } != nil
        upsertDiagnosticRecord(
            mediaID: mediaID,
            recordedAt: date,
            direction: direction,
            kind: kind,
            byteCount: byteCount,
            duration: duration
        )
        if var existing = milestones[mediaID] {
            existing.capturedAt = min(existing.capturedAt, date)
            milestones[mediaID] = existing
            return
        }
        // A completed item keeps its anonymous diagnostic mapping for late metadata discovery.
        // Repeated begin calls must not create a second timing sample for that same runtime ID.
        guard !alreadyHasDiagnosticRecord else { return }
        if milestones.count >= Self.maximumTrackedItems,
           let oldest = milestones.min(by: {
               $0.value.capturedAt < $1.value.capturedAt
           })?.key {
            milestones.removeValue(forKey: oldest)
        }
        milestones[mediaID] = Milestones(capturedAt: date)
    }

    func updateMetadata(
        mediaID: UUID,
        direction: LocalMediaDiagnosticDirection? = nil,
        kind: KitChatMediaKind? = nil,
        byteCount: Int? = nil,
        duration: TimeInterval? = nil,
        producerScope: LocalMediaDiagnosticProducerScope?
    ) {
        guard accepts(producerScope) else { return }
        rehydrateOutgoingMilestonesIfNeeded(mediaID: mediaID)
        guard diagnosticRecordGenerations[mediaID] == recordingGeneration,
              let recordID = diagnosticRecordIDs[mediaID],
              let index = recordIndex(id: recordID)
        else { return }
        mergeMetadata(
            into: &diagnosticRecords[index],
            direction: direction,
            kind: kind,
            byteCount: byteCount,
            duration: duration
        )
        persistRecords()
    }

    @discardableResult
    func markVisible(
        mediaID: UUID,
        at date: Date = Date(),
        producerScope: LocalMediaDiagnosticProducerScope?
    ) -> LocalMediaLatencyMeasurement? {
        guard accepts(producerScope) else { return nil }
        rehydrateOutgoingMilestonesIfNeeded(mediaID: mediaID)
        guard diagnosticRecordGenerations[mediaID] == recordingGeneration,
              var value = milestones[mediaID]
        else { return nil }
        guard value.visibleAt == nil else { return measurement(value) }
        value.visibleAt = date
        milestones[mediaID] = value
        let result = measurement(value)
        if let milliseconds = result.captureToVisibleMilliseconds {
            logger.info("capture_to_visible_ms=\(milliseconds, privacy: .public)")
            updateTimingRecord(mediaID: mediaID) {
                $0.captureToVisibleMilliseconds = milliseconds
            }
        }
        retireCompletedMeasurement(mediaID: mediaID, milestones: value)
        return result
    }

    @discardableResult
    func markPlayable(
        mediaID: UUID,
        at date: Date = Date(),
        producerScope: LocalMediaDiagnosticProducerScope?
    ) -> LocalMediaLatencyMeasurement? {
        guard accepts(producerScope) else { return nil }
        rehydrateOutgoingMilestonesIfNeeded(mediaID: mediaID)
        guard diagnosticRecordGenerations[mediaID] == recordingGeneration,
              var value = milestones[mediaID]
        else { return nil }
        guard value.playableAt == nil else { return measurement(value) }
        value.playableAt = date
        milestones[mediaID] = value
        let result = measurement(value)
        if let milliseconds = result.captureToPlayableMilliseconds {
            logger.info("capture_to_playable_ms=\(milliseconds, privacy: .public)")
            updateTimingRecord(mediaID: mediaID) {
                $0.captureToPlayableMilliseconds = milliseconds
            }
        }
        retireCompletedMeasurement(mediaID: mediaID, milestones: value)
        return result
    }

    @discardableResult
    func markEncrypted(
        mediaID: UUID,
        at date: Date = Date(),
        producerScope: LocalMediaDiagnosticProducerScope?
    ) -> LocalMediaLatencyMeasurement? {
        guard accepts(producerScope) else { return nil }
        rehydrateOutgoingMilestonesIfNeeded(mediaID: mediaID)
        guard diagnosticRecordGenerations[mediaID] == recordingGeneration,
              var value = milestones[mediaID]
        else { return nil }
        if value.encryptedAt == nil {
            value.encryptedAt = date
            milestones[mediaID] = value
        }
        let result = measurement(value)
        if let milliseconds = result.captureToEncryptedMilliseconds {
            logger.info("capture_to_encrypted_ms=\(milliseconds, privacy: .public)")
            updateTimingRecord(mediaID: mediaID) {
                $0.captureToEncryptedMilliseconds = milliseconds
            }
        }
        return result
    }

    @discardableResult
    func markServerAccepted(
        mediaID: UUID,
        at date: Date = Date(),
        producerScope: LocalMediaDiagnosticProducerScope?
    ) -> LocalMediaLatencyMeasurement? {
        guard accepts(producerScope) else { return nil }
        rehydrateOutgoingMilestonesIfNeeded(mediaID: mediaID)
        guard diagnosticRecordGenerations[mediaID] == recordingGeneration,
              var value = milestones[mediaID]
        else { return nil }
        if value.serverAcceptedAt == nil {
            value.serverAcceptedAt = date
            milestones[mediaID] = value
        }
        let result = measurement(value)
        if let milliseconds = result.captureToServerAcceptedMilliseconds {
            logger.info("capture_to_server_accepted_ms=\(milliseconds, privacy: .public)")
            updateTimingRecord(mediaID: mediaID) {
                $0.captureToServerAcceptedMilliseconds = milliseconds
            }
        }
        retireCompletedMeasurement(mediaID: mediaID, milestones: value)
        return result
    }

    /// A very fast local/LAN upload may receive server acceptance before SwiftUI mounts the
    /// staged bubble. Keep that sample until the two local-first milestones have also arrived;
    /// the global 256-entry bound still retires abandoned measurements deterministically.
    private func retireCompletedMeasurement(mediaID: UUID, milestones value: Milestones) {
        guard value.visibleAt != nil,
              value.playableAt != nil,
              value.serverAcceptedAt != nil
        else { return }
        milestones.removeValue(forKey: mediaID)
    }

    func beginRecipientHydration(
        mediaID: UUID,
        descriptorObservedAt: Date = Date(),
        kind: KitChatMediaKind? = nil,
        byteCount: Int? = nil,
        duration: TimeInterval? = nil,
        producerScope: LocalMediaDiagnosticProducerScope?
    ) {
        guard accepts(producerScope) else { return }
        upsertDiagnosticRecord(
            mediaID: mediaID,
            recordedAt: descriptorObservedAt,
            direction: .incoming,
            kind: kind,
            byteCount: byteCount,
            duration: duration
        )
        let persistedObservedAt = diagnosticRecordIDs[mediaID]
            .flatMap { recordID in recordIndex(id: recordID) }
            .map { diagnosticRecords[$0].recordedAt }
        recipientDescriptorDates[mediaID] = [
            recipientDescriptorDates[mediaID],
            persistedObservedAt,
            descriptorObservedAt
        ].compactMap { $0 }.min()
        if recipientDescriptorDates.count > Self.maximumTrackedItems,
           let oldest = recipientDescriptorDates.min(by: { $0.value < $1.value })?.key {
            recipientDescriptorDates.removeValue(forKey: oldest)
        }
    }

    @discardableResult
    func markRecipientHydrated(
        mediaID: UUID,
        at date: Date = Date(),
        producerScope: LocalMediaDiagnosticProducerScope?
    ) -> LocalMediaLatencyMeasurement? {
        guard accepts(producerScope) else { return nil }
        rehydrateRecipientDescriptorIfNeeded(mediaID: mediaID)
        guard diagnosticRecordGenerations[mediaID] == recordingGeneration,
              let observedAt = recipientDescriptorDates.removeValue(forKey: mediaID)
        else {
            return nil
        }
        let milliseconds = LocalMediaLatencyMeasurement.milliseconds(
            from: observedAt,
            to: date
        )
        logger.info("recipient_descriptor_to_local_ms=\(milliseconds, privacy: .public)")
        updateTimingRecord(mediaID: mediaID) {
            $0.recipientDescriptorToLocalMilliseconds = milliseconds
        }
        return LocalMediaLatencyMeasurement(
            recipientDescriptorToLocalMilliseconds: milliseconds
        )
    }

    func recordPlayback(
        outcome: LocalMediaPlaybackOutcome,
        mediaID: UUID,
        isOutgoing: Bool,
        byteCount: Int?,
        expectedDuration: TimeInterval?,
        position: TimeInterval?,
        producerScope: LocalMediaDiagnosticProducerScope?
    ) {
        guard accepts(producerScope) else { return }
        let source: LocalMediaStoredDiagnosticRecord?
        if diagnosticRecordGenerations[mediaID] == recordingGeneration {
            source = diagnosticRecordIDs[mediaID].flatMap { id in
                recordIndex(id: id).map { diagnosticRecords[$0] }
            }
        } else {
            source = nil
        }
        let duration = Self.validNonnegative(expectedDuration) ?? source?.durationSeconds
        let record = LocalMediaStoredDiagnosticRecord(
            localCorrelationTokenSHA256: nil,
            recordedAt: Date(),
            event: .videoPlayback,
            direction: isOutgoing ? .outgoing : .incoming,
            kind: .video,
            byteCount: Self.validByteCount(byteCount) ?? source?.byteCount,
            durationSeconds: duration,
            captureToVisibleMilliseconds: nil,
            captureToPlayableMilliseconds: nil,
            captureToEncryptedMilliseconds: nil,
            captureToServerAcceptedMilliseconds: nil,
            recipientDescriptorToLocalMilliseconds: nil,
            actionToDurableOutboxCommitMilliseconds: nil,
            actionToVisibleLocalBubbleMilliseconds: nil,
            playbackOutcome: outcome,
            playbackPositionSeconds: Self.validNonnegative(position)
        )
        append(record)
    }

    /// Begins one text-composer timing sample. The message UUID exists only in this process so UI,
    /// durable-store and render callbacks can meet; neither it nor a derivative is persisted or
    /// exported. Re-entering with the same UUID is an idempotent retry and keeps the original
    /// monotonic start rather than manufacturing a faster second sample.
    func beginTextSend(
        messageID: UUID,
        atUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        recordedAt: Date = Date(),
        producerScope: LocalMediaDiagnosticProducerScope?
    ) {
        guard accepts(producerScope), textSendMilestones[messageID] == nil else { return }
        let record = LocalMediaStoredDiagnosticRecord(
            localCorrelationTokenSHA256: nil,
            recordedAt: recordedAt,
            event: .textSendTiming,
            direction: .outgoing,
            kind: nil,
            byteCount: nil,
            durationSeconds: nil,
            captureToVisibleMilliseconds: nil,
            captureToPlayableMilliseconds: nil,
            captureToEncryptedMilliseconds: nil,
            captureToServerAcceptedMilliseconds: nil,
            recipientDescriptorToLocalMilliseconds: nil,
            actionToDurableOutboxCommitMilliseconds: nil,
            actionToVisibleLocalBubbleMilliseconds: nil,
            playbackOutcome: nil,
            playbackPositionSeconds: nil
        )
        textSendMilestones[messageID] = TextSendMilestones(
            actionStartedAtUptimeNanoseconds: atUptimeNanoseconds,
            recordID: record.id,
            durableCommitAtUptimeNanoseconds: nil,
            visibleBubbleAtUptimeNanoseconds: nil
        )
        append(record)
    }

    /// Marks the point at which the owner-bound message and outbox row have committed together.
    /// This hook deliberately precedes state reload, scheduling and every network operation.
    @discardableResult
    func markTextOutboxCommitted(
        messageID: UUID,
        atUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        producerScope: LocalMediaDiagnosticProducerScope?
    ) -> LocalTextSendLatencyMeasurement? {
        guard accepts(producerScope), var value = textSendMilestones[messageID] else { return nil }
        if value.durableCommitAtUptimeNanoseconds == nil {
            guard atUptimeNanoseconds >= value.actionStartedAtUptimeNanoseconds else { return nil }
            value.durableCommitAtUptimeNanoseconds = atUptimeNanoseconds
            textSendMilestones[messageID] = value
            if let milliseconds = Self.monotonicMilliseconds(
                from: value.actionStartedAtUptimeNanoseconds,
                to: atUptimeNanoseconds
            ) {
                logger.info("text_action_to_durable_outbox_commit_ms=\(milliseconds, privacy: .public)")
                updateTextSendTimingRecord(recordID: value.recordID) {
                    $0.actionToDurableOutboxCommitMilliseconds = milliseconds
                }
            }
        }
        return textSendMeasurement(value)
    }

    /// Records the first actual SwiftUI publication of the local bubble. A render callback cannot
    /// create a sample and cannot precede the durable commit milestone.
    @discardableResult
    func markTextBubbleVisible(
        messageID: UUID,
        atUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        producerScope: LocalMediaDiagnosticProducerScope?
    ) -> LocalTextSendLatencyMeasurement? {
        guard accepts(producerScope), var value = textSendMilestones[messageID],
              let durableAt = value.durableCommitAtUptimeNanoseconds
        else { return nil }
        if value.visibleBubbleAtUptimeNanoseconds == nil {
            guard atUptimeNanoseconds >= durableAt else { return nil }
            value.visibleBubbleAtUptimeNanoseconds = atUptimeNanoseconds
            textSendMilestones[messageID] = value
            if let milliseconds = Self.monotonicMilliseconds(
                from: value.actionStartedAtUptimeNanoseconds,
                to: atUptimeNanoseconds
            ) {
                logger.info("text_action_to_visible_local_bubble_ms=\(milliseconds, privacy: .public)")
                updateTextSendTimingRecord(recordID: value.recordID) {
                    $0.actionToVisibleLocalBubbleMilliseconds = milliseconds
                }
            }
        }
        return textSendMeasurement(value)
    }

    /// Removes only a never-committed attempt when the composer contents change. A durable row is
    /// retained even if navigation is interrupted, because it remains valid local-queue evidence.
    func abandonUncommittedTextSend(
        messageID: UUID,
        producerScope: LocalMediaDiagnosticProducerScope?
    ) {
        guard accepts(producerScope),
              let value = textSendMilestones[messageID],
              value.durableCommitAtUptimeNanoseconds == nil
        else { return }
        textSendMilestones.removeValue(forKey: messageID)
        diagnosticRecords.removeAll { $0.id == value.recordID }
        persistRecords()
    }

    func exportReport() -> String {
        let info = Bundle.main.infoDictionary
        let exportedRecords = diagnosticRecords.map { record in
            ExportDiagnosticRecord(
                recordedAt: record.recordedAt,
                event: record.event,
                direction: record.direction,
                kind: record.kind,
                byteCount: record.byteCount,
                durationSeconds: record.durationSeconds,
                captureToVisibleMilliseconds: record.captureToVisibleMilliseconds,
                captureToPlayableMilliseconds: record.captureToPlayableMilliseconds,
                captureToEncryptedMilliseconds: record.captureToEncryptedMilliseconds,
                captureToServerAcceptedMilliseconds: record.captureToServerAcceptedMilliseconds,
                recipientDescriptorToLocalMilliseconds: record.recipientDescriptorToLocalMilliseconds,
                actionToDurableOutboxCommitMilliseconds:
                    record.actionToDurableOutboxCommitMilliseconds,
                actionToVisibleLocalBubbleMilliseconds:
                    record.actionToVisibleLocalBubbleMilliseconds,
                playbackOutcome: record.playbackOutcome,
                playbackPositionSeconds: record.playbackPositionSeconds
            )
        }
        let report = ExportReport(
            schemaVersion: 1,
            generatedAt: Date(),
            application: ExportApplication(
                version: info?["CFBundleShortVersionString"] as? String ?? "unknown",
                build: info?["CFBundleVersion"] as? String ?? "unknown",
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
            ),
            privacy: ExportPrivacy(
                notice: "This report contains only bounded event times, local text-send performance measurements, media performance measurements and coarse media metadata.",
                excludedData: [
                    "message and caption content",
                    "conversation and contact identifiers",
                    "media identifiers, filenames and URLs",
                    "MIME payloads and media content"
                ]
            ),
            recordLimit: Self.maximumTrackedItems,
            recordCount: exportedRecords.count,
            records: exportedRecords
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{\"error\":\"Media diagnostics could not be encoded.\"}"
        }
        return text
    }

    @discardableResult
    func clearReport() -> Bool {
        let persistenceWasCleared = persistenceWriter?.clear() ?? true
        milestones.removeAll()
        recipientDescriptorDates.removeAll()
        diagnosticRecordIDs.removeAll()
        diagnosticRecordGenerations.removeAll()
        textSendMilestones.removeAll()
        diagnosticRecords.removeAll()
        return persistenceWasCleared
    }

    /// Closes the current account generation before asynchronous media producers are cancelled.
    /// Any late callback is ignored until a successfully cleared account boundary resumes capture.
    @discardableResult
    func suspendRecordingAndClearReport() -> Bool {
        isRecordingSuspended = true
        recordingGeneration &+= 1
        let cleared = clearReport()
        hasClearedSuspendedBoundary = cleared
        return cleared
    }

    func resumeRecordingForFreshAccount() {
        guard isRecordingSuspended, hasClearedSuspendedBoundary else { return }
        recordingGeneration &+= 1
        hasClearedSuspendedBoundary = false
        isRecordingSuspended = false
    }

    /// Tests that recreate the monitor immediately can wait for the same serialized writer used
    /// in production. Ordinary capture and playback paths never call this blocking hook.
    func flushPendingPersistence() {
        persistenceWriter?.flush()
    }

    private func measurement(_ value: Milestones) -> LocalMediaLatencyMeasurement {
        LocalMediaLatencyMeasurement(
            captureToVisibleMilliseconds: value.visibleAt.map {
                LocalMediaLatencyMeasurement.milliseconds(from: value.capturedAt, to: $0)
            },
            captureToPlayableMilliseconds: value.playableAt.map {
                LocalMediaLatencyMeasurement.milliseconds(from: value.capturedAt, to: $0)
            },
            captureToEncryptedMilliseconds: value.encryptedAt.map {
                LocalMediaLatencyMeasurement.milliseconds(from: value.capturedAt, to: $0)
            },
            captureToServerAcceptedMilliseconds: value.serverAcceptedAt.map {
                LocalMediaLatencyMeasurement.milliseconds(from: value.capturedAt, to: $0)
            },
            recipientDescriptorToLocalMilliseconds: nil
        )
    }

    private func textSendMeasurement(
        _ value: TextSendMilestones
    ) -> LocalTextSendLatencyMeasurement {
        LocalTextSendLatencyMeasurement(
            actionToDurableOutboxCommitMilliseconds:
                value.durableCommitAtUptimeNanoseconds.flatMap {
                    Self.monotonicMilliseconds(
                        from: value.actionStartedAtUptimeNanoseconds,
                        to: $0
                    )
                },
            actionToVisibleLocalBubbleMilliseconds:
                value.visibleBubbleAtUptimeNanoseconds.flatMap {
                    Self.monotonicMilliseconds(
                        from: value.actionStartedAtUptimeNanoseconds,
                        to: $0
                    )
                }
        )
    }

    private func upsertDiagnosticRecord(
        mediaID: UUID,
        recordedAt: Date,
        direction: LocalMediaDiagnosticDirection,
        kind: KitChatMediaKind?,
        byteCount: Int?,
        duration: TimeInterval?
    ) {
        bindPersistedTimingRecordIfNeeded(mediaID: mediaID)
        if let recordID = diagnosticRecordIDs[mediaID],
           let index = recordIndex(id: recordID) {
            mergeMetadata(
                into: &diagnosticRecords[index],
                direction: direction,
                kind: kind,
                byteCount: byteCount,
                duration: duration
            )
            persistRecords()
            return
        }
        let record = LocalMediaStoredDiagnosticRecord(
            localCorrelationTokenSHA256: Self.correlationToken(for: mediaID),
            recordedAt: recordedAt,
            event: .mediaTiming,
            direction: direction,
            kind: kind,
            byteCount: Self.validByteCount(byteCount),
            durationSeconds: Self.validNonnegative(duration),
            captureToVisibleMilliseconds: nil,
            captureToPlayableMilliseconds: nil,
            captureToEncryptedMilliseconds: nil,
            captureToServerAcceptedMilliseconds: nil,
            recipientDescriptorToLocalMilliseconds: nil,
            actionToDurableOutboxCommitMilliseconds: nil,
            actionToVisibleLocalBubbleMilliseconds: nil,
            playbackOutcome: nil,
            playbackPositionSeconds: nil
        )
        diagnosticRecordIDs[mediaID] = record.id
        diagnosticRecordGenerations[mediaID] = recordingGeneration
        append(record)
    }

    private func bindPersistedTimingRecordIfNeeded(mediaID: UUID) {
        guard diagnosticRecordIDs[mediaID] == nil else { return }
        let token = Self.correlationToken(for: mediaID)
        guard let record = diagnosticRecords.last(where: {
            $0.event == .mediaTiming && $0.localCorrelationTokenSHA256 == token
        }) else { return }
        diagnosticRecordIDs[mediaID] = record.id
        diagnosticRecordGenerations[mediaID] = recordingGeneration
    }

    private func rehydrateOutgoingMilestonesIfNeeded(mediaID: UUID) {
        guard diagnosticRecordIDs[mediaID] == nil else { return }
        bindPersistedTimingRecordIfNeeded(mediaID: mediaID)
        guard let recordID = diagnosticRecordIDs[mediaID],
              let index = recordIndex(id: recordID),
              diagnosticRecords[index].direction == .outgoing
        else { return }
        let record = diagnosticRecords[index]
        func date(milliseconds: Double?) -> Date? {
            milliseconds.map { record.recordedAt.addingTimeInterval($0 / 1_000) }
        }
        milestones[mediaID] = Milestones(
            capturedAt: record.recordedAt,
            visibleAt: date(milliseconds: record.captureToVisibleMilliseconds),
            playableAt: date(milliseconds: record.captureToPlayableMilliseconds),
            encryptedAt: date(milliseconds: record.captureToEncryptedMilliseconds),
            serverAcceptedAt: date(milliseconds: record.captureToServerAcceptedMilliseconds)
        )
    }

    private func rehydrateRecipientDescriptorIfNeeded(mediaID: UUID) {
        guard recipientDescriptorDates[mediaID] == nil else { return }
        bindPersistedTimingRecordIfNeeded(mediaID: mediaID)
        guard let recordID = diagnosticRecordIDs[mediaID],
              let index = recordIndex(id: recordID),
              diagnosticRecords[index].direction == .incoming,
              diagnosticRecords[index].recipientDescriptorToLocalMilliseconds == nil
        else { return }
        recipientDescriptorDates[mediaID] = diagnosticRecords[index].recordedAt
    }

    private func mergeMetadata(
        into record: inout LocalMediaStoredDiagnosticRecord,
        direction: LocalMediaDiagnosticDirection?,
        kind: KitChatMediaKind?,
        byteCount: Int?,
        duration: TimeInterval?
    ) {
        if let direction { record.direction = direction }
        if let kind { record.kind = kind }
        if let byteCount = Self.validByteCount(byteCount) { record.byteCount = byteCount }
        if let duration = Self.validNonnegative(duration) { record.durationSeconds = duration }
    }

    private func updateTimingRecord(
        mediaID: UUID,
        update: (inout LocalMediaStoredDiagnosticRecord) -> Void
    ) {
        guard let recordID = diagnosticRecordIDs[mediaID],
              let index = recordIndex(id: recordID)
        else { return }
        update(&diagnosticRecords[index])
        persistRecords()
    }

    private func updateTextSendTimingRecord(
        recordID: UUID,
        update: (inout LocalMediaStoredDiagnosticRecord) -> Void
    ) {
        guard let index = recordIndex(id: recordID),
              diagnosticRecords[index].event == .textSendTiming
        else { return }
        update(&diagnosticRecords[index])
        persistRecords()
    }

    private func recordIndex(id: UUID) -> Int? {
        diagnosticRecords.firstIndex { $0.id == id }
    }

    private func append(_ record: LocalMediaStoredDiagnosticRecord) {
        diagnosticRecords.append(record)
        if diagnosticRecords.count > Self.maximumTrackedItems {
            diagnosticRecords.removeFirst(diagnosticRecords.count - Self.maximumTrackedItems)
            let retainedIDs = Set(diagnosticRecords.map(\.id))
            diagnosticRecordIDs = diagnosticRecordIDs.filter { retainedIDs.contains($0.value) }
            let retainedMediaIDs = Set(diagnosticRecordIDs.keys)
            diagnosticRecordGenerations = diagnosticRecordGenerations.filter {
                retainedMediaIDs.contains($0.key)
            }
            textSendMilestones = textSendMilestones.filter {
                retainedIDs.contains($0.value.recordID)
            }
        }
        persistRecords()
    }

    private func persistRecords() {
        persistenceWriter?.submit(
            LocalMediaPersistedDiagnostics(schemaVersion: 1, records: diagnosticRecords)
        )
    }

    private static func loadRecords(
        from persistenceURL: URL?
    ) -> [LocalMediaStoredDiagnosticRecord] {
        guard let persistenceURL,
              let data = try? Data(contentsOf: persistenceURL)
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let payload = try? decoder.decode(
            LocalMediaPersistedDiagnostics.self,
            from: data
        ),
              payload.schemaVersion == 1
        else { return [] }
        return Array(payload.records.suffix(maximumTrackedItems))
    }

    private static func defaultPersistenceURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("MediaDiagnostics", isDirectory: true)
            .appendingPathComponent("local-media-report.json", isDirectory: false)
    }

    private static func validByteCount(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func validNonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// Diagnostics retain millisecond buckets rather than raw clocks, and cap anomalous samples
    /// at ten minutes. Neither uptime nor the cap reveals account or message identity.
    private static func monotonicMilliseconds(from start: UInt64, to end: UInt64) -> Double? {
        guard end >= start else { return nil }
        let elapsed = min(end - start, 600_000_000_000)
        return (Double(elapsed) / 1_000_000).rounded()
    }

    private static func correlationToken(for mediaID: UUID) -> String {
        SHA256.hash(data: Data(mediaID.uuidString.lowercased().utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func accepts(_ scope: LocalMediaDiagnosticProducerScope?) -> Bool {
        !isRecordingSuspended && scope?.generation == recordingGeneration
    }
}

/// Classifies an end-to-end encrypted attachment by its wire MIME type.
///
/// The v1 `KITMEDIA1` descriptor deliberately carries no dedicated kind field, so the MIME type
/// in `mt` is the single cross-platform source of truth for how a bubble should render.
enum KitChatMediaKind: String, Codable, CaseIterable, Sendable {
    case image
    case voice
    case audio
    case video
    case document

    init(mediaType: String) {
        let normalized = mediaType.lowercased()
        if normalized.hasPrefix("image/") {
            self = .image
        } else if normalized == "audio/mp4" {
            // Kit voice notes are recorded and assembled as canonical M4A. Other supported audio
            // MIME types are imported files and must not be presented as microphone recordings.
            self = .voice
        } else if normalized.hasPrefix("audio/") {
            self = .audio
        } else if normalized.hasPrefix("video/") {
            self = .video
        } else {
            self = .document
        }
    }

    var symbolName: String {
        switch self {
        case .image: "photo.fill"
        case .voice: "mic.fill"
        case .audio: "music.note"
        case .video: "video.fill"
        case .document: "doc.fill"
        }
    }

    var previewLabel: String {
        switch self {
        case .image: "Photo"
        case .voice: "Voice note"
        case .audio: "Audio"
        case .video: "Video"
        case .document: "Document"
        }
    }
}

/// Client-side limits for encrypted chat media. The cipher and wire caps in
/// `SecureMessagingWire` are the hard bound; these values keep each media kind
/// inside that bound with kind-appropriate ceilings.
enum KitChatMediaLimits {
    /// Hard per-file transfer cap shared by every media kind (matches the attachment cipher).
    static let maximumTransferBytes = SecureMediaAttachmentCipher.maximumPlaintextBytes

    /// Images are re-encoded before send, so they stay small for cheap offline history.
    static let imageEncodeTargetBytes = 10 * 1_024 * 1_024

    /// Plaintext blobs at or under this size may live inside the encrypted state file for
    /// instant offline access. Anything larger goes to the encrypted media file cache so a
    /// wallet-balance update never rewrites hundreds of megabytes.
    static let maximumInlineCacheBytes = 4 * 1_024 * 1_024

    static let maximumTransferLabel = "200 MB"

    /// A local video may temporarily exceed the wire ceiling while the user trims it. Keeping
    /// that source app-owned and protected preserves local-first editing; only the resulting clip
    /// may enter a message/outbox record and it must still satisfy `maximumTransferBytes`.
    static let maximumEditableLocalVideoBytes = 1_073_741_824

    static func fits(_ byteCount: Int, kind _: KitChatMediaKind) -> Bool {
        byteCount > 0 && byteCount <= maximumTransferBytes
    }

    static func fitsLocalOriginal(byteCount: Int, mediaType: String) -> Bool {
        if mediaType.lowercased().hasPrefix("video/") {
            return byteCount > 0 && byteCount <= maximumEditableLocalVideoBytes
        }
        return fits(byteCount, kind: KitChatMediaKind(mediaType: mediaType))
    }

    static func shouldCacheInline(byteCount: Int) -> Bool {
        byteCount > 0 && byteCount <= maximumInlineCacheBytes
    }
}

enum LegacyReceivedVideoMigrationPolicy {
    enum Source: Equatable {
        case streamedRemote
        case smallLocalBlob
        case unavailable
    }

    static func source(
        plaintextByteCount: Int,
        allowsDownload: Bool,
        isOnline: Bool,
        secureMessagingAvailable: Bool,
        hasRemoteStorageKey: Bool,
        hasAuthenticatedSession: Bool
    ) -> Source {
        if allowsDownload,
           isOnline,
           secureMessagingAvailable,
           hasRemoteStorageKey,
           hasAuthenticatedSession {
            return .streamedRemote
        }
        return KitChatMediaLimits.shouldCacheInline(byteCount: plaintextByteCount)
            ? .smallLocalBlob
            : .unavailable
    }
}

/// Family-wide safe projection of a message body for every presentation surface: bubbles,
/// list previews, reply quotes, scheduled previews, accessibility labels, copy, and search.
///
/// This is the single place that decides what a `KITMEDIA` body may show. Raw reserved-family
/// text is never returned from any method here — a descriptor carries attachment key material,
/// so an unparseable or future-version family body renders only as the generic placeholder,
/// and the only user-visible prose a valid descriptor contributes is its caption. All of it is
/// feature-flag independent (§4 rule 6): receive-side safety never consults a capability.
enum KitMediaMessageFamilyPresentation {
    /// §4 rule 6 placeholder for any reserved-family body this build cannot strictly parse.
    static let genericAttachmentLabel = "Attachment"

    /// How a body may render. Exactly one case applies; `confinedPlaceholder` is terminal —
    /// callers must show `genericAttachmentLabel` and expose nothing else of the body.
    enum BodyContent {
        case text(String)
        case mediaV1(KitMediaMessageDescriptor)
        case mediaV2(KitMediaMessageV2Descriptor)
        case confinedPlaceholder
    }

    static func content(for body: String) -> BodyContent {
        if let v2 = KitMediaMessageV2Descriptor.parse(body) { return .mediaV2(v2) }
        if let v1 = KitMediaMessageDescriptor.parse(body) { return .mediaV1(v1) }
        if KitMediaMessageFamilyPolicy.isReservedFamilyText(body) { return .confinedPlaceholder }
        return .text(body)
    }

    /// One safe label for an ordered batch: "3 Photos" when every item shares a kind,
    /// "4 Attachments" for a mixed batch. §4 keeps `n` in 2…8, so the plural always reads.
    static func summaryLabel(forMediaTypes mediaTypes: [String]) -> String {
        let kinds = Set(mediaTypes.map { KitChatMediaKind(mediaType: $0) })
        guard mediaTypes.count > 1 else {
            return kinds.first?.previewLabel ?? genericAttachmentLabel
        }
        if kinds.count == 1, let kind = kinds.first {
            return "\(mediaTypes.count) \(kind.previewLabel)s"
        }
        return "\(mediaTypes.count) \(genericAttachmentLabel)s"
    }

    static func summaryLabel(for descriptor: KitMediaMessageV2Descriptor) -> String {
        summaryLabel(forMediaTypes: descriptor.items.map(\.mediaType))
    }

    /// §8 reply-quote label for an ordered batch: the first item's kind leads, the rest ride as
    /// a count, and a validated caption follows as garnish — "Video +1 · Family photos", matching
    /// Android's mediaAlbumQuoteLabel. The caption rides byte-exact: a validated v2 caption is
    /// canonical by construction (nil/non-nil is the whole test), and the contract's boundary
    /// rule deliberately admits scalars — NBSP, U+0085, U+2028/U+2029 — that Foundation trims
    /// would mutate or drop.
    static func mediaAlbumQuoteLabel(forMediaTypes mediaTypes: [String], caption: String?) -> String {
        let lead = mediaTypes.first.map { KitChatMediaKind(mediaType: $0).previewLabel }
            ?? genericAttachmentLabel
        let label = mediaTypes.count > 1 ? "\(lead) +\(mediaTypes.count - 1)" : lead
        guard let caption else { return label }
        return "\(label) · \(caption)"
    }

    /// One-line preview: media bodies read label-first with the caption as garnish; ordinary
    /// text reads verbatim; confined bodies read as the bare placeholder.
    static func previewText(for body: String) -> String {
        switch content(for: body) {
        case .text(let text):
            return text
        case .mediaV1(let media):
            let label = KitChatMediaKind(mediaType: media.mediaType).previewLabel
            if let caption = media.caption, !caption.isEmpty { return "\(label) · \(caption)" }
            return label
        case .mediaV2(let media):
            let label = summaryLabel(for: media)
            if let caption = media.caption, !caption.isEmpty { return "\(label) · \(caption)" }
            return label
        case .confinedPlaceholder:
            return genericAttachmentLabel
        }
    }

    /// The only text of a media body that may leave the bubble — reach the pasteboard, match
    /// in-chat search, or seed a share — is a valid descriptor's caption. Ordinary text passes
    /// through; a family body without a parseable caption yields nil, never the raw body.
    static func safeUserText(for body: String) -> String? {
        switch content(for: body) {
        case .text(let text):
            return text
        case .mediaV1(let media):
            return media.caption?.isEmpty == false ? media.caption : nil
        case .mediaV2(let media):
            return media.caption?.isEmpty == false ? media.caption : nil
        case .confinedPlaceholder:
            return nil
        }
    }
}

/// One-line conversation-list preview for any message body, including media descriptors.
enum KitChatMessagePreview {
    static func text(for body: String) -> String {
        KitMediaMessageFamilyPresentation.previewText(for: body)
    }

    static func symbolName(for body: String) -> String? {
        switch KitMediaMessageFamilyPresentation.content(for: body) {
        case .text:
            return nil
        case .mediaV1(let media):
            return KitChatMediaKind(mediaType: media.mediaType).symbolName
        case .mediaV2(let media):
            let kinds = Set(media.items.map { KitChatMediaKind(mediaType: $0.mediaType) })
            if kinds.count == 1, let kind = kinds.first { return kind.symbolName }
            return "paperclip"
        case .confinedPlaceholder:
            return "paperclip"
        }
    }
}

/// Ordering and selection policy for the chats list: pinned conversations first
/// (most recent activity first within each group).
enum ConversationListPolicy {
    static func ordered(
        _ conversations: [Conversation],
        pinnedIds: Set<String>
    ) -> [Conversation] {
        conversations.sorted { first, second in
            let firstPinned = pinnedIds.contains(first.id)
            let secondPinned = pinnedIds.contains(second.id)
            if firstPinned != secondPinned { return firstPinned }
            if first.updatedAt != second.updatedAt { return first.updatedAt > second.updatedAt }
            return first.id < second.id
        }
    }

    static func togglingMembership(_ id: String, in ids: [String]?) -> [String] {
        var set = ids ?? []
        if let index = set.firstIndex(of: id) {
            set.remove(at: index)
        } else {
            set.append(id)
        }
        return set
    }
}
