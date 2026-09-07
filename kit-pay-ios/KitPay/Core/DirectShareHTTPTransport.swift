import CryptoKit
import Foundation

protocol DirectShareTransporting: Sendable {
    func capabilities(scope: MessagingProcessBroker.Scope) async throws -> DirectShareCapabilitiesDTO
    func send<Response: Decodable, Body: Encodable>(
        _ endpoint: MessagingAPIEndpoint, body: Body, scope: MessagingProcessBroker.Scope
    ) async throws -> Response
    func request<Response: Decodable>(
        _ endpoint: MessagingAPIEndpoint, body: Data?, scope: MessagingProcessBroker.Scope,
        contentType: String, headers: [String: String], allowRefresh: Bool
    ) async throws -> Response
    func upload(
        ciphertextURL: URL, attachmentID: String, mediaType: String, byteSize: Int64,
        sha256: String, scope: MessagingProcessBroker.Scope, allowRefresh: Bool
    ) async throws -> MessagingAttachmentUploadDTO
}

/// Messaging endpoints are canonical and never need redirects. In particular, a refresh POST
/// or multipart body must not be replayed to a CDN, another origin or a downgraded URL.
private final class DirectShareRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

extension DirectShareTransporting {
    func request<Response: Decodable>(
        _ endpoint: MessagingAPIEndpoint, body: Data? = nil, scope: MessagingProcessBroker.Scope
    ) async throws -> Response {
        try await request(endpoint, body: body, scope: scope, contentType: "application/json",
                          headers: [:], allowRefresh: true)
    }
    func upload(
        ciphertextURL: URL, attachmentID: String, mediaType: String, byteSize: Int64,
        sha256: String, scope: MessagingProcessBroker.Scope
    ) async throws -> MessagingAttachmentUploadDTO {
        try await upload(ciphertextURL: ciphertextURL, attachmentID: attachmentID, mediaType: mediaType,
                         byteSize: byteSize, sha256: sha256, scope: scope, allowRefresh: true)
    }
}

