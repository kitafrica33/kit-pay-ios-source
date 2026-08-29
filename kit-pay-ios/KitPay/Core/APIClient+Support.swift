import Foundation

/// The session AND account a support view or sheet was opened under. Captured ONCE when the
/// surface appears and used for the surface's entire lifetime, so an already-open sheet stays
/// bound to its original account: after an account switch every request fails closed with
/// `.signedOut` (transport-level task-local binding) and every state write is dropped
/// (`isCurrent` re-checks BOTH fields), while the draft text and its idempotency UUID stay
/// persisted under the ORIGINAL account's protected storage.
struct SupportFlowBinding: Equatable, Sendable {
    let sessionID: String
    /// Canonical account identifier. Deliberately NOT the session ID: a session-scoped key would
    /// break account isolation (two sessions of one account would not share drafts, and a fresh
    /// session could not recover a durable draft). Capture fails closed when the token record
    /// carries no account identifier.
    let accountID: String
}

/// Session/account continuity for multi-step support flows (same transport pattern as
/// `attachBankDepositProof`): a view captures the flow binding once when it appears, wraps every
/// nested request in `APIClientSessionBinding.$sessionID.withValue(binding.sessionID) { … }` so
/// the transport fails closed with `.signedOut` if the signed-in session changes mid-flow, and
/// checks `isCurrent` again before applying any result — success or error — to UI state, so a
/// stale response can never update or clear another account's screen.
enum SupportSessionScope {
    static func captureFlow() async throws -> SupportFlowBinding {
        guard let tokens = await SessionStore.shared.current(),
              let accountID = SupportContract.canonicalAccountID(tokens.accountId)
        else { throw APIClientError.signedOut }
        if let inherited = APIClientSessionBinding.sessionID {
            // An inherited task-local binding must still describe the signed-in session,
            // otherwise the account identifier would belong to a different session: fail closed.
            guard SessionRefreshPolicy.matchesSessionID(inherited, current: tokens.sessionId)
            else { throw APIClientError.signedOut }
            return SupportFlowBinding(sessionID: inherited, accountID: accountID)
        }
        return SupportFlowBinding(sessionID: tokens.sessionId, accountID: accountID)
    }

    /// Both fields must still match: the session (case-insensitive, as the transport compares
    /// it) AND the canonical account. Either one differing means the surface belongs to a
    /// signed-out context and must not be updated.
    static func isCurrent(_ binding: SupportFlowBinding) async -> Bool {
        guard let tokens = await SessionStore.shared.current(),
              let currentAccountID = SupportContract.canonicalAccountID(tokens.accountId)
        else { return false }
        return SessionRefreshPolicy.matchesSessionID(binding.sessionID, current: tokens.sessionId)
            && currentAccountID == binding.accountID
    }
}

enum SupportAPIEndpoint: Equatable {
    case categories
    case tickets
    case ticket(id: String)
    case close(id: String)
    case escalate(id: String)
    case messages(id: String)
    case payments(id: String)

    var path: String {
        switch self {
        case .categories: "support/categories"
        case .tickets: "support/tickets"
        case .ticket(let id): "support/tickets/\(id)"
        case .close(let id): "support/tickets/\(id)/close"
        case .escalate(let id): "support/tickets/\(id)/escalate"
        case .messages(let id): "support/tickets/\(id)/messages"
        case .payments(let id): "support/tickets/\(id)/payments"
        }
    }

    var method: String {
        switch self {
        case .categories, .tickets, .ticket, .messages: "GET"
        case .close, .escalate, .payments: "POST"
        }
    }
}

extension APIClient {
    func supportCategories() async throws -> [SupportCategoryDTO] {
        let endpoint = SupportAPIEndpoint.categories
        let list: SupportCategoryListDTO = try await send(
            path: endpoint.path,
            method: endpoint.method,
            body: SupportEmptyBody()
        )
        return list.items
    }

