import CryptoKit
import Foundation

/// Non-secret, immutable identity attached to every background ciphertext PATCH. The operating
/// system persists `URLSessionTask.taskDescription` with the task, which lets a relaunched process
/// prove that it is reattaching to the exact account/session/upload/offset it intended. Raw account
/// ids, session ids and bearer tokens are deliberately reduced to one-way fingerprints.
struct MessagingBackgroundUploadContext: Codable, Equatable, Sendable {
    static let taskDescriptionPrefix = "kit-media-background-upload-v1:"

    let version: Int
    let accountFingerprint: String
    let sessionFingerprint: String
    let accessTokenFingerprint: String
    let uploadID: String
    let byteOffset: Int64
    let byteSize: Int
    let ciphertextSHA256: String

    init?(
        accountID: String,
        sessionID: String,
        accessToken: String,
        uploadID: String,
        byteOffset: Int64,
        byteSize: Int,
        ciphertextSHA256: String
    ) {
        guard SecureMessagingWirePolicy.isCanonicalUUID(accountID.lowercased()),
              SessionRefreshPolicy.isValidSessionID(sessionID),
              !accessToken.isEmpty,
              SecureMessagingWirePolicy.isCanonicalUUID(uploadID),
              byteOffset >= 0,
              (1 ... MessagingResumableAttachmentPolicy.maximumChunkBytes).contains(byteSize),
              SecureMessagingWirePolicy.isLowercaseSHA256(ciphertextSHA256)
        else { return nil }
        version = 1
        accountFingerprint = Self.fingerprint(accountID.lowercased())
        sessionFingerprint = Self.fingerprint(sessionID.lowercased())
        accessTokenFingerprint = Self.fingerprint(accessToken)
        self.uploadID = uploadID
        self.byteOffset = byteOffset
        self.byteSize = byteSize
        self.ciphertextSHA256 = ciphertextSHA256
    }

    var isStructurallyValid: Bool {
        version == 1
            && Self.isFingerprint(accountFingerprint)
            && Self.isFingerprint(sessionFingerprint)
            && Self.isFingerprint(accessTokenFingerprint)
            && SecureMessagingWirePolicy.isCanonicalUUID(uploadID)
            && byteOffset >= 0
            && (1 ... MessagingResumableAttachmentPolicy.maximumChunkBytes).contains(byteSize)
            && SecureMessagingWirePolicy.isLowercaseSHA256(ciphertextSHA256)
    }

    /// Stable across access-token rotation. This serializes all attempts for one server offset so
    /// a foreground retry cannot race a still-running task created by the prior token generation.
    var logicalTransferID: String {
        Self.fingerprint([
            accountFingerprint,
            sessionFingerprint,
            uploadID,
            String(byteOffset),
            String(byteSize),
            ciphertextSHA256,
        ].joined(separator: "\u{0}"))
    }

    /// Includes the token generation. A durable 401 from an old token must never mask a replay
    /// made with the refreshed token, while a durable success remains tied to its exact attempt.
    var attemptID: String {
        Self.fingerprint(logicalTransferID + "\u{0}" + accessTokenFingerprint)
    }

    func describesSameTransfer(as other: Self) -> Bool {
        logicalTransferID == other.logicalTransferID
            && accountFingerprint == other.accountFingerprint
            && sessionFingerprint == other.sessionFingerprint
            && uploadID == other.uploadID
            && byteOffset == other.byteOffset
            && byteSize == other.byteSize
            && ciphertextSHA256 == other.ciphertextSHA256
    }

    var taskDescription: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard isStructurallyValid,
              let encoded = try? encoder.encode(self)
        else { return nil }
        return Self.taskDescriptionPrefix + Self.base64URL(encoded)
    }

    static func decode(taskDescription: String?) -> Self? {
        guard let taskDescription,
              taskDescription.hasPrefix(taskDescriptionPrefix),
              let data = decodeBase64URL(String(taskDescription.dropFirst(taskDescriptionPrefix.count))),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.isStructurallyValid,
              value.taskDescription == taskDescription
        else { return nil }
        return value
    }

    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isFingerprint(_ value: String) -> Bool {
        SecureMessagingWirePolicy.isLowercaseSHA256(value)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        guard !value.isEmpty else { return nil }
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64.append(String(repeating: "=", count: 4 - remainder)) }
        return Data(base64Encoded: base64)
    }
}