/// A deliberately narrow authenticated transport for the share extension. It uses the same wire
/// DTOs, endpoint constructors and shared refresh authority as the app, without linking wallet,
/// payment or UIApplication code into the extension. No request accepts an arbitrary host URL.
actor DirectShareHTTPTransport: DirectShareTransporting {
    static let shared = DirectShareHTTPTransport()
    private let broker: MessagingProcessBroker
    private let sessions: SessionStore
    private let network: URLSession
    private let baseURL = URL(string: "https://pay.kit.africa/api/kit-wallet/v1/")!

    enum Failure: LocalizedError {
        case signedOut, invalidResponse, http(Int)

        var errorDescription: String? {
            switch self {
            case .signedOut: "Your account changed. Sign in to Kit Pay and share again."
            case .invalidResponse: "Kit Pay could not confirm the send. Please try again."
            case .http: "The connection was interrupted. Your send is saved and can retry."
            }
        }
    }

    init(broker: MessagingProcessBroker = .shared, sessions: SessionStore = .shared) {
        self.broker = broker
        self.sessions = sessions
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 300
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        network = URLSession(configuration: configuration, delegate: DirectShareRedirectPolicy(), delegateQueue: nil)
    }

    func send<Response: Decodable, Body: Encodable>(
        _ endpoint: MessagingAPIEndpoint,
        body: Body,
        scope: MessagingProcessBroker.Scope
    ) async throws -> Response {
        let bytes = endpoint.method == "GET" ? nil : try JSONEncoder().encode(body)
        return try await request(endpoint, body: bytes, scope: scope)
    }

    func capabilities(scope: MessagingProcessBroker.Scope) async throws -> DirectShareCapabilitiesDTO {
        try await request(MessagingAPIEndpoint(path: "capabilities", method: "GET"), scope: scope)
    }

    func request<Response: Decodable>(
        _ endpoint: MessagingAPIEndpoint,
        body: Data? = nil,
        scope: MessagingProcessBroker.Scope,
        contentType: String = "application/json",
        headers: [String: String] = [:],
        allowRefresh: Bool = true
    ) async throws -> Response {
        try Task.checkCancellation()
        let session = try currentSession(scope: scope)
        var request = try makeRequest(endpoint, session: session)
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await network.data(for: request)
        _ = try currentSession(scope: scope)
        guard let http = response as? HTTPURLResponse, http.url == request.url else { throw Failure.invalidResponse }
        if http.statusCode == 401, allowRefresh {
            try await refresh(session, scope: scope)
            return try await self.request(
                endpoint, body: body, scope: scope, contentType: contentType,
                headers: headers, allowRefresh: false
            )
        }
        return try decode(data, response: http)
    }

    /// A file upload keeps large encrypted attachments out of the extension's small heap. The
    /// temporary multipart body contains only ciphertext; keys remain in the encrypted journal.
    func upload(
        ciphertextURL: URL,
        attachmentID: String,
        mediaType: String,
        byteSize: Int64,
        sha256: String,
        scope: MessagingProcessBroker.Scope,
        allowRefresh: Bool = true
    ) async throws -> MessagingAttachmentUploadDTO {
        let session = try currentSession(scope: scope)
        guard SecureMessagingWirePolicy.isCanonicalUUID(attachmentID),
              SecureMessagingWire.allowedAttachmentMediaTypes.contains(mediaType),
              SecureMessagingWirePolicy.isLowercaseSHA256(sha256),
              (try FileManager.default.attributesOfItem(atPath: ciphertextURL.path)[.size]
                as? NSNumber)?.int64Value == byteSize
        else { throw Failure.invalidResponse }
        let boundary = "KitShare-\(UUID().uuidString.lowercased())"
        let multipart = ciphertextURL.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString.lowercased()).upload"
        )
        defer { try? FileManager.default.removeItem(at: multipart) }
        FileManager.default.createFile(
            atPath: multipart.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        let output = try FileHandle(forWritingTo: multipart)
        let input = try FileHandle(forReadingFrom: ciphertextURL)
        defer { try? output.close(); try? input.close() }
        for (name, value) in [
            ("media_type", mediaType), ("client_media_id", attachmentID),
            ("ciphertext_sha256", sha256),
        ] {
            try output.write(contentsOf: Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8
            ))
        }
        try output.write(contentsOf: Data(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"ciphertext\"; filename=\"encrypted-attachment.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8
        ))
        var copied: Int64 = 0
        while let bytes = try input.read(upToCount: 256 * 1_024), !bytes.isEmpty {
            try Task.checkCancellation()
            copied += Int64(bytes.count)
            guard copied <= byteSize else { throw Failure.invalidResponse }
            try output.write(contentsOf: bytes)
        }
        guard copied == byteSize else { throw Failure.invalidResponse }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try output.synchronize()
        var request = try makeRequest(.attachments, session: session)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        _ = try currentSession(scope: scope)
        let (data, response) = try await network.upload(for: request, fromFile: multipart)
        _ = try currentSession(scope: scope)
        guard let http = response as? HTTPURLResponse, http.url == request.url else { throw Failure.invalidResponse }
        if http.statusCode == 401, allowRefresh {
            try await refresh(session, scope: scope)
            return try await upload(
                ciphertextURL: ciphertextURL, attachmentID: attachmentID, mediaType: mediaType,
                byteSize: byteSize, sha256: sha256, scope: scope, allowRefresh: false
            )
        }
        return try decode(data, response: http)
    }

    private func currentSession(scope: MessagingProcessBroker.Scope) throws -> SessionTokens {
        return try broker.withLock { locked in
            let authority = try locked.requireScopeLocked(scope)
            guard let session = authority.session else { throw Failure.signedOut }
            return session
        }
    }

    private func makeRequest(_ endpoint: MessagingAPIEndpoint, session: SessionTokens) throws -> URLRequest {
        guard !endpoint.path.contains(".."), !endpoint.path.hasPrefix("/"),
              !endpoint.path.contains(":"), endpoint.queryItems.isEmpty,
              let url = URL(string: endpoint.path, relativeTo: baseURL)?.absoluteURL,
              url.host == baseURL.host, url.scheme == "https"
        else { throw Failure.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(APIClientIdentity.currentHeader, forHTTPHeaderField: "X-Kit-Wallet-Client")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-ID")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(session.sessionId, forHTTPHeaderField: "X-Kit-Wallet-Session-ID")
        return request
    }

    private func decode<Response: Decodable>(_ data: Data, response: HTTPURLResponse) throws -> Response {
        guard data.count <= 8 * 1_024 * 1_024 else { throw Failure.invalidResponse }
        guard let envelope = try? JSONDecoder().decode(APIEnvelope<Response>.self, from: data) else {
            throw Failure.http(response.statusCode)
        }
        guard (200 ... 299).contains(response.statusCode), envelope.ok, let value = envelope.data else {
            if let error = envelope.error {
                throw error.attachingHTTP(status: response.statusCode, retryAfter: nil)
            }
            throw Failure.http(response.statusCode)
        }
        return value
    }

    private func refresh(_ rejected: SessionTokens, scope: MessagingProcessBroker.Scope) async throws {
        if let current = await sessions.current(), current != rejected {
            guard current.sessionId.lowercased() == scope.sessionID,
                  current.accountId?.lowercased() == scope.accountID
            else { throw Failure.signedOut }
            return
        }
        do {
            let nonce = try await sessions.replayNonce(for: rejected)
            var request = try makeRequest(
                MessagingAPIEndpoint(path: "auth/refresh", method: "POST"), session: rejected
            )
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(RefreshBody(
                refreshToken: rejected.refreshToken, refreshReplayNonce: nonce
            ))
            _ = try currentSession(scope: scope)
            let (data, response) = try await network.data(for: request)
            _ = try currentSession(scope: scope)
            guard let response = response as? HTTPURLResponse, response.url == request.url else {
                throw Failure.invalidResponse
            }
            let result: DirectShareRefreshResult = try decode(data, response: response)
            guard let replacement = result.session else { throw Failure.invalidResponse }
            _ = try await sessions.adoptRefresh(replacement, ifCurrent: rejected)
        } catch {
            if let current = await sessions.current(),
               current.sessionId.lowercased() == scope.sessionID,
               current.accountId?.lowercased() == scope.accountID,
               current.accessToken != rejected.accessToken,
               current.refreshToken != rejected.refreshToken { return }
            if let payload = error as? APIErrorPayload, payload.httpStatus == 401,
               ["SESSION_ID_REQUIRED", "SESSION_REVOKED", "REFRESH_TOKEN_INVALID",
                "REFRESH_TOKEN_EXPIRED", "REFRESH_TOKEN_REUSED"].contains(payload.code) {
                _ = try? await sessions.clearIfCurrent(rejected)
            }
            throw error
        }
    }

    private struct RefreshBody: Encodable {
        let refreshToken: String
        let refreshReplayNonce: String

        enum CodingKeys: String, CodingKey {
            case refreshToken = "refresh_token"
            case refreshReplayNonce = "refresh_replay_nonce"
        }
    }
}

struct DirectShareEmptyBody: Encodable {}
