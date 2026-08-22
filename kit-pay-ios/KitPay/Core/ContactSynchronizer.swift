import BackgroundTasks
import Contacts
import Foundation

enum ContactAccessState: Equatable, Sendable {
    case notDetermined
    case allowed
    case limited
    case denied
}

enum ContactSyncPhase: String, Equatable, Sendable {
    case preparing
    case uploading
    case finalizing
    case refreshing
    case complete
}

enum ContactSyncSnapshotScope: String, Codable, Equatable, Sendable {
    /// Authoritative replacement of the user's visible address-book snapshot.
    case full
    /// Upsert only; never deletes contacts hidden by limited iOS authorization.
    case partial
}

struct ContactSyncProgress: Equatable, Sendable {
    let phase: ContactSyncPhase
    let completedUnitCount: Int
    let totalUnitCount: Int

    var fractionCompleted: Double? {
        guard totalUnitCount > 0 else { return nil }
        return min(1, max(0, Double(completedUnitCount) / Double(totalUnitCount)))
    }
}

enum AutomaticContactSyncState: Equatable, Sendable {
    case idle
    case requestingPermission
    case denied
    case syncing(ContactSyncProgress)
    case synced(uploaded: Int, matched: Int, limitedAccess: Bool)
    case failed(String)

    var isSyncing: Bool {
        switch self {
        case .requestingPermission, .syncing: true
        default: false
        }
    }
}

/// The only contact-sync states that need to interrupt a recipient picker.
/// Permission prompts, progress, and successful refreshes stay silent because
/// contact discovery is automatic.
enum ContactSyncRecoveryPresentation: Equatable, Sendable {
    case openSettings
    case retry(message: String)

    static func presentation(
        for state: AutomaticContactSyncState
    ) -> ContactSyncRecoveryPresentation? {
        switch state {
        case .denied:
            .openSettings
        case .failed(let message):
            .retry(message: message)
        case .idle, .requestingPermission, .syncing, .synced:
            nil
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .openSettings: "contact-sync-recovery.open-settings"
        case .retry: "contact-sync-recovery.retry"
        }
    }
}

@MainActor
final class ContactBackgroundRefreshScheduler {
    static let shared = ContactBackgroundRefreshScheduler()
    static let identifier = "africa.kit.pay.ios.contacts-refresh"

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
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

protocol DeviceContactsProviding: Sendable {
    func accessState() -> ContactAccessState
    func requestAccess() async throws -> Bool
    func phoneNumbers() async throws -> [DeviceContactPhone]
}

final class SystemDeviceContactsProvider: DeviceContactsProviding, @unchecked Sendable {
    private let store: CNContactStore

    init(store: CNContactStore = CNContactStore()) {
        self.store = store
    }

    func accessState() -> ContactAccessState {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if #available(iOS 18.0, *), status == .limited { return .limited }

        switch status {
        case .authorized: return .allowed
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        default: return .denied
        }
    }

    func requestAccess() async throws -> Bool {
        try await store.requestAccess(for: .contacts)
    }

    func phoneNumbers() async throws -> [DeviceContactPhone] {
        let worker = Task.detached(priority: .userInitiated) { [self] in
            let keys: [CNKeyDescriptor] = [
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                CNContactPhoneNumbersKey as CNKeyDescriptor,
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            request.unifyResults = true
            request.sortOrder = .userDefault

            var values: [DeviceContactPhone] = []
            try store.enumerateContacts(with: request) { contact, stop in
                if Task.isCancelled {
                    stop.pointee = true
                    return
                }
                let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
                for number in contact.phoneNumbers {
                    values.append(
                        DeviceContactPhone(name: name, phone: number.value.stringValue)
                    )
                }
            }
            try Task.checkCancellation()
            return values
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

struct ContactSyncOutcome: Sendable {
    let contacts: [WalletContactDTO]
    let uploadedCount: Int
    let omittedCount: Int
    let limitedAccess: Bool
}

enum ContactSyncError: LocalizedError, Equatable {
    case accessDenied
    case snapshotTooLarge(limit: Int)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            "Contacts access is off. You can enable it for Kit Pay in Settings."
        case .snapshotTooLarge(let limit):
            "This address book has more than \(limit.formatted()) phone numbers. Nothing was changed on Kit Pay."
        }
    }
}

struct ContactSyncCoordinator: Sendable {
    private let source: any DeviceContactsProviding
    private let uploader: any ContactSyncUploading

    init(source: any DeviceContactsProviding, uploader: any ContactSyncUploading) {
        self.source = source
        self.uploader = uploader
    }

    /// This is deliberately the only upload entry point. Call it directly from
    /// a user-initiated control; constructing the coordinator performs no work.
    func syncAfterExplicitUserAction(
        context: PhoneIdentityContext = .uganda
    ) async throws -> ContactSyncOutcome {
        let consented: Bool
        let limitedAccess: Bool
        switch source.accessState() {
        case .allowed:
            consented = true
            limitedAccess = false
        case .limited:
            consented = true
            limitedAccess = true
        case .notDetermined:
            consented = try await source.requestAccess()
            limitedAccess = false
        case .denied:
            consented = false
            limitedAccess = false
        }

        guard consented else { throw ContactSyncError.accessDenied }

        let snapshot = ContactSyncNormalizer.snapshot(
            from: try await source.phoneNumbers(),
            context: context
        )
        guard snapshot.omittedCount == 0 else {
            throw ContactSyncError.snapshotTooLarge(limit: ContactSyncSnapshot.serverLimit)
        }
        let response = try await uploader.syncContacts(snapshot.contacts)
        return ContactSyncOutcome(
            contacts: response.items ?? [],
            uploadedCount: snapshot.contacts.count,
            omittedCount: snapshot.omittedCount,
            limitedAccess: limitedAccess
        )
    }
}