/// Durable completion handed back to the authenticated API layer. The response is bounded before
/// it is persisted, and every consumer re-validates the enclosing media/upload metadata before
/// advancing an offset.
struct MessagingBackgroundUploadResult: Codable, Equatable, Sendable {
    static let maximumResponseBytes = 1 * 1_024 * 1_024

    let context: MessagingBackgroundUploadContext
    let statusCode: Int?
    let headers: [String: String]
    let body: Data
    let errorDomain: String?
    let errorCode: Int?
    let completedAt: Date

    var isStructurallyValid: Bool {
        context.isStructurallyValid
            && statusCode.map({ (100 ... 599).contains($0) }) ?? true
            && body.count <= Self.maximumResponseBytes
            && headers.count <= 64
            && headers.allSatisfy {
                !$0.key.isEmpty && $0.key.utf8.count <= 128 && $0.value.utf8.count <= 4_096
            }
            && ((errorDomain == nil) == (errorCode == nil))
            && ((statusCode != nil) || (errorDomain != nil))
    }

    func transportError() -> Error? {
        guard let errorDomain, let errorCode else { return nil }
        if errorDomain == NSURLErrorDomain {
            return URLError(URLError.Code(rawValue: errorCode))
        }
        return NSError(domain: errorDomain, code: errorCode)
    }
}

/// Owns the one background URLSession reserved for E2EE attachment chunks. Each chunk is staged
/// as a protected file before `uploadTask(fromFile:)` is created. Both the system task description
/// and the completion ledger survive process termination; a relaunched coordinator reattaches to
/// an in-flight task or consumes the durable response and advances the authoritative server
/// offset exactly once.
final class MessagingBackgroundAttachmentUploader: NSObject, URLSessionDataDelegate {
    static let shared = MessagingBackgroundAttachmentUploader()
    static let sessionIdentifier = "africa.kit.pay.ios.messaging-media-upload-v1"

    private typealias UploadContinuation = CheckedContinuation<
        MessagingBackgroundUploadResult,
        Error
    >

    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "africa.kit.pay.ios.messaging-media-upload.delegate"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    private var responseBodies: [Int: Data] = [:]
    private var forcedErrors: [Int: Error] = [:]
    private var ignoredDuplicateTaskIDs: Set<Int> = []
    private var taskContexts: [Int: MessagingBackgroundUploadContext] = [:]
    private var waiters: [String: [UploadContinuation]] = [:]
    private var startsInFlight: Set<String> = []
    private var revokedBindings: Set<String> = []
    private var backgroundEventsCompletionHandler: (() -> Void)?
    private var backgroundEventsFinished = false

    private override init() {
        super.init()
    }

    static func handlesSession(identifier: String) -> Bool {
        identifier == sessionIdentifier
    }

    /// Reconnect the delegate to tasks restored by iOS and remove crash leftovers that no live
    /// task or durable completion can own. This does not require an authenticated account.
    func prepareForApplicationLaunch() {
        let session = self.session
        session.getAllTasks { [weak self] tasks in
            self?.delegateQueue.addOperation { [weak self] in
                guard let self else { return }
                var activeAttemptIDs: Set<String> = []
                for task in tasks {
                    guard let context = MessagingBackgroundUploadContext.decode(
                        taskDescription: task.taskDescription
                    ) else {
                        task.cancel()
                        continue
                    }
                    activeAttemptIDs.insert(context.attemptID)
                    self.taskContexts[task.taskIdentifier] = context
                    task.resume()
                }
                self.removeOrphanedChunkFiles(retaining: activeAttemptIDs)
                self.pruneDurableResults()
            }
        }
    }

    func setBackgroundEventsCompletionHandler(_ completionHandler: @escaping () -> Void) {
        delegateQueue.addOperation { [weak self] in
            guard let self else {
                DispatchQueue.main.async(execute: completionHandler)
                return
            }
            if let replaced = self.backgroundEventsCompletionHandler {
                DispatchQueue.main.async(execute: replaced)
            }
            self.backgroundEventsCompletionHandler = completionHandler
            if self.backgroundEventsFinished {
                self.finishBackgroundEvents()
            }
        }
    }

