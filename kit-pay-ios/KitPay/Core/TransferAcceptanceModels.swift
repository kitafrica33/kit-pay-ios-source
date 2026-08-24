import CryptoKit
import Foundation

// MARK: - Authoritative transfer-acceptance state

/// Server-side lifecycle of a claimable Kit Pay → Kit Pay transfer.
enum TransferAcceptanceStatus: String, Codable, CaseIterable {
    case pending
    case accepted
    case rejected
    case reversed
    case expired
}

/// One transfer as the backend sees it. The chat descriptor is only a hint; every button the
/// user can tap resolves against this authoritative object first.
struct TransferAcceptanceDTO: Codable, Hashable, Identifiable {
    let id: String
    let transactionId: String
    let reference: String?
    let status: String
    let amount: String
    let currency: CurrencyDTO
    let note: String?
    let sender: TransferAcceptancePartyDTO?
    let recipient: TransferAcceptancePartyDTO?
    let reason: String?
    let resolvedBy: String?
    let reversalTransactionId: String?
    let expiresAt: String?
    let acceptedAt: String?
    let returnedAt: String?
    let createdAt: String?
    let canAccept: Bool
    let canReject: Bool
    let canReverse: Bool

    enum CodingKeys: String, CodingKey {
        case id, reference, status, amount, currency, note, sender, recipient, reason
        case transactionId = "transaction_id"
        case resolvedBy = "resolved_by"
        case reversalTransactionId = "reversal_transaction_id"
        case expiresAt = "expires_at"
        case acceptedAt = "accepted_at"
        case returnedAt = "returned_at"
        case createdAt = "created_at"
        case canAccept = "can_accept"
        case canReject = "can_reject"
        case canReverse = "can_reverse"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        transactionId = try values.decode(String.self, forKey: .transactionId)
        reference = try values.decodeIfPresent(String.self, forKey: .reference)
        status = try values.decode(String.self, forKey: .status)
        amount = try values.decode(String.self, forKey: .amount)
        currency = try values.decode(CurrencyDTO.self, forKey: .currency)
        note = try values.decodeIfPresent(String.self, forKey: .note)
        sender = try values.decodeIfPresent(TransferAcceptancePartyDTO.self, forKey: .sender)
        recipient = try values.decodeIfPresent(TransferAcceptancePartyDTO.self, forKey: .recipient)
        reason = try values.decodeIfPresent(String.self, forKey: .reason)
        resolvedBy = try values.decodeIfPresent(String.self, forKey: .resolvedBy)
        reversalTransactionId = try values.decodeIfPresent(
            String.self,
            forKey: .reversalTransactionId
        )
        expiresAt = try values.decodeIfPresent(String.self, forKey: .expiresAt)
        acceptedAt = try values.decodeIfPresent(String.self, forKey: .acceptedAt)
        returnedAt = try values.decodeIfPresent(String.self, forKey: .returnedAt)
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
        canAccept = try values.decodeIfPresent(Bool.self, forKey: .canAccept) ?? false
        canReject = try values.decodeIfPresent(Bool.self, forKey: .canReject) ?? false
        canReverse = try values.decodeIfPresent(Bool.self, forKey: .canReverse) ?? false
    }

    var knownStatus: TransferAcceptanceStatus? {
        TransferAcceptanceStatus(rawValue: status)
    }

    var senderUserId: String? { sender?.id }
    var recipientUserId: String? { recipient?.id }
}

struct TransferAcceptancePartyDTO: Codable, Hashable {
    let id: String?
    let name: String?
    let phone: String?
}

// MARK: - Acceptance window

/// The escrow window and the canonical wording used everywhere the auto-reversal is explained.
enum TransferAcceptanceWindowPolicy {
    static let acceptanceWindowDays = 7

    /// The reason carried inside the auto-reversal chat receipt and shown under the bubble.
    /// Must stay within `KitPaymentMessage.maximumReasonLength`.
    static let autoReversalReason =
        "Reversed automatically: not accepted within 7 days, so the money returned to the sender."

    /// Whole days left before an unaccepted transfer auto-reverses, from the server's
    /// `expires_at`; nil when the timestamp is absent or unparseable.
    static func daysRemaining(untilExpiry expiresAt: String?, now: Date = Date()) -> Int? {
        guard let expiresAt, let expiry = parseTimestamp(expiresAt) else { return nil }
        let seconds = expiry.timeIntervalSince(now)
        guard seconds > 0 else { return 0 }
        return max(1, Int((seconds / 86_400).rounded(.up)))
    }

