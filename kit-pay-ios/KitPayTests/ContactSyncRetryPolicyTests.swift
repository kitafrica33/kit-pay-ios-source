import Foundation
import XCTest
@testable import KitPay

final class ContactSyncRetryPolicyTests: XCTestCase {
    func testTimerCompatibilityWaitsForConnectivityMonitorWhenOffline() {
        XCTAssertNil(
            ContactSyncRetryPolicy.delay(
                for: URLError(.notConnectedToInternet),
                automaticRetryCount: 0
            )
        )
    }

    func testRouteNotFoundRetriesWithBoundedBackoff() {
        let error = APIErrorPayload(
            code: "ROUTE_NOT_FOUND",
            message: "The requested endpoint was not found."
        )

        XCTAssertEqual(
            decision(for: error, automaticRetryCount: 0),
            .retry(after: 2)
        )
        XCTAssertEqual(
            decision(for: error, automaticRetryCount: 1),
            .retry(after: 5)
        )
        XCTAssertEqual(
            decision(for: error, automaticRetryCount: 2),
            .retry(after: 15)
        )
        XCTAssertEqual(
            decision(for: error, automaticRetryCount: 3),
            .retry(after: 30)
        )
        XCTAssertEqual(
            decision(for: error, automaticRetryCount: 4),
            .stop
        )
    }

    func testOfflineFailureWaitsForConnectivityWithoutConsumingATimer() {
        XCTAssertEqual(
            decision(for: URLError(.notConnectedToInternet), automaticRetryCount: 3),
            .waitForConnectivity
        )
    }

    func testTransientTransportAndServerFailuresRetry() {
        XCTAssertEqual(
            decision(for: URLError(.networkConnectionLost), automaticRetryCount: 0),
            .retry(after: 2)
        )
        XCTAssertEqual(
            decision(for: APIClientError.httpStatus(503), automaticRetryCount: 0),
            .retry(after: 2)
        )
        XCTAssertEqual(
            decision(for: APIClientError.invalidPayload(status: 404), automaticRetryCount: 0),
            .retry(after: 2)
        )
    }

    func testRateLimitUsesServerDelayAndExactBackendCode() {
        let error = APIErrorPayload(
            code: "RATE_LIMIT_EXCEEDED",
            message: "Try again later."
        )
        XCTAssertEqual(
            decision(for: error, automaticRetryCount: 0, retryAfter: 45),
            .retry(after: 45)
        )
        XCTAssertEqual(
            decision(for: error, automaticRetryCount: 0, retryAfter: 500),
            .retry(after: 120)
        )
    }

    func testSupersededGenerationGetsOnlyOneFreshPass() {
        let error = APIErrorPayload(
            code: "CONTACT_SYNC_SUPERSEDED",
            message: "A newer sync replaced this one."
        )
        XCTAssertEqual(
            decision(for: error, automaticRetryCount: 0),
            .retry(after: 1)
        )
        XCTAssertEqual(
            decision(for: error, automaticRetryCount: 1),
            .stop
        )
    }

    func testAuthenticationAndValidationFailuresDoNotRetry() {
        XCTAssertEqual(
            decision(for: APIClientError.signedOut, automaticRetryCount: 0),
            .stop
        )
        XCTAssertEqual(
            decision(
                for: APIErrorPayload(
                    code: "VALIDATION_FAILED",
                    message: "The payload is invalid."
                ),
                automaticRetryCount: 0
            ),
            .stop
        )
        XCTAssertEqual(
            decision(
                for: APIErrorPayload(
                    code: "SESSION_ID_REQUIRED",
                    message: "A valid session ID header is required."
                ),
                automaticRetryCount: 0
            ),
            .stop
        )
    }

    private func decision(
        for error: Error,
        automaticRetryCount: Int,
        retryAfter: TimeInterval? = nil
    ) -> ContactSyncRetryDecision {
        ContactSyncRetryPolicy.decision(
            for: error,
            automaticRetryCount: automaticRetryCount,
            retryAfter: retryAfter,
            jitterUnitInterval: 0.5
        )
    }
}
