import Foundation

enum AccountDeletionAPIEndpoint: Equatable {
    case preflight
    case request

    var path: String {
        switch self {
        case .preflight: "account/deletion"
        case .request: "account/deletion-requests"
        }
    }

    var method: String {
        switch self {
        case .preflight: "GET"
        case .request: "POST"
        }
    }

    static let stepUpHeader = "X-Kit-Wallet-Step-Up"
}

extension APIClient {
    func accountDeletionPreflight() async throws -> AccountDeletionPreflightDTO {
        let endpoint = AccountDeletionAPIEndpoint.preflight
        return try await send(
            path: endpoint.path,
            method: endpoint.method,
            body: AccountDeletionEmptyBody()
        )
    }

    func requestAccountDeletion(
        preflight: AccountDeletionPreflightDTO,
        confirmation: String,
        stepUpToken: String
    ) async throws -> AccountDeletionReceiptDTO {
        guard preflight.purpose == AccountDeletionContract.purpose,
              preflight.confirmationText == AccountDeletionContract.confirmation,
              confirmation == preflight.confirmationText
        else { throw AccountDeletionContractError.invalidConfirmation }
        guard AccountDeletionContract.validStepUpToken(stepUpToken) else {
            throw AccountDeletionContractError.invalidStepUp
        }

        let endpoint = AccountDeletionAPIEndpoint.request
        return try await send(
            path: endpoint.path,
            method: endpoint.method,
            body: try RequestAccountDeletionDTO(confirmation: confirmation),
            headers: [AccountDeletionAPIEndpoint.stepUpHeader: stepUpToken]
        )
    }
}

private struct AccountDeletionEmptyBody: Encodable {}