    func upload(
        request: URLRequest,
        chunk: Data,
        context: MessagingBackgroundUploadContext
    ) async throws -> MessagingBackgroundUploadResult {
        guard context.isStructurallyValid,
              chunk.count == context.byteSize,
              SecureMessagingValidation.sha256Hex(chunk) == context.ciphertextSHA256,
              request.url != nil,
              request.httpMethod?.uppercased() == "PATCH",
              request.httpBody == nil
        else { throw APIClientError.invalidResponse }
        return try await withCheckedThrowingContinuation { continuation in
            delegateQueue.addOperation { [weak self] in
                guard let self else {
                    continuation.resume(throwing: URLError(.cancelled))
                    return
                }
                self.enqueue(
                    request: request,
                    chunk: chunk,
                    context: context,
                    continuation: continuation
                )
            }
        }
    }

    /// Called before credentials are discarded. Cancellation is scoped to fingerprints of the
    /// exact account/session; a replacement sign-in can never inherit or cancel another owner's
    /// transfer.
    func cancelTransfers(accountID: String, sessionID: String) {
        let binding = Self.bindingKey(accountID: accountID, sessionID: sessionID)
        delegateQueue.addOperation { [weak self] in
            guard let self else { return }
            self.revokedBindings.insert(binding)
            self.removeDurableResults(bindingKey: binding)
            self.session.getAllTasks { [weak self] tasks in
                self?.delegateQueue.addOperation { [weak self] in
                    guard let self else { return }
                    for task in tasks {
                        guard let context = MessagingBackgroundUploadContext.decode(
                            taskDescription: task.taskDescription
                        ), self.bindingKey(for: context) == binding
                        else { continue }
                        task.cancel()
                    }
                }
            }
        }
    }

    private func enqueue(
        request: URLRequest,
        chunk: Data,
        context: MessagingBackgroundUploadContext,
        continuation: UploadContinuation
    ) {
        let binding = bindingKey(for: context)
        guard !revokedBindings.contains(binding) else {
            continuation.resume(throwing: APIClientError.signedOut)
            return
        }
        if let result = durableResult(for: context) {
            if let error = result.transportError() {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: result)
            }
            return
        }
        waiters[context.logicalTransferID, default: []].append(continuation)
        guard startsInFlight.insert(context.logicalTransferID).inserted else { return }

