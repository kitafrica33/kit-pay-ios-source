import Foundation

enum ContactSyncRetryDecision: Equatable, Sendable {
    case retry(after: TimeInterval)
    case waitForConnectivity
    case stop
}

enum ContactSyncRetryPolicy {
    private static let delays: [TimeInterval] = [2, 5, 15, 30]

    /// Timer-only compatibility used by request loops. Connectivity-gated
    /// failures return nil and are resumed by the app's connectivity monitor.
    static func delay(
        for error: Error,
        automaticRetryCount: Int
    ) -> Duration? {
        switch decision(for: error, automaticRetryCount: automaticRetryCount) {
        case .retry(let delay): .seconds(delay)
        case .waitForConnectivity, .stop: nil
        }
    }

    /// Separates failures that need a timer from failures that should wait for
    /// the connectivity monitor. `jitterUnitInterval` is injectable so tests
    /// remain deterministic while production clients avoid synchronized retry
    /// bursts after a rollout or service recovery.
    static func decision(
        for error: Error,
        automaticRetryCount: Int,
        retryAfter: TimeInterval? = nil,
        jitterUnitInterval: Double = Double.random(in: 0 ... 1)
    ) -> ContactSyncRetryDecision {
        if let urlError = error as? URLError,
           connectivityGatedURLErrorCodes.contains(urlError.code) {
            return .waitForConnectivity
        }

        if let payload = error as? APIErrorPayload,
           payload.code.uppercased() == "CONTACT_SYNC_SUPERSEDED" {
            return automaticRetryCount == 0 ? .retry(after: 1) : .stop
        }

        guard delays.indices.contains(automaticRetryCount), isRetryable(error) else {
            return .stop
        }

        let serverDelay = retryAfter.map { min(120, max(0, $0)) }
        let baseDelay = serverDelay ?? delays[automaticRetryCount]
        let jitter = min(1, max(0, jitterUnitInterval))
        let jitterFactor = 0.9 + (0.2 * jitter)
        return .retry(after: baseDelay * jitterFactor)
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let payload = error as? APIErrorPayload {
            return retryableAPICodes.contains(payload.code.uppercased())
        }
        if let clientError = error as? APIClientError {
            switch clientError {
            case .invalidResponse:
                return true
            case .invalidPayload(let status), .httpStatus(let status):
                return status == 404 || status == 408 || status == 425
                    || status == 429 || (500 ... 599).contains(status)
            case .httpResponse(let status, _):
                return status == 404 || status == 408 || status == 425
                    || status == 429 || (500 ... 599).contains(status)
            case .signedOut, .invalidURL:
                return false
            }
        }
        if let urlError = error as? URLError { return retryableURLErrorCodes.contains(urlError.code) }
        return false
    }

    private static let retryableAPICodes: Set<String> = [
        "ENDPOINT_NOT_FOUND",
        "GATEWAY_TIMEOUT",
        "INTERNAL_ERROR",
        "RATE_LIMIT_EXCEEDED",
        "RATE_LIMITED",
        "REQUEST_TIMEOUT",
        "ROUTE_NOT_FOUND",
        "SERVICE_UNAVAILABLE",
        "TOO_MANY_REQUESTS",
        "UPSTREAM_UNAVAILABLE",
    ]

    private static let retryableURLErrorCodes: Set<URLError.Code> = [
        .cannotConnectToHost,
        .cannotFindHost,
        .dnsLookupFailed,
        .networkConnectionLost,
        .resourceUnavailable,
        .timedOut,
    ]

    private static let connectivityGatedURLErrorCodes: Set<URLError.Code> = [
        .dataNotAllowed,
        .internationalRoamingOff,
        .notConnectedToInternet,
    ]
}