    static func pendingRecipientCopy(expiresAt: String?, now: Date = Date()) -> String {
        guard let days = daysRemaining(untilExpiry: expiresAt, now: now) else {
            return "Accept to add it to your wallet — unaccepted payments return to the sender after \(acceptanceWindowDays) days."
        }
        if days <= 0 {
            return "Accept to add it to your wallet — it is about to return to the sender."
        }
        let unit = days == 1 ? "day" : "days"
        return "Accept to add it to your wallet — it returns to the sender in \(days) \(unit)."
    }

    static func pendingSenderCopy(expiresAt: String?, now: Date = Date()) -> String {
        guard let days = daysRemaining(untilExpiry: expiresAt, now: now) else {
            return "Waiting for them to accept. Unaccepted payments come back to you after \(acceptanceWindowDays) days."
        }
        if days <= 0 {
            return "Waiting for them to accept. It is about to come back to you."
        }
        let unit = days == 1 ? "day" : "days"
        return "Waiting for them to accept. It comes back to you in \(days) \(unit)."
    }

    /// A deterministic message id for the auto-reversal receipt, derived from the transfer id,
    /// so the receipt is idempotent no matter how many times either device observes the expiry.
    static func autoReversalReceiptMessageID(forTransferID transferID: String) -> UUID {
        deterministicMessageID(
            namespace: "kit-transfer-auto-reversal:\(transferID.lowercased())"
        )
    }

    /// A stable, action-scoped id for a user-driven terminal receipt. The action is part of the
    /// namespace so it cannot collide with the original transfer card or the automatic-expiry
    /// receipt, while retries and multiple installations converge on one chat event.
    static func resolutionReceiptMessageID(
        forTransferID transferID: String,
        action: KitPaymentMessageAction
    ) -> UUID? {
        switch action {
        case .accepted, .rejected, .reversed:
            return deterministicMessageID(
                namespace: "kit-transfer-resolution:\(transferID.lowercased()):\(action.rawValue)"
            )
        case .request, .paid, .declined, .cancelled, .transfer, .sent, .expired:
            return nil
        }
    }