        session.getAllTasks { [weak self] tasks in
            self?.delegateQueue.addOperation { [weak self] in
                guard let self else { return }
                if let result = self.durableResult(for: context) {
                    if let error = result.transportError() {
                        self.finishWaiters(
                            for: context.logicalTransferID,
                            with: .failure(error)
                        )
                    } else {
                        self.finishWaiters(
                            for: context.logicalTransferID,
                            with: .success(result)
                        )
                    }
                    return
                }
                let matching = tasks.compactMap { task -> (
                    URLSessionTask,
                    MessagingBackgroundUploadContext
                )? in
                    guard let taskContext = MessagingBackgroundUploadContext.decode(
                        taskDescription: task.taskDescription
                    ), taskContext.describesSameTransfer(as: context)
                    else { return nil }
                    return (task, taskContext)
                }.sorted { $0.0.taskIdentifier < $1.0.taskIdentifier }
                if let retained = matching.first {
                    for duplicate in matching.dropFirst() {
                        self.ignoredDuplicateTaskIDs.insert(duplicate.0.taskIdentifier)
                        duplicate.0.cancel()
                    }
                    self.taskContexts[retained.0.taskIdentifier] = retained.1
                    self.startsInFlight.remove(context.logicalTransferID)
                    retained.0.resume()
                    return
                }
                do {
                    let chunkURL = try self.stageChunk(chunk, context: context)
                    let task = self.session.uploadTask(with: request, fromFile: chunkURL)
                    guard let description = context.taskDescription else {
                        throw APIClientError.invalidResponse
                    }
                    task.taskDescription = description
                    self.taskContexts[task.taskIdentifier] = context
                    self.startsInFlight.remove(context.logicalTransferID)
                    task.resume()
                } catch {
                    self.finishWaiters(
                        for: context.logicalTransferID,
                        with: .failure(error)
                    )
                }
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard response is HTTPURLResponse else {
            forcedErrors[dataTask.taskIdentifier] = APIClientError.invalidResponse
            completionHandler(.cancel)
            return
        }
        responseBodies[dataTask.taskIdentifier] = Data()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        var body = responseBodies[dataTask.taskIdentifier] ?? Data()
        guard body.count <= MessagingBackgroundUploadResult.maximumResponseBytes - data.count else {
            forcedErrors[dataTask.taskIdentifier] = URLError(.dataLengthExceedsMaximum)
            dataTask.cancel()
            return
        }
        body.append(data)
        responseBodies[dataTask.taskIdentifier] = body
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let body = responseBodies.removeValue(forKey: task.taskIdentifier) ?? Data()
        let forcedError = forcedErrors.removeValue(forKey: task.taskIdentifier)
        if ignoredDuplicateTaskIDs.remove(task.taskIdentifier) != nil {
            taskContexts.removeValue(forKey: task.taskIdentifier)
            return
        }
        guard let context = taskContexts.removeValue(forKey: task.taskIdentifier)
            ?? MessagingBackgroundUploadContext.decode(taskDescription: task.taskDescription)
        else { return }
        removeChunk(for: context)
        let binding = bindingKey(for: context)
        guard !revokedBindings.contains(binding) else {
            finishWaiters(
                for: context.logicalTransferID,
                with: .failure(APIClientError.signedOut)
            )
            return
        }

        let http = task.response as? HTTPURLResponse
        let completedError = forcedError ?? error
        if let completedError {
            finishWaiters(
                for: context.logicalTransferID,
                with: .failure(completedError)
            )
            return
        }
        var headers: [String: String] = [:]
        if let http {
            for (rawName, rawValue) in http.allHeaderFields {
                let name = String(describing: rawName)
                let value = String(describing: rawValue)
                guard !name.isEmpty,
                      name.utf8.count <= 128,
                      value.utf8.count <= 4_096,
                      headers.count < 64
                else { continue }
                headers[name] = value
            }
        }
        let result = MessagingBackgroundUploadResult(
            context: context,
            statusCode: http?.statusCode,
            headers: headers,
            body: body,
            errorDomain: nil,
            errorCode: nil,
            completedAt: Date()
        )
        guard result.isStructurallyValid else {
            finishWaiters(
                for: context.logicalTransferID,
                with: .failure(APIClientError.invalidResponse)
            )
            return
        }
        let hasLiveWaiter = !(waiters[context.logicalTransferID]?.isEmpty ?? true)
        if (200 ... 299).contains(http?.statusCode ?? 0) || !hasLiveWaiter {
            persistDurableResult(result)
        }
        finishWaiters(for: context.logicalTransferID, with: .success(result))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Never carry a persisted bearer request onto a redirect target. The attachment endpoint
        // is first-party and canonical; any redirect is a configuration or interception failure.
        completionHandler(nil)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        backgroundEventsFinished = true
        if backgroundEventsCompletionHandler != nil { finishBackgroundEvents() }
    }

    func urlSession(
        _ session: URLSession,
        didBecomeInvalidWithError error: Error?
    ) {
        let failure = error ?? URLError(.backgroundSessionWasDisconnected)
        let pending = waiters
        waiters.removeAll()
        startsInFlight.removeAll()
        for continuations in pending.values {
            for continuation in continuations { continuation.resume(throwing: failure) }
        }
    }

    private func finishWaiters(
        for logicalTransferID: String,
        with result: Result<MessagingBackgroundUploadResult, Error>
    ) {
        startsInFlight.remove(logicalTransferID)
        let continuations = waiters.removeValue(forKey: logicalTransferID) ?? []
        for continuation in continuations {
            switch result {
            case .success(let value): continuation.resume(returning: value)
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
    }

    private func finishBackgroundEvents() {
        guard let completionHandler = backgroundEventsCompletionHandler else { return }
        backgroundEventsCompletionHandler = nil
        backgroundEventsFinished = false
        DispatchQueue.main.async(execute: completionHandler)
    }

    private func stageChunk(
        _ chunk: Data,
        context: MessagingBackgroundUploadContext
    ) throws -> URL {
        let directory = try storageDirectory()
        let url = directory.appendingPathComponent(context.attemptID + ".chunk", isDirectory: false)
        if let existing = try? Data(contentsOf: url, options: [.mappedIfSafe]),
           existing.count == context.byteSize,
           SecureMessagingValidation.sha256Hex(existing) == context.ciphertextSHA256 {
            return url
        }
        try? FileManager.default.removeItem(at: url)
        try chunk.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
        return url
    }

    private func removeChunk(for context: MessagingBackgroundUploadContext) {
        guard let directory = try? storageDirectory() else { return }
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(context.attemptID + ".chunk")
        )
    }

    private func durableResult(
        for context: MessagingBackgroundUploadContext
    ) -> MessagingBackgroundUploadResult? {
        guard let directory = try? storageDirectory() else { return nil }
        let exactURL = directory.appendingPathComponent(context.attemptID + ".result")
        if FileManager.default.fileExists(atPath: exactURL.path) {
            guard let result = readDurableResult(at: exactURL), result.context == context else {
                try? FileManager.default.removeItem(at: exactURL)
                return nil
            }
            if result.statusCode.map({ !(200 ... 299).contains($0) }) == true {
                // Deliver a restored failure once. A later outbox retry must be allowed to create
                // a fresh PATCH rather than being pinned to a week-old 429/5xx response.
                try? FileManager.default.removeItem(at: exactURL)
            }
            return result
        }
        // Access-token rotation changes attempt identity, not the logical ciphertext operation.
        // A prior successful response is authoritative and avoids an unnecessary idempotent PATCH.
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for url in urls where url.pathExtension == "result" {
            guard let result = readDurableResult(at: url),
                  result.context.describesSameTransfer(as: context),
                  result.statusCode.map({ (200 ... 299).contains($0) }) == true
            else { continue }
            return result
        }
        return nil
    }

    private func readDurableResult(at url: URL) -> MessagingBackgroundUploadResult? {
        guard let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode(
                  MessagingBackgroundUploadResult.self,
                  from: data
              ),
              result.isStructurallyValid
        else { return nil }
        return result
    }

    private func persistDurableResult(_ result: MessagingBackgroundUploadResult) {
        guard result.isStructurallyValid,
              let directory = try? storageDirectory(),
              let encoded = try? JSONEncoder().encode(result)
        else { return }
        let url = directory.appendingPathComponent(result.context.attemptID + ".result")
        do {
            try encoded.write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(values)
        } catch {
            return
        }
        pruneDurableResults()
    }

    private func storageDirectory() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport.appendingPathComponent(
            "KitMessagingBackgroundUploads-v1",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
        return directory
    }

    private func removeOrphanedChunkFiles(retaining attemptIDs: Set<String>) {
        guard let directory = try? storageDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil
              )
        else { return }
        for url in urls where url.pathExtension == "chunk" {
            guard !attemptIDs.contains(url.deletingPathExtension().lastPathComponent) else {
                continue
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func pruneDurableResults(now: Date = Date()) {
        guard let directory = try? storageDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              )
        else { return }
        let results = urls.filter { $0.pathExtension == "result" }.sorted { lhs, rhs in
            let left = try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            let right = try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            return (left ?? .distantPast) > (right ?? .distantPast)
        }
        let expiry = now.addingTimeInterval(-7 * 24 * 60 * 60)
        for (index, url) in results.enumerated() {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            if index >= 256 || (modified ?? .distantPast) < expiry {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func removeDurableResults(bindingKey: String) {
        guard let directory = try? storageDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              )
        else { return }
        for url in urls where url.pathExtension == "result" {
            guard let data = try? Data(contentsOf: url),
                  let result = try? JSONDecoder().decode(
                      MessagingBackgroundUploadResult.self,
                      from: data
                  ),
                  self.bindingKey(for: result.context) == bindingKey
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func bindingKey(for context: MessagingBackgroundUploadContext) -> String {
        context.accountFingerprint + ":" + context.sessionFingerprint
    }

    private static func bindingKey(accountID: String, sessionID: String) -> String {
        MessagingBackgroundUploadContext.fingerprint(accountID.lowercased())
            + ":"
            + MessagingBackgroundUploadContext.fingerprint(sessionID.lowercased())
    }
}