    /// Fetches one page of the cursor-paginated tickets index (newest first; optional status
    /// filter). Continuation is AUTHORITATIVE: the response meta must carry a coherent
    /// `has_more`/`next_cursor` pair or the page is rejected
    /// (`SupportThreadPageValidator.validateTicketPageContinuation`) — completeness is never
    /// inferred from page fullness. An outgoing cursor is only ever one the server just issued;
    /// anything outside the server's own length bound fails before the request is formed.
    func supportTickets(
        status: String? = nil,
        limit: Int = SupportContract.ticketsPageLimit,
        cursor: String? = nil
    ) async throws -> SupportTicketPage {
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let status {
            guard status == SupportContract.statusOpen
                || status == SupportContract.statusClosed
            else { throw SupportContractError.inconsistentList }
            queryItems.append(URLQueryItem(name: "status", value: status))
        }
        if let cursor {
            guard SupportContract.isBoundedServerText(
                cursor,
                maximum: SupportContract.ticketsCursorMaximumLength
            ) else { throw SupportContractError.inconsistentList }
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        let endpoint = SupportAPIEndpoint.tickets
        let (list, meta): (SupportTicketListDTO, APIMeta?) = try await sendWithMeta(
            path: endpoint.path,
            method: endpoint.method,
            body: SupportEmptyBody(),
            queryItems: queryItems
        )
        let continuation = try SupportThreadPageValidator.validateTicketPageContinuation(
            hasMore: meta?.hasMore,
            nextCursor: meta?.nextCursor
        )
        return SupportTicketPage(
            items: list.items,
            nextCursor: continuation.nextCursor,
            hasMore: continuation.hasMore
        )
    }

    func openSupportTicket(
        categoryKey: String,
        subject: String,
        message: String,
        clientMessageID: UUID
    ) async throws -> SupportTicketDTO {
        let trimmedCategory = categoryKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCategory.isEmpty else { throw SupportContractError.invalidCategory }
        guard let subject = SupportContract.normalizedSubject(subject) else {
            throw SupportContractError.invalidSubject
        }
        guard let message = SupportContract.normalizedMessageBody(message) else {
            throw SupportContractError.invalidMessageBody
        }

        return try await send(
            path: SupportAPIEndpoint.tickets.path,
            method: "POST",
            body: OpenSupportTicketRequestDTO(
                categoryKey: trimmedCategory,
                subject: subject,
                message: message,
                clientMessageID: clientMessageID.uuidString.lowercased()
            )
        )
    }

    func supportTicketSnapshot(
        id: String,
        limit: Int = SupportContract.snapshotMessagesLimit
    ) async throws -> SupportTicketSnapshotDTO {
        guard let id = SupportContract.canonicalTicketID(id) else {
            throw SupportContractError.invalidTicketID
        }
        let endpoint = SupportAPIEndpoint.ticket(id: id)
        return try await send(
            path: endpoint.path,
            method: endpoint.method,
            body: SupportEmptyBody(),
            queryItems: [URLQueryItem(name: "limit", value: String(limit))]
        )
    }

    func supportMessages(
        ticketID: String,
        afterPosition: Int,
        limit: Int = SupportContract.messagesPageLimit
    ) async throws -> SupportMessageListDTO {
        guard let id = SupportContract.canonicalTicketID(ticketID) else {
            throw SupportContractError.invalidTicketID
        }
        let endpoint = SupportAPIEndpoint.messages(id: id)
        return try await send(
            path: endpoint.path,
            method: endpoint.method,
            body: SupportEmptyBody(),
            queryItems: [
                URLQueryItem(name: "after_position", value: String(max(0, afterPosition))),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
        )
    }

    func sendSupportMessage(
        ticketID: String,
        body: String,
        clientMessageID: UUID
    ) async throws -> SupportMessageDTO {
        guard let id = SupportContract.canonicalTicketID(ticketID) else {
            throw SupportContractError.invalidTicketID
        }
        guard let body = SupportContract.normalizedMessageBody(body) else {
            throw SupportContractError.invalidMessageBody
        }
        return try await send(
            path: SupportAPIEndpoint.messages(id: id).path,
            method: "POST",
            body: SendSupportMessageRequestDTO(
                body: body,
                clientMessageID: clientMessageID.uuidString.lowercased()
            )
        )
    }

    func closeSupportTicket(id: String) async throws -> SupportTicketDTO {
        guard let id = SupportContract.canonicalTicketID(id) else {
            throw SupportContractError.invalidTicketID
        }
        let endpoint = SupportAPIEndpoint.close(id: id)
        return try await send(
            path: endpoint.path,
            method: endpoint.method,
            body: SupportEmptyBody()
        )
    }

    func escalateSupportTicket(id: String) async throws -> SupportTicketDTO {
        guard let id = SupportContract.canonicalTicketID(id) else {
            throw SupportContractError.invalidTicketID
        }
        let endpoint = SupportAPIEndpoint.escalate(id: id)
        return try await send(
            path: endpoint.path,
            method: endpoint.method,
            body: SupportEmptyBody()
        )
    }

    /// Executes (or verbatim-replays) a customer-initiated payment to the company beneficiary
    /// inside a ticket. The caller MUST have durably frozen the envelope before calling — the
    /// idempotency key, amount, wallet, and note are replayed byte-identically so the server's
    /// ticket-scoped ledger can prove sameness. The request body carries no destination of any
    /// kind (the server resolves its company wallet itself and prohibits destination fields),
    /// and the response is the strictly validated receipt plus the server's `idempotent_replay`
    /// meta flag (true means an earlier attempt already settled — no new money moved).
    func supportPayment(
        ticketID: String,
        sourceWalletID: String,
        amount: String,
        note: String?,
        idempotencyKey: String,
        stepUpToken: String
    ) async throws -> (receipt: SupportPaymentReceiptDTO, idempotentReplay: Bool) {
        guard let id = SupportContract.canonicalTicketID(ticketID) else {
            throw SupportContractError.invalidTicketID
        }
        guard SupportContract.canonicalUUID(sourceWalletID) == sourceWalletID,
              SupportPaymentContract.isCanonicalAPIAmount(amount),
              SupportPaymentContract.isCoherentNote(note),
              SupportPaymentContract.isValidIdempotencyKey(idempotencyKey),
              !stepUpToken.isEmpty
        else { throw SupportContractError.paymentUnconfirmed }
        let endpoint = SupportAPIEndpoint.payments(id: id)
        let (receipt, meta): (SupportPaymentReceiptDTO, APIMeta?) = try await sendWithMeta(
            path: endpoint.path,
            method: endpoint.method,
            body: SupportPaymentRequestDTO(
                sourceWalletID: sourceWalletID,
                amount: amount,
                note: note
            ),
            headers: [
                "Idempotency-Key": idempotencyKey,
                "X-Kit-Wallet-Step-Up": stepUpToken,
            ]
        )
        return (receipt, meta?.idempotentReplay == true)
    }
}

private struct SupportEmptyBody: Encodable {}