    private static func deterministicMessageID(namespace: String) -> UUID {
        let digest = SHA256.hash(data: Data(namespace.utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

struct TransferAcceptanceListDTO: Decodable {
    let items: [TransferAcceptanceDTO]
    let page: CursorPage?
}

// MARK: - Capability gate

/// Accept/Reject/Reverse exists only when the backend advertises it; without the capability,
/// transfers are what they always were — instant and final — and the chat event is a receipt.
struct TransferAcceptancePolicy: Equatable {
    let transfersEnabled: Bool
    let acceptanceEnabled: Bool

    init(features: [String: Bool?]?) {
        let enabled = features?.compactMapValues { $0 } ?? [:]
        transfersEnabled = enabled["wallets"] == true && enabled["internal_transfers"] == true
        acceptanceEnabled = transfersEnabled && enabled["claimable_transfers"] == true
    }
}

// MARK: - Descriptor ↔ authority resolution

/// The two accounts a chat transfer event may bind to: the signed-in user and the single
/// conversation peer. A transfer whose parties are anyone else — however real — must stay
/// inert in this conversation (a relayed descriptor must never gain live buttons).
struct KitTransferPartyBinding: Equatable {
    let currentUserID: String
    let peerUserID: String

    init?(currentUserID: String?, peerUserID: String?) {
        guard let current = currentUserID?.lowercased(), !current.isEmpty,
              let peer = peerUserID?.lowercased(), !peer.isEmpty,
              current != peer
        else { return nil }
        self.currentUserID = current
        self.peerUserID = peer
    }
}

enum KitTransferResolution: Equatable {
    case match(TransferAcceptanceDTO)
    case missing
    case mismatch
}

enum KitTransferResolutionPolicy {
    /// A chat transfer event may only act on a backend transfer whose id, amount, currency, AND
    /// parties all match: the transfer must be exactly between the signed-in user and this
    /// conversation's peer. Fails closed when the backend omits either party.
    static func resolve(
        _ descriptor: KitPaymentMessage,
        in transfers: [TransferAcceptanceDTO],
        binding: KitTransferPartyBinding
    ) -> KitTransferResolution {
        guard descriptor.action == .transfer else { return .mismatch }
        let candidates = transfers.filter {
            $0.id.lowercased() == descriptor.paymentRequestId
        }
        guard !candidates.isEmpty else { return .missing }
        guard candidates.count == 1,
              let transfer = candidates.first,
              transfer.knownStatus != nil,
              descriptor.matchesAuthoritativeTransfer(transfer),
              let sender = transfer.senderUserId?.lowercased(),
              let recipient = transfer.recipientUserId?.lowercased(),
              sender != recipient,
              Set([sender, recipient]) == Set([binding.currentUserID, binding.peerUserID])
        else { return .mismatch }
        return .match(transfer)
    }
}

extension KitPaymentMessage {
    /// Field-exact check against the backend's transfer object.
    func matchesAuthoritativeTransfer(_ transfer: TransferAcceptanceDTO) -> Bool {
        guard let scale = Int(transfer.currency.scale),
              let transferMinor = Self.minorUnits(for: transfer.amount, scale: scale)
        else { return false }
        return transfer.id.lowercased() == paymentRequestId
            && transfer.currency.code == currencyCode
            && scale == currencyScale
            && transferMinor == amountMinor
    }
}

// MARK: - Offline thread fallback

/// The latest transfer outcome visible INSIDE the conversation itself, derived from the
/// encrypted response events (`accepted`/`rejected`/`reversed`) that reference a transfer id.
/// Used only as an offline hint — buttons always require the authoritative object — and only
/// when the event's author could truthfully produce that outcome: the transfer's recipient
/// authors accept/reject, its sender authors a reversal. A counterpart cannot forge the
/// outcome that is not theirs to declare (e.g. a payer forging "Accepted · Final" to make a
/// merchant hand over goods against a still-reversible payment).
enum KitTransferThreadStatePolicy {
    static func latestLocalOutcome(
        forTransferID transferID: String,
        transferIsOutgoing: Bool,
        messages: [LocalMessage]
    ) -> KitPaymentMessageAction? {
        var outcome: KitPaymentMessageAction?
        for message in messages {
            guard let descriptor = KitPaymentMessage.parse(message.body),
                  descriptor.paymentRequestId.caseInsensitiveCompare(transferID) == .orderedSame
            else { continue }
            switch descriptor.action {
            case .accepted, .rejected:
                // The recipient authors these: the opposite direction of the transfer event.
                if message.isOutgoing != transferIsOutgoing {
                    outcome = descriptor.action
                }
            case .reversed, .expired:
                // The sender authors this: the same direction as the transfer event.
                if message.isOutgoing == transferIsOutgoing {
                    outcome = descriptor.action
                }
            case .request, .paid, .declined, .cancelled, .transfer, .sent:
                continue
            }
        }
        return outcome
    }
}

// MARK: - Presentation

struct KitTransferMessagePresentation: Equatable {
    let title: String
    let statusText: String
    let showsAccept: Bool
    let showsReject: Bool
    let showsReverse: Bool

    var showsAnyAction: Bool { showsAccept || showsReject || showsReverse }
}

enum KitTransferMessagePresentationPolicy {
    /// Presentation ladder for a `.transfer` chat event and its response events.
    ///
    /// - The response events (`accepted`/`rejected`/`reversed`) are immutable receipts.
    /// - A `.transfer` event under the acceptance capability offers Accept/Reject to the
    ///   recipient and Reverse to the sender only while the AUTHORITATIVE status is still
    ///   `pending` — never from the descriptor or the thread hint alone.
    /// - Without the capability, a `transfer` event stays inert; immediate transfers use `sent`.
    static func presentation(
        for descriptor: KitPaymentMessage,
        isOutgoing: Bool,
        authoritativeTransfer: TransferAcceptanceDTO?,
        localOutcome: KitPaymentMessageAction?,
        binding: KitTransferPartyBinding?,
        acceptanceEnabled: Bool,
        isOnline: Bool
    ) -> KitTransferMessagePresentation {
        switch descriptor.action {
        case .accepted:
            return receipt(
                title: "Payment accepted",
                statusText: "The payment is now final."
            )
        case .rejected:
            return receipt(
                title: "Payment declined",
                statusText: isOutgoing
                    ? "You declined it. The money went back to the sender."
                    : "The money was returned to you."
            )
        case .reversed:
            return receipt(
                title: "Payment reversed",
                statusText: isOutgoing
                    ? "You reversed it before it was accepted."
                    : "The sender reversed it before it was accepted."
            )
        case .expired:
            return receipt(
                title: "Payment returned",
                statusText: "Not accepted within \(TransferAcceptanceWindowPolicy.acceptanceWindowDays) days"
            )
        case .sent:
            return receipt(
                title: isOutgoing ? "Payment sent" : "Payment received",
                statusText: "Completed"
            )
        case .request, .paid, .declined, .cancelled:
            // Requests/paid events belong to KitPaymentMessagePresentationPolicy.
            return receipt(title: "Payment", statusText: "")
        case .transfer:
            break
        }

        guard acceptanceEnabled else {
            return receipt(
                title: "Payment awaiting acceptance",
                statusText: isOnline ? "This payment cannot be updated yet" : "Connect to see the latest status"
            )
        }

        if let authoritativeTransfer,
           descriptor.matchesAuthoritativeTransfer(authoritativeTransfer) {
            // Buttons additionally bind to the transfer's OWN parties, never chat direction
            // alone: Accept/Reject belong to the transfer's recipient, Reverse to its sender.
            let currentUserID = binding?.currentUserID
            let currentUserIsRecipient = currentUserID != nil
                && authoritativeTransfer.recipientUserId?.lowercased() == currentUserID
            let currentUserIsSender = currentUserID != nil
                && authoritativeTransfer.senderUserId?.lowercased() == currentUserID
            switch authoritativeTransfer.knownStatus {
            case .pending:
                if isOutgoing {
                    return KitTransferMessagePresentation(
                        title: "Payment sent",
                        statusText: TransferAcceptanceWindowPolicy.pendingSenderCopy(
                            expiresAt: authoritativeTransfer.expiresAt
                        ) + (isOnline && authoritativeTransfer.canReverse
                            ? " You can still reverse it."
                            : ""),
                        showsAccept: false,
                        showsReject: false,
                        showsReverse: isOnline
                            && currentUserIsSender
                            && authoritativeTransfer.canReverse
                    )
                }
                return KitTransferMessagePresentation(
                    title: "Payment received",
                    statusText: isOnline
                        ? TransferAcceptanceWindowPolicy.pendingRecipientCopy(
                            expiresAt: authoritativeTransfer.expiresAt
                        )
                        : "Connect to accept or decline.",
                    showsAccept: isOnline
                        && currentUserIsRecipient
                        && authoritativeTransfer.canAccept,
                    showsReject: isOnline
                        && currentUserIsRecipient
                        && authoritativeTransfer.canReject,
                    showsReverse: false
                )
            case .accepted:
                return receipt(
                    title: isOutgoing ? "Payment sent" : "Payment received",
                    statusText: "Accepted · Final"
                )
            case .rejected:
                return receipt(
                    title: isOutgoing ? "Payment sent" : "Payment received",
                    statusText: "Declined · Money returned to the sender"
                )
            case .reversed:
                return receipt(
                    title: isOutgoing ? "Payment sent" : "Payment received",
                    statusText: "Reversed by the sender"
                )
            case .expired:
                return receipt(
                    title: isOutgoing ? "Payment sent" : "Payment received",
                    statusText: "Returned automatically · Not accepted within \(TransferAcceptanceWindowPolicy.acceptanceWindowDays) days"
                )
            case nil:
                return receipt(
                    title: isOutgoing ? "Payment sent" : "Payment received",
                    statusText: authoritativeTransfer.status
                        .replacingOccurrences(of: "_", with: " ")
                        .capitalized
                )
            }
        }

        // No authoritative object yet: response events already exchanged in this thread are a
        // truthful hint, and never enable a button.
        if let localOutcome {
            switch localOutcome {
            case .accepted:
                return receipt(
                    title: isOutgoing ? "Payment sent" : "Payment received",
                    statusText: "Accepted · Final"
                )
            case .rejected:
                return receipt(
                    title: isOutgoing ? "Payment sent" : "Payment received",
                    statusText: "Declined · Money returned to the sender"
                )
            case .reversed:
                return receipt(
                    title: isOutgoing ? "Payment sent" : "Payment received",
                    statusText: "Reversed by the sender"
                )
            case .expired:
                return receipt(
                    title: isOutgoing ? "Payment sent" : "Payment received",
                    statusText: "Returned automatically · Not accepted within \(TransferAcceptanceWindowPolicy.acceptanceWindowDays) days"
                )
            case .request, .paid, .declined, .cancelled, .transfer, .sent:
                break
            }
        }
        return receipt(
            title: isOutgoing ? "Payment sent" : "Payment received",
            statusText: isOnline ? "Verifying payment status" : "Connect to see the latest status"
        )
    }

    private static func receipt(
        title: String,
        statusText: String
    ) -> KitTransferMessagePresentation {
        KitTransferMessagePresentation(
            title: title,
            statusText: statusText,
            showsAccept: false,
            showsReject: false,
            showsReverse: false
        )
    }
}
