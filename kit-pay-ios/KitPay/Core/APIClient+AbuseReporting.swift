import Foundation

enum AbuseReportAPIEndpoint {
    static let path = "communications/reports"
}

extension APIClient {
    func submitAbuseReport(
        _ request: CreateAbuseReportRequest,
        idempotencyKey: String
    ) async throws -> AbuseReportReceipt {
        guard AbuseReportContract.validIdempotencyKey(idempotencyKey) else {
            throw AbuseReportContractError.invalidIdempotencyKey
        }
        let receipt: AbuseReportReceipt = try await send(
            path: AbuseReportAPIEndpoint.path,
            method: "POST",
            body: request,
            headers: ["Idempotency-Key": idempotencyKey]
        )
        guard receipt.confirms(request) else { throw APIClientError.invalidResponse }
        return receipt
    }
}
