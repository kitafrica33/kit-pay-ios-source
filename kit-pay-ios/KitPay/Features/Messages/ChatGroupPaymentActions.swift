import Foundation
import SwiftUI

// MARK: - View model

/// Server-authoritative state and actions for group payments shown as chat events.
///
/// The announcement in the thread is a label, not a source of truth: what a member may do, and
/// what they are owed, is re-read from the payment itself immediately before every action. The one
/// thing this model deliberately cannot do is settle a share by claim id — money sent into a group
/// is answered through the group, so accepting and declining go to the group payment's own
/// endpoints and appear nowhere in the one-to-one transfers inbox.
@MainActor
final class ChatGroupPaymentsViewModel: ObservableObject {
    /// Keyed by lowercased payment id.
    @Published private(set) var payments: [String: GroupPaymentDTO] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var actionPaymentId: String?
    @Published var errorMessage: String?

    private let api: APIClient

    init(api: APIClient = .shared) {
        self.api = api
    }

    /// Reads every payment the thread mentions. A failure leaves the cards in their verifying
    /// state rather than painting the chat red: the announcement is still readable, and a stale
    /// permission flag must never be what an accept button is drawn from.
    func load(isOnline: Bool, paymentIds: [String]) async {
        guard !isLoading, isOnline, !paymentIds.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        var seen: Set<String> = []
        for paymentId in paymentIds.suffix(60) {
            let paymentId = paymentId.lowercased()
            guard seen.insert(paymentId).inserted else { continue }
            if let payment = try? await api.groupPayment(id: paymentId) {
                store(payment)
            }
        }
    }

    /// The authoritative payment behind an announcement, but only when the two agree on every
    /// field the announcement states. A descriptor that disagrees is a bubble the thread cannot
    /// vouch for, and the card says so instead of offering buttons.
    func authoritativePayment(
        for descriptor: KitGroupPaymentMessage,
        conversationID: String,
        announcementSenderID: String
    ) -> GroupPaymentDTO? {
        guard let payment = payments[descriptor.groupPaymentId],
              descriptor.action == .sent,
              descriptor.matchesAuthoritativePayment(payment),
              GroupPaymentAuthorityPolicy.matchesContext(
                  payment,
                  conversationID: conversationID,
                  announcementSenderID: announcementSenderID
              )
        else { return nil }
        return payment
    }

    /// Whether the announcement and the server disagree about a payment we have actually loaded.
    func contradictsAuthoritativeState(
        _ descriptor: KitGroupPaymentMessage,
        conversationID: String,
        announcementSenderID: String
    ) -> Bool {
        guard descriptor.action == .sent, let payment = payments[descriptor.groupPaymentId] else {
            return false
        }
        return !descriptor.matchesAuthoritativePayment(payment)
            || !GroupPaymentAuthorityPolicy.matchesContext(
                payment,
                conversationID: conversationID,
                announcementSenderID: announcementSenderID
            )
    }

    /// Takes your own share. Never a step-up: this releases money already held in your wallet.
    func acceptShare(
        _ descriptor: KitGroupPaymentMessage,
        conversationID: String,
        announcementSenderID: String,
        groupPaymentsEnabled: Bool,
        isOnline: Bool
    ) async -> Bool {
        await settleShare(
            descriptor,
            conversationID: conversationID,
            announcementSenderID: announcementSenderID,
            groupPaymentsEnabled: groupPaymentsEnabled,
            isOnline: isOnline,
            expected: .accepted,
            serverAllows: \.canAccept,
            failureCopy: "Kit did not confirm accepting your share. Refresh and try again."
        ) { paymentId in
            try await self.api.acceptGroupPaymentShare(id: paymentId)
        }
    }

    /// Turns down your own share; it goes back to the sender.
    func rejectShare(
        _ descriptor: KitGroupPaymentMessage,
        conversationID: String,
        announcementSenderID: String,
        reason: String?,
        groupPaymentsEnabled: Bool,
        isOnline: Bool
    ) async -> Bool {
        let reason = ChatTransfersViewModel.canonicalReason(reason)
        return await settleShare(
            descriptor,
            conversationID: conversationID,
            announcementSenderID: announcementSenderID,
            groupPaymentsEnabled: groupPaymentsEnabled,
            isOnline: isOnline,
            expected: .rejected,
            serverAllows: \.canReject,
            failureCopy: "Kit did not confirm declining your share. Refresh and try again."
        ) { paymentId in
            try await self.api.rejectGroupPaymentShare(id: paymentId, reason: reason)
        }
    }

    /// Sender pulls back every share nobody has taken, in one step-up-approved move.
    func reverseUnclaimed(
        _ descriptor: KitGroupPaymentMessage,
        conversationID: String,
        announcementSenderID: String,
        reason: String?,
        groupPaymentsEnabled: Bool,
        pin: String,
        isOnline: Bool,
        authorize: KitFinancialStepUpAuthorization
    ) async -> Bool {
        let reason = ChatTransfersViewModel.canonicalReason(reason)
        guard let payment = await beginAction(
            descriptor,
            conversationID: conversationID,
            announcementSenderID: announcementSenderID,
            groupPaymentsEnabled: groupPaymentsEnabled,
            isOnline: isOnline
        ) else { return false }
        defer { actionPaymentId = nil }
        guard payment.canReverseUnclaimed, payment.pendingCount > 0 else {
            errorMessage = "There is nothing left to return on this payment."
            return false
        }
        do {
            let verification = try await authorize(
                GroupPaymentStepUpPolicy.reversePurpose,
                GroupPaymentStepUpPolicy.reverseIntent(
                    groupPaymentId: payment.id,
                    reason: reason
                ),
                pin,
                "Approve returning the unclaimed shares"
            )
            let resolved = try await api.reverseUnclaimedGroupPayment(
                id: payment.id,
                reason: reason,
                stepUpToken: verification.stepUpToken
            )
            guard resolved.id.caseInsensitiveCompare(payment.id) == .orderedSame,
                  resolved.pendingCount == 0
            else {
                throw ChatGroupPaymentFlowError.unconfirmed(
                    "Kit did not confirm returning the unclaimed shares. Refresh and try again."
                )
            }
            store(resolved)
            return true
        } catch {
            errorMessage = message(for: error)
            return false
        }
    }

    /// Sends one payment into the conversation.
    ///
    /// The step-up approval covers the whole send — the split, the members and their amounts — so
    /// it cannot be replayed against a different one. The idempotency key belongs to the composer
    /// and stays the same across retries, so a timeout that actually succeeded cannot pay twice.
    func send(
        conversationId: String,
        body: CreateGroupPaymentBody,
        idempotencyKey: String,
        groupPaymentsEnabled: Bool,
        pin: String,
        isOnline: Bool,
        authorize: KitFinancialStepUpAuthorization
    ) async -> GroupPaymentDTO? {
        guard actionPaymentId == nil else { return nil }
        guard groupPaymentsEnabled else {
            errorMessage = "Group payments are not available right now."
            return nil
        }
        guard isOnline else {
            errorMessage = "Connect to the internet first. A group payment cannot be queued offline."
            return nil
        }
        actionPaymentId = idempotencyKey
        errorMessage = nil
        defer { actionPaymentId = nil }
        do {
            let verification = try await authorize(
                GroupPaymentStepUpPolicy.sendPurpose,
                GroupPaymentStepUpPolicy.sendIntent(for: body, conversationId: conversationId),
                pin,
                "Approve this group payment"
            )
            let payment = try await api.createGroupPayment(
                conversationId: conversationId,
                body: body,
                idempotencyKey: idempotencyKey,
                stepUpToken: verification.stepUpToken
            )
            store(payment)
            return payment
        } catch {
            errorMessage = message(for: error)
            return nil
        }
    }

    private func settleShare(
        _ descriptor: KitGroupPaymentMessage,
        conversationID: String,
        announcementSenderID: String,
        groupPaymentsEnabled: Bool,
        isOnline: Bool,
        expected: GroupPaymentShareStatus,
        serverAllows: KeyPath<GroupPaymentShareDTO, Bool>,
        failureCopy: String,
        operation: (_ paymentId: String) async throws -> GroupPaymentDTO
    ) async -> Bool {
        guard let payment = await beginAction(
            descriptor,
            conversationID: conversationID,
            announcementSenderID: announcementSenderID,
            groupPaymentsEnabled: groupPaymentsEnabled,
            isOnline: isOnline
        ) else { return false }
        defer { actionPaymentId = nil }
        guard let share = payment.yourShare,
              share.knownStatus == .pending,
              share[keyPath: serverAllows]
        else {
            errorMessage = "Your share is not waiting anymore. Refresh to see its latest state."
            return false
        }
        do {
            let resolved = try await operation(payment.id)
            guard resolved.id.caseInsensitiveCompare(payment.id) == .orderedSame,
                  resolved.yourShare?.knownStatus == expected
            else {
                throw ChatGroupPaymentFlowError.unconfirmed(failureCopy)
            }
            store(resolved)
            return true
        } catch {
            errorMessage = message(for: error)
            return false
        }
    }

    /// Claims the in-flight marker and re-reads the payment. The marker is taken *before* the
    /// first suspension so a second tap cannot interleave at the refresh and settle twice.
    ///
    /// The caller must clear `actionPaymentId` — every caller does it with a `defer`.
    private func beginAction(
        _ descriptor: KitGroupPaymentMessage,
        conversationID: String,
        announcementSenderID: String,
        groupPaymentsEnabled: Bool,
        isOnline: Bool
    ) async -> GroupPaymentDTO? {
        guard actionPaymentId == nil else { return nil }
        guard groupPaymentsEnabled else {
            errorMessage = "Group payment decisions are not available right now."
            return nil
        }
        guard isOnline else {
            errorMessage =
                "Connect to the internet first. Group payment decisions cannot be queued offline."
            return nil
        }
        actionPaymentId = descriptor.groupPaymentId
        errorMessage = nil
        do {
            let refreshed = try await api.groupPayment(id: descriptor.groupPaymentId)
            store(refreshed)
            guard descriptor.action == .sent,
                  descriptor.matchesAuthoritativePayment(refreshed),
                  GroupPaymentAuthorityPolicy.matchesContext(
                      refreshed,
                      conversationID: conversationID,
                      announcementSenderID: announcementSenderID
                  )
            else {
                errorMessage = "Kit could not verify this payment in this group."
                actionPaymentId = nil
                return nil
            }
            return refreshed
        } catch {
            errorMessage = message(for: error)
            actionPaymentId = nil
            return nil
        }
    }

    private func store(_ payment: GroupPaymentDTO) {
        payments[payment.id.lowercased()] = payment
    }

    private func message(for error: Error) -> String {
        let message = (error as? APIErrorPayload)?.message ?? error.localizedDescription
        return CustomerFacingPaymentCopy.neutralizedServiceMessage(message)
    }
}

private enum ChatGroupPaymentFlowError: LocalizedError {
    case unconfirmed(String)

    var errorDescription: String? {
        switch self {
        case .unconfirmed(let copy): copy
        }
    }
}

// MARK: - Scheduled group payments

@MainActor
final class ChatScheduledGroupPaymentsViewModel: ObservableObject {
    @Published private(set) var items: [ScheduledGroupPaymentDTO] = []
    @Published private(set) var actionID: String?
    @Published var errorMessage: String?

    private struct PendingSubmission {
        let fingerprint: String
        let plan: ScheduledGroupPaymentPlanDTO
        let idempotencyKey: String
    }

    private let api: APIClient
    private var pendingSubmission: PendingSubmission?

    init(api: APIClient = .shared) {
        self.api = api
    }

    func load(conversationID: String, enabled: Bool, isOnline: Bool) async {
        guard enabled else {
            items = []
            return
        }
        guard isOnline, actionID == nil,
              let conversationID = ScheduledPaymentValidation.canonicalUUID(conversationID)
        else { return }
        actionID = "load"
        errorMessage = nil
        defer { actionID = nil }
        let previous = items
        do {
            var fetched: [ScheduledGroupPaymentDTO] = []
            for status in [
                ScheduledGroupPaymentStatus.scheduled,
                .queued,
                .processing,
            ] {
                fetched.append(contentsOf: try await pages(
                    conversationID: conversationID,
                    status: status
                ))
            }
            let fetchedIDs = Set(fetched.map { $0.id })
            var exact: [ScheduledGroupPaymentDTO] = []
            for known in previous where !fetchedIDs.contains(known.id) {
                if let value = try? await api.scheduledGroupPayment(id: known.id) {
                    exact.append(value)
                }
            }
            items = ScheduledGroupPaymentCollectionPolicy.reconcile(
                previous: previous,
                fetched: fetched,
                exact: exact,
                conversationID: conversationID
            )
        } catch {
            items = previous
            errorMessage = message(for: error)
        }
    }

    func schedule(
        conversationID rawConversationID: String,
        draft: CreateGroupPaymentBody,
        wallet: Wallet,
        scheduledFor requestedDate: Date,
        allowedRecipientIDs: Set<String>,
        pin: String,
        enabled: Bool,
        isOnline: Bool,
        authorize: KitFinancialStepUpAuthorization,
        now: Date = Date()
    ) async -> ScheduledGroupPaymentDTO? {
        guard actionID == nil else { return nil }
        guard enabled else {
            errorMessage = "Scheduled group payments are not available right now."
            return nil
        }
        guard isOnline else {
            errorMessage = "Connect to the internet to schedule this group payment."
            return nil
        }
        guard let conversationID = ScheduledPaymentValidation.canonicalUUID(rawConversationID),
              let scheduledFor = ScheduledSendPolicy.normalize(requestedDate, now: now)
        else {
            errorMessage = "Choose a time from one minute to one year from now."
            return nil
        }
        let allowed = Set(allowedRecipientIDs.compactMap(
            ScheduledPaymentValidation.canonicalUUID
        ))
        guard !allowed.isEmpty else {
            errorMessage = "No eligible group member can receive this payment."
            return nil
        }
        let previewBody = PreviewScheduledGroupPaymentBody(
            draft: draft,
            scheduledFor: scheduledFor
        )
        let fingerprint = Self.fingerprint(
            conversationID: conversationID,
            body: previewBody
        )
        actionID = fingerprint
        errorMessage = nil
        defer { actionID = nil }
        do {
            let plan: ScheduledGroupPaymentPlanDTO
            let idempotencyKey: String
            if let pendingSubmission,
               pendingSubmission.fingerprint == fingerprint,
               pendingSubmission.plan.expiryDate.map({ $0 > now }) == true {
                plan = pendingSubmission.plan
                idempotencyKey = pendingSubmission.idempotencyKey
            } else {
                plan = try await api.previewScheduledGroupPayment(
                    conversationId: conversationID,
                    body: previewBody
                )
                guard plan.matches(
                    draft: draft,
                    conversationID: conversationID,
                    wallet: wallet,
                    scheduledFor: scheduledFor,
                    allowedRecipientIDs: allowed,
                    now: now
                ) else { throw ChatGroupPaymentFlowError.unconfirmed(
                    "Kit could not verify the exact scheduled group payment. Nothing was scheduled."
                ) }
                idempotencyKey = "ios-scheduled-group-payment-\(UUID().uuidString.lowercased())"
                pendingSubmission = PendingSubmission(
                    fingerprint: fingerprint,
                    plan: plan,
                    idempotencyKey: idempotencyKey
                )
            }
            let verification = try await authorize(
                plan.stepUp.purpose,
                plan.stepUp.intent.fields,
                pin,
                "Approve this scheduled group payment"
            )
            let created = try await api.createScheduledGroupPayment(
                conversationId: conversationID,
                planId: plan.planId,
                idempotencyKey: idempotencyKey,
                stepUpToken: verification.stepUpToken
            )
            guard created.matches(plan: plan) else { throw ChatGroupPaymentFlowError.unconfirmed(
                "Kit did not confirm the exact schedule. Check the group before trying again."
            ) }
            pendingSubmission = nil
            upsert(created, conversationID: conversationID)
            return created
        } catch {
            errorMessage = message(for: error)
            return nil
        }
    }

    func cancel(
        _ schedule: ScheduledGroupPaymentDTO,
        conversationID rawConversationID: String,
        enabled: Bool,
        isOnline: Bool
    ) async {
        guard actionID == nil, enabled, isOnline,
              let conversationID = ScheduledPaymentValidation.canonicalUUID(rawConversationID)
        else {
            if !isOnline { errorMessage = "Connect to cancel this scheduled group payment." }
            return
        }
        actionID = schedule.id
        errorMessage = nil
        defer { actionID = nil }
        do {
            let latest = try await api.scheduledGroupPayment(id: schedule.id)
            guard latest.isStructurallyValid,
                  latest.conversationId == conversationID,
                  latest.knownStatus == .scheduled
            else { throw ChatGroupPaymentFlowError.unconfirmed(
                "This group payment has already started and can no longer be cancelled."
            ) }
            let cancelled = try await api.cancelScheduledGroupPayment(
                id: latest.id,
                idempotencyKey: "ios-scheduled-group-cancel-\(latest.id)"
            )
            guard cancelled.isStructurallyValid,
                  cancelled.id == latest.id,
                  cancelled.conversationId == conversationID,
                  cancelled.knownStatus == .cancelled
            else { throw ChatGroupPaymentFlowError.unconfirmed(
                "Kit did not confirm the cancellation. Refresh before trying again."
            ) }
            upsert(cancelled, conversationID: conversationID)
        } catch {
            errorMessage = message(for: error)
        }
    }

    func upsert(_ schedule: ScheduledGroupPaymentDTO, conversationID: String) {
        items = ScheduledGroupPaymentCollectionPolicy.reconcile(
            previous: items,
            fetched: [schedule],
            exact: [],
            conversationID: conversationID
        )
    }

    private func pages(
        conversationID: String,
        status: ScheduledGroupPaymentStatus
    ) async throws -> [ScheduledGroupPaymentDTO] {
        var result: [ScheduledGroupPaymentDTO] = []
        var before: String?
        var seen: Set<String> = []
        for _ in 0..<100 {
            let page = try await api.scheduledGroupPayments(
                conversationId: conversationID,
                status: status,
                before: before,
                limit: 100
            )
            guard page.isStructurallyValid,
                  page.items.allSatisfy({
                      $0.conversationId == conversationID && $0.knownStatus == status
                  })
            else { throw ChatGroupPaymentFlowError.unconfirmed(
                "Kit could not verify the scheduled group payments."
            ) }
            result.append(contentsOf: page.items)
            guard page.hasMore, let cursor = page.nextBefore else { return result }
            guard seen.insert(cursor).inserted else { throw ChatGroupPaymentFlowError.unconfirmed(
                "Kit could not verify the scheduled group payments."
            ) }
            before = cursor
        }
        throw ChatGroupPaymentFlowError.unconfirmed(
            "There are too many scheduled group payments to load safely."
        )
    }

    private static func fingerprint(
        conversationID: String,
        body: PreviewScheduledGroupPaymentBody
    ) -> String {
        let recipients = (body.recipients ?? []).map {
            "\($0.userId.lowercased()):\($0.amount ?? "")"
        }.joined(separator: ",")
        return [
            conversationID,
            body.sourceWalletId.lowercased(),
            body.splitMode,
            body.audience,
            body.totalAmount ?? "",
            body.note ?? "",
            recipients,
            body.scheduledFor,
        ].joined(separator: "\u{1F}")
    }

    private func message(for error: Error) -> String {
        let raw = (error as? APIErrorPayload)?.message ?? error.localizedDescription
        return CustomerFacingPaymentCopy.neutralizedServiceMessage(raw)
    }
}

enum ScheduledGroupPaymentCollectionPolicy {
    static func reconcile(
        previous: [ScheduledGroupPaymentDTO],
        fetched: [ScheduledGroupPaymentDTO],
        exact: [ScheduledGroupPaymentDTO],
        conversationID: String
    ) -> [ScheduledGroupPaymentDTO] {
        var byID: [String: ScheduledGroupPaymentDTO] = [:]
        for value in previous + fetched + exact {
            guard value.isStructurallyValid, value.conversationId == conversationID else { continue }
            if value.knownStatus?.isTerminal == true {
                byID[value.id] = nil
            } else {
                byID[value.id] = value
            }
        }
        return byID.values.sorted {
            if $0.scheduledDate != $1.scheduledDate {
                return ($0.scheduledDate ?? .distantFuture) < ($1.scheduledDate ?? .distantFuture)
            }
            return $0.id < $1.id
        }
    }
}

struct ScheduledGroupPaymentSection: View {
    let items: [ScheduledGroupPaymentDTO]
    let isOnline: Bool
    let actionID: String?
    let errorMessage: String?
    let onCancel: (ScheduledGroupPaymentDTO) -> Void

    var body: some View {
        VStack(spacing: 10) {
            Label(
                items.count == 1
                    ? "Scheduled group payment"
                    : "Scheduled group payments · \(items.count)",
                systemImage: "person.3.sequence.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(KitColor.secondaryText)

            ForEach(items) { schedule in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(statusTitle(schedule), systemImage: "clock.badge.checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(KitColor.gold)
                        Spacer()
                        if actionID == schedule.id { ProgressView().controlSize(.small) }
                    }
                    if let total = schedule.totalAmount {
                        Text(KitMoney.formatted(total, currency: schedule.currency))
                            .font(.title3.bold())
                            .foregroundStyle(KitColor.primaryText)
                    }
                    Text("For \(schedule.recipientCount) \(schedule.recipientCount == 1 ? "member" : "members") · \(scheduleLabel(schedule))")
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                    if let note = schedule.note, !note.isEmpty {
                        Text(note).font(.subheadline).foregroundStyle(KitColor.secondaryText)
                    }
                    Text("Kit will send this from the server even if this iPhone is offline.")
                        .font(.caption2)
                        .foregroundStyle(KitColor.secondaryText)
                }
                .padding(14)
                .frame(maxWidth: 320, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(KitColor.gold.opacity(0.42), lineWidth: 1)
                }
                .contextMenu {
                    if schedule.knownStatus == .scheduled {
                        Button(role: .destructive) { onCancel(schedule) } label: {
                            Label("Cancel payment", systemImage: "xmark.circle")
                        }
                        .disabled(!isOnline || actionID != nil)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 320, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func statusTitle(_ schedule: ScheduledGroupPaymentDTO) -> String {
        switch schedule.knownStatus {
        case .scheduled: "Scheduled"
        case .queued: "Queued securely"
        case .processing: "Sending"
        case .completed: "Completed"
        case .failed: "Not sent"
        case .cancelled: "Cancelled"
        case nil: "Scheduled group payment"
        }
    }

    private func scheduleLabel(_ schedule: ScheduledGroupPaymentDTO) -> String {
        schedule.scheduledDate?.formatted(date: .abbreviated, time: .shortened) ?? "scheduled"
    }
}

// MARK: - Collaborative group requests

/// Server-authoritative state for a target that group members can fund in several payments.
/// Encrypted `KITGREQ1` messages are discovery hints only: every amount, name, status and button
/// shown by the view is derived from a validated resource response.
@MainActor
final class ChatGroupPaymentRequestsViewModel: ObservableObject {
    @Published private(set) var requests: [String: GroupPaymentRequestDTO] = [:]
    @Published private(set) var exactContributions: [String: GroupPaymentRequestContributionDTO]
        = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var actionRequestID: String?
    @Published var errorMessage: String?

    private let api: APIClient

    init(api: APIClient = .shared) {
        self.api = api
    }

    func load(
        conversationID: String,
        requestIDs: [String],
        contributionReferences: [GroupPaymentRequestContributionReference] = [],
        isOnline: Bool
    ) async {
        guard !isLoading, isOnline, !requestIDs.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        var seenRequestIDs: Set<String> = []
        let orderedWanted = requestIDs.reversed().compactMap { raw -> String? in
            let id = raw.lowercased()
            return seenRequestIDs.insert(id).inserted ? id : nil
        }
        let wanted = Set(orderedWanted)
        do {
            let response = try await api.groupPaymentRequests(conversationId: conversationID)
            for request in response.items where wanted.contains(request.id.lowercased()) {
                storeIfValid(request, conversationID: conversationID)
            }
        } catch {
            // Continue into the exact reads below. A list failure must not turn an unverified
            // descriptor into a live card, but it must not strand a thread whose exact resource
            // remains available either.
        }
        // A successful conversation list can itself be truncated. Re-read every missing resource
        // named by the authenticated timeline rather than treating list success as completeness.
        for requestID in orderedWanted.prefix(60) where requests[requestID] == nil {
            if let request = try? await api.groupPaymentRequest(id: requestID) {
                storeIfValid(request, conversationID: conversationID)
            }
        }
        // The request embeds only the newest 50 rows. Older sync/E2EE contribution events resolve
        // through the exact request-scoped endpoint so a valid old event never disappears merely
        // because newer members have contributed since.
        var seenReferences: Set<GroupPaymentRequestContributionReference> = []
        let references = contributionReferences.reversed().compactMap { reference in
            seenReferences.insert(reference).inserted ? reference : nil
        }.prefix(200)
        for reference in references {
            let requestID = reference.requestID.lowercased()
            let contributionID = reference.contributionID.lowercased()
            let isEmbedded = requests[requestID]?.contributions.contains(where: {
                $0.id.caseInsensitiveCompare(contributionID) == .orderedSame
            }) == true
            guard wanted.contains(requestID),
                  exactContributions[contributionID] == nil,
                  let request = requests[requestID],
                  reference.requiresExactRead || !isEmbedded,
                  let contribution = try? await api.groupPaymentRequestContribution(
                      requestId: requestID,
                      contributionId: contributionID
                  ),
                  contribution.id.caseInsensitiveCompare(contributionID) == .orderedSame,
                  contribution.isStructurallyValid(currencyScale: request.currencyScale),
                  contribution.minorUnits.map({
                      $0 <= (request.contributedMinorUnits ?? -1)
                  }) == true
            else { continue }
            exactContributions[contributionID] = contribution
        }
    }

    func authoritativeRequest(
        for descriptor: KitGroupPaymentRequestMessage,
        conversationID: String,
        announcementSenderID: String
    ) -> GroupPaymentRequestDTO? {
        guard descriptor.action == .requested,
              let request = requests[descriptor.requestID],
              descriptor.matchesAuthoritativeRequest(request),
              GroupPaymentRequestAuthorityPolicy.matchesContext(
                  request,
                  conversationID: conversationID,
                  announcementSenderID: announcementSenderID
              )
        else { return nil }
        return request
    }

    func contradictsAuthoritativeState(
        _ descriptor: KitGroupPaymentRequestMessage,
        conversationID: String,
        announcementSenderID: String
    ) -> Bool {
        guard descriptor.action == .requested,
              let request = requests[descriptor.requestID]
        else { return false }
        return !descriptor.matchesAuthoritativeRequest(request)
            || !GroupPaymentRequestAuthorityPolicy.matchesContext(
                request,
                conversationID: conversationID,
                announcementSenderID: announcementSenderID
            )
    }

    func verifiedEventCopy(
        for descriptor: KitGroupPaymentRequestMessage,
        conversationID: String,
        messageAuthorID: String,
        isViewerAuthor: Bool,
        displayName: (String) -> String
    ) -> String? {
        guard descriptor.action != .requested,
              let request = requests[descriptor.requestID],
              request.isStructurallyValid,
              request.conversationId.caseInsensitiveCompare(conversationID) == .orderedSame
        else { return nil }
        switch descriptor.action {
        case .contributed:
            let exact = descriptor.contributionID.flatMap {
                exactContributions[$0.lowercased()]
            }
            guard let contribution = GroupPaymentRequestAuthorityPolicy.matchingContribution(
                for: descriptor,
                in: request,
                messageAuthorID: messageAuthorID,
                exactContribution: exact
            ) else { return nil }
            let actor = isViewerAuthor ? "You" : displayName(contribution.contributorUserId)
            let amount = KitMoney.formatted(
                contribution.amount,
                currency: request.currency,
                trimZeroFraction: true
            )
            return "\(actor) contributed \(amount) to this request."
        case .completed:
            let exact = descriptor.contributionID.flatMap {
                exactContributions[$0.lowercased()]
            }
            guard let exact,
                  GroupPaymentRequestAuthorityPolicy.terminalEventMatches(
                descriptor,
                request: request,
                messageAuthorID: messageAuthorID,
                exactContribution: exact
            ) else { return nil }
            let amount = KitMoney.formatted(
                exact.amount,
                currency: request.currency,
                trimZeroFraction: true
            )
            return GroupPaymentRequestCopy.completedContribution(
                contributorName: displayName(exact.contributorUserId),
                isViewerContributor: isViewerAuthor,
                formattedAmount: amount
            )
        case .cancelled:
            guard GroupPaymentRequestAuthorityPolicy.terminalEventMatches(
                descriptor,
                request: request,
                messageAuthorID: messageAuthorID
            ) else { return nil }
            return isViewerAuthor
                ? "You closed this payment request."
                : "\(displayName(request.requesterUserId)) closed this payment request."
        case .expired:
            guard GroupPaymentRequestAuthorityPolicy.terminalEventMatches(
                descriptor,
                request: request,
                messageAuthorID: messageAuthorID
            ) else { return nil }
            return "This payment request expired."
        case .requested:
            return nil
        }
    }

    func create(
        conversationID: String,
        requesterUserID: String,
        body: CreateGroupPaymentRequestBody,
        idempotencyKey: String,
        enabled: Bool,
        isOnline: Bool
    ) async -> GroupPaymentRequestDTO? {
        guard actionRequestID == nil else { return nil }
        guard enabled else {
            errorMessage = "Group payment requests are not available right now."
            return nil
        }
        guard isOnline else {
            errorMessage = "Connect to the internet to create a group payment request."
            return nil
        }
        actionRequestID = idempotencyKey
        errorMessage = nil
        defer { actionRequestID = nil }
        do {
            let request = try await api.createGroupPaymentRequest(
                conversationId: conversationID,
                body: body,
                idempotencyKey: idempotencyKey
            )
            guard GroupPaymentRequestAuthorityPolicy.matchesContext(
                request,
                conversationID: conversationID,
                announcementSenderID: requesterUserID
            ) else { throw ChatGroupPaymentFlowError.unconfirmed(
                "Kit created the request, but could not verify its group. Refresh before retrying."
            ) }
            store(request)
            return request
        } catch {
            errorMessage = message(for: error)
            return nil
        }
    }

    func contribute(
        descriptor: KitGroupPaymentRequestMessage,
        conversationID: String,
        announcementSenderID: String,
        currentUserID: String,
        wallet: Wallet,
        amountInput: String,
        idempotencyKey: String,
        pin: String,
        enabled: Bool,
        isOnline: Bool,
        authorize: KitFinancialStepUpAuthorization
    ) async -> GroupPaymentRequestContributionResultDTO? {
        guard actionRequestID == nil else { return nil }
        guard enabled else {
            errorMessage = "Contributions are not available right now."
            return nil
        }
        guard isOnline else {
            errorMessage = "Connect to the internet to contribute to this request."
            return nil
        }
        actionRequestID = descriptor.requestID
        errorMessage = nil
        defer { actionRequestID = nil }
        do {
            let request = try await api.groupPaymentRequest(id: descriptor.requestID)
            store(request)
            guard descriptor.action == .requested,
                  descriptor.matchesAuthoritativeRequest(request),
                  GroupPaymentRequestAuthorityPolicy.matchesContext(
                      request,
                      conversationID: conversationID,
                      announcementSenderID: announcementSenderID
                  ),
                  request.requesterUserId.caseInsensitiveCompare(currentUserID) != .orderedSame,
                  let amount = GroupPaymentRequestContributionPolicy.canonicalAmount(
                      amountInput,
                      request: request,
                      wallet: wallet
                  )
            else { throw ChatGroupPaymentFlowError.unconfirmed(
                "This request changed or the amount is no longer available. Review it and try again."
            ) }
            let verification = try await authorize(
                GroupPaymentRequestContributionPolicy.purpose,
                GroupPaymentRequestContributionPolicy.intent(
                    requestID: request.id,
                    sourceWalletID: wallet.id,
                    amount: amount,
                    currencyCode: request.currency.code
                ),
                pin,
                "Approve this group contribution"
            )
            let result = try await api.contributeToGroupPaymentRequest(
                id: request.id,
                sourceWalletId: wallet.id,
                amount: amount,
                idempotencyKey: idempotencyKey,
                stepUpToken: verification.stepUpToken
            )
            guard result.isStructurallyValid,
                  result.request.id.caseInsensitiveCompare(request.id) == .orderedSame,
                  result.request.conversationId.caseInsensitiveCompare(conversationID)
                    == .orderedSame,
                  result.request.requesterUserId.caseInsensitiveCompare(announcementSenderID)
                    == .orderedSame,
                  result.contribution.contributorUserId.caseInsensitiveCompare(currentUserID)
                    == .orderedSame,
                  result.contribution.amount == amount
            else { throw ChatGroupPaymentFlowError.unconfirmed(
                "Kit could not confirm this contribution. Check Wallet activity before retrying."
            ) }
            store(result.request)
            // This mutation response is the exact request-scoped contribution resource. Retain
            // it separately from the bounded request window so a completing contribution can be
            // rendered immediately without weakening the same exact-read rule used during sync.
            exactContributions[result.contribution.id.lowercased()] = result.contribution
            return result
        } catch {
            if let payload = error as? APIErrorPayload, payload.httpStatus == 409,
               let refreshed = try? await api.groupPaymentRequest(id: descriptor.requestID) {
                store(refreshed)
            }
            errorMessage = message(for: error)
            return nil
        }
    }

    func cancel(
        descriptor: KitGroupPaymentRequestMessage,
        conversationID: String,
        announcementSenderID: String,
        idempotencyKey: String,
        enabled: Bool,
        isOnline: Bool
    ) async -> GroupPaymentRequestDTO? {
        guard actionRequestID == nil else { return nil }
        guard enabled, isOnline else {
            errorMessage = enabled
                ? "Connect to the internet to close this request."
                : "Group payment requests are not available right now."
            return nil
        }
        actionRequestID = descriptor.requestID
        errorMessage = nil
        defer { actionRequestID = nil }
        do {
            let current = try await api.groupPaymentRequest(id: descriptor.requestID)
            store(current)
            guard descriptor.action == .requested,
                  descriptor.matchesAuthoritativeRequest(current),
                  GroupPaymentRequestAuthorityPolicy.matchesContext(
                      current,
                      conversationID: conversationID,
                      announcementSenderID: announcementSenderID
                  ),
                  current.knownStatus == .open,
                  current.canCancel
            else { throw ChatGroupPaymentFlowError.unconfirmed(
                "This request is no longer open. Refresh to see its latest status."
            ) }
            let resolved = try await api.cancelGroupPaymentRequest(
                id: current.id,
                idempotencyKey: idempotencyKey
            )
            guard resolved.isStructurallyValid,
                  resolved.id.caseInsensitiveCompare(current.id) == .orderedSame,
                  resolved.knownStatus == .cancelled
            else { throw ChatGroupPaymentFlowError.unconfirmed(
                "Kit did not confirm closing this request. Refresh before trying again."
            ) }
            store(resolved)
            return resolved
        } catch {
            if let refreshed = try? await api.groupPaymentRequest(id: descriptor.requestID) {
                store(refreshed)
            }
            errorMessage = message(for: error)
            return nil
        }
    }

    private func storeIfValid(_ request: GroupPaymentRequestDTO, conversationID: String) {
        guard request.isStructurallyValid,
              request.conversationId.caseInsensitiveCompare(conversationID) == .orderedSame
        else { return }
        store(request)
    }

    private func store(_ request: GroupPaymentRequestDTO) {
        guard request.isStructurallyValid else { return }
        requests[request.id.lowercased()] = request
    }

    private func message(for error: Error) -> String {
        let message = (error as? APIErrorPayload)?.message ?? error.localizedDescription
        return CustomerFacingPaymentCopy.neutralizedServiceMessage(message)
    }
}

// MARK: - Collaborative request card

struct GroupPaymentRequestCardView: View {
    let request: GroupPaymentRequestDTO?
    let contradictsServer: Bool
    let senderName: String
    let currentUserID: String?
    let displayName: (String) -> String
    let isBusy: Bool
    let contribute: () -> Void
    let payRemaining: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("Group payment request", systemImage: "chart.pie.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(KitColor.gold)
                .textCase(.uppercase)

            if contradictsServer {
                verificationFailure
            } else if let request {
                verifiedContent(request)
            } else {
                HStack(spacing: 10) {
                    ProgressView().tint(KitColor.gold)
                    Text("Verifying this request with Kit…")
                        .font(.footnote)
                        .foregroundStyle(KitColor.secondaryText)
                }
            }
        }
        .padding(17)
        .frame(maxWidth: 390, alignment: .leading)
        .background(KitColor.paleGold, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(KitColor.goldSheen, lineWidth: 1.4)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
    }

    private var verificationFailure: some View {
        Label(
            "Kit could not verify this request. No payment action is available.",
            systemImage: "exclamationmark.shield.fill"
        )
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func verifiedContent(_ request: GroupPaymentRequestDTO) -> some View {
        Text("\(requesterCopy(request)) is collecting")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(KitColor.primaryText)
        Text(KitMoney.formatted(
            request.targetAmount,
            currency: request.currency,
            trimZeroFraction: true
        ))
            .font(.system(size: 30, weight: .heavy, design: .rounded))
            .foregroundStyle(KitColor.primaryText)
            .minimumScaleFactor(0.75)
        if let note = request.note, !note.isEmpty {
            Text(note)
                .font(.footnote)
                .foregroundStyle(KitColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 7) {
            ProgressView(value: Double(request.progressBasisPoints), total: 10_000)
                .tint(KitColor.gold)
            HStack {
                Text(GroupPaymentRequestCopy.progressPercent(request.progressBasisPoints))
                    .font(.caption.bold().monospacedDigit())
                Spacer()
                Text("\(formatted(request.contributedAmount, request)) contributed")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(KitColor.secondaryText)
            Text("\(formatted(request.remainingAmount, request)) remaining")
                .font(.footnote)
                .foregroundStyle(KitColor.secondaryText)
        }

        if !request.contributions.isEmpty {
            Divider().overlay(KitColor.gold.opacity(0.3))
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(request.contributions.suffix(5))) { contribution in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(KitColor.green)
                        Text(contributorName(contribution))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(KitColor.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(formatted(contribution.amount, request))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(KitColor.secondaryText)
                    }
                }
                let hiddenCount = max(0, request.contributionCount - 5)
                if hiddenCount > 0 {
                    Text("\(hiddenCount) earlier \(hiddenCount == 1 ? "contribution" : "contributions")")
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                }
            }
        }

        statusAndActions(request)
    }

    @ViewBuilder
    private func statusAndActions(_ request: GroupPaymentRequestDTO) -> some View {
        switch request.knownStatus {
        case .open:
            if request.canContribute {
                HStack(spacing: 10) {
                    Button("Contribute", action: contribute)
                        .buttonStyle(KitSecondaryButtonStyle())
                    Button("Pay remaining", action: payRemaining)
                        .buttonStyle(GroupPaymentGoldButtonStyle())
                }
                .disabled(isBusy)
            } else if request.canCancel {
                Button("Close request", role: .destructive, action: cancel)
                    .buttonStyle(KitSecondaryButtonStyle())
                    .disabled(isBusy)
            } else {
                statusLabel("Open", symbol: "clock.fill", color: KitColor.gold)
            }
        case .completed:
            statusLabel("Complete — 100% funded", symbol: "checkmark.seal.fill", color: KitColor.green)
        case .cancelled:
            statusLabel("Closed", symbol: "xmark.circle.fill", color: KitColor.secondaryText)
        case .expired:
            statusLabel("Expired", symbol: "clock.badge.exclamationmark", color: .orange)
        case nil:
            verificationFailure
        }
    }

    private func statusLabel(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(color)
    }

    private func requesterCopy(_ request: GroupPaymentRequestDTO) -> String {
        guard let currentUserID else { return senderName }
        return request.requesterUserId.caseInsensitiveCompare(currentUserID) == .orderedSame
            ? "You"
            : senderName
    }

    private func contributorName(_ contribution: GroupPaymentRequestContributionDTO) -> String {
        if contribution.contributorUserId.caseInsensitiveCompare(currentUserID ?? "") == .orderedSame {
            return "You"
        }
        return displayName(contribution.contributorUserId)
    }

    private func formatted(_ amount: String, _ request: GroupPaymentRequestDTO) -> String {
        KitMoney.formatted(amount, currency: request.currency, trimZeroFraction: true)
    }
}

// MARK: - The golden card

/// A group payment as it appears in the thread: gold, centred, and showing each member only what
/// is theirs — their own share and their own buttons, never the pot when the pot was not shared.
struct GroupPaymentCardView: View {
    let descriptor: KitGroupPaymentMessage
    let payment: GroupPaymentDTO?
    let contradictsServer: Bool
    let isOutgoing: Bool
    let senderName: String
    /// Resolves a member's display name from their user id.
    let displayName: (String) -> String
    let isBusy: Bool
    let accept: () -> Void
    let decline: () -> Void
    let returnUnclaimed: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text(announcement)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KitColor.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(KitColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = descriptor.note {
                Text(note)
                    .font(.footnote.italic())
                    .foregroundStyle(KitColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if contradictsServer {
                Label(
                    "Kit could not verify this payment. Open your wallet to check it.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let payment {
                Divider().overlay(KitColor.gold.opacity(0.3))
                if let share = payment.yourShare {
                    yourShare(share, in: payment)
                }
                if isOutgoing || payment.canReverseUnclaimed {
                    senderSummary(payment)
                }
                recipientRoll(payment)
            } else {
                ProgressView()
                    .tint(KitColor.gold)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(16)
        .frame(maxWidth: 360, alignment: .leading)
        .background(KitColor.paleGold, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(KitColor.goldSheen, lineWidth: 1.4)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(announcement)
    }

    private var header: some View {
        Label {
            Text("Group payment")
                .font(.caption.weight(.bold))
                .foregroundStyle(KitColor.gold)
                .textCase(.uppercase)
        } icon: {
            Image(systemName: "banknote.fill")
                .foregroundStyle(KitColor.gold)
        }
        .accessibilityHidden(true)
    }

    private var announcement: String {
        GroupPaymentCopy.announcement(
            for: descriptor,
            senderName: senderName,
            isViewerSender: isOutgoing,
            recipientNames: descriptor.recipientUserIds.map(displayName),
            // Only ever the sender's own view: the server withholds the pot of a custom split
            // from everybody else, so there is nothing here to leak.
            totalOverride: isOutgoing ? payment?.totalAmount : nil
        )
    }

    private var subtitle: String? {
        GroupPaymentCopy.evenShareSubtitle(for: descriptor)
    }

    @ViewBuilder
    private func yourShare(_ share: GroupPaymentShareDTO, in payment: GroupPaymentDTO) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your share")
                .font(.caption.weight(.semibold))
                .foregroundStyle(KitColor.secondaryText)
            Text(KitMoney.formatted(share.amount, currency: payment.currency))
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(KitColor.primaryText)
            if let status = share.knownStatus {
                Text(GroupPaymentCopy.shareStatus(status))
                    .font(.footnote)
                    .foregroundStyle(KitColor.secondaryText)
            }
            if share.canAccept || share.canReject {
                HStack(spacing: 10) {
                    if share.canAccept {
                        Button(action: accept) {
                            if isBusy {
                                ProgressView().tint(.white).frame(maxWidth: .infinity)
                            } else {
                                Label("Take my share", systemImage: "checkmark")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(GroupPaymentGoldButtonStyle())
                        .disabled(isBusy)
                    }
                    if share.canReject {
                        Button("Decline", action: decline)
                            .buttonStyle(KitSecondaryButtonStyle())
                            .disabled(isBusy)
                    }
                }
                Text(GroupPaymentCopy.groupOnlyClaimNote)
                    .font(.caption2)
                    .foregroundStyle(KitColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func senderSummary(_ payment: GroupPaymentDTO) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(GroupPaymentCopy.progress(for: payment))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(KitColor.secondaryText)
            if payment.canReverseUnclaimed, payment.pendingCount > 0 {
                Button(action: returnUnclaimed) {
                    Label("Return what is unclaimed", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KitSecondaryButtonStyle())
                .disabled(isBusy)
            }
        }
    }

    /// Who was paid and where each of them has got to. Amounts appear only on the lines the
    /// server chose to fill in — for a custom split that is the sender's view and your own line.
    @ViewBuilder
    private func recipientRoll(_ payment: GroupPaymentDTO) -> some View {
        if !payment.recipients.isEmpty, payment.recipients.count <= 12 {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(payment.recipients) { recipient in
                    HStack(spacing: 8) {
                        Text(recipient.name ?? recipient.userId.map(displayName) ?? "Kit Pay user")
                            .font(.footnote)
                            .foregroundStyle(KitColor.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let amount = recipient.amount {
                            Text(KitMoney.formatted(amount, currency: payment.currency))
                                .font(.footnote.weight(.semibold).monospacedDigit())
                                .foregroundStyle(KitColor.primaryText)
                        }
                        if let status = recipient.knownStatus {
                            Text(GroupPaymentCopy.recipientStatus(status))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(KitColor.secondaryText)
                        }
                    }
                }
            }
        }
    }
}

/// Gold where the rest of the app is green: the same shape as `KitPrimaryButtonStyle`, so a group
/// payment's buttons sit at the same weight as every other money action.
struct GroupPaymentGoldButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.vertical, 13)
            .padding(.horizontal, 16)
            .background(
                KitColor.gold.opacity(configuration.isPressed ? 0.78 : 1),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .shadow(
                color: KitColor.gold.opacity(configuration.isPressed ? 0.08 : 0.24),
                radius: 12,
                y: 6
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

/// One member's answer, shown the way a date heading is: small, centred, unobtrusive. It states
/// only what its author did, which is the only thing the thread can vouch for offline.
struct GroupPaymentOutcomeChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(KitColor.gold)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(KitColor.paleGold, in: Capsule())
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }
}

// MARK: - Answering sheets

/// Collects the optional reason before a member's share goes back to the sender.
struct GroupPaymentDeclineView: View {
    @Environment(\.dismiss) private var dismiss
    let shareAmount: String
    let isSubmitting: Bool
    let errorMessage: String?
    let submit: (String?) async -> Bool
    @State private var reason = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(KitColor.gold)
                Text("Decline your share")
                    .font(.title2.bold())
                Text("\(shareAmount) goes back to the sender. The rest of the group keeps theirs.")
                    .font(.subheadline)
                    .foregroundStyle(KitColor.secondaryText)
                    .multilineTextAlignment(.center)
                TextField("Reason (optional)", text: $reason, axis: .vertical)
                    .lineLimit(2 ... 4)
                    .padding(14)
                    .kitGlass(cornerRadius: 16)
                    .onChange(of: reason) { _, value in
                        reason = ChatTransfersViewModel.canonicalReason(value) ?? ""
                    }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Button {
                    Task {
                        if await submit(reason) {
                            reason = ""
                            dismiss()
                        }
                    }
                } label: {
                    if isSubmitting {
                        ProgressView().tint(.white).frame(maxWidth: .infinity)
                    } else {
                        Label("Decline and return", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(GroupPaymentGoldButtonStyle())
                .disabled(isSubmitting)
                Spacer()
            }
            .padding(22)
            .background(KitColor.canvas.ignoresSafeArea())
            .navigationTitle("Decline share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// Confirms returning every share nobody has taken yet, with biometrics or the wallet PIN.
struct GroupPaymentReturnView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let pendingCount: Int
    let isSubmitting: Bool
    let errorMessage: String?
    let submit: (String?, String) async -> Bool
    @State private var reason = ""
    @State private var pin = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(KitColor.gold)
                        .frame(width: 88, height: 88)
                        .kitGlass(cornerRadius: 28, tint: KitColor.paleGold)
                    Text("Return the unclaimed shares")
                        .font(.title2.bold())
                        .foregroundStyle(KitColor.primaryText)
                    Text(shareCountCopy)
                        .font(.subheadline)
                        .foregroundStyle(KitColor.secondaryText)
                        .multilineTextAlignment(.center)

                    TextField("Reason (optional)", text: $reason, axis: .vertical)
                        .lineLimit(2 ... 4)
                        .padding(14)
                        .kitGlass(cornerRadius: 16)
                        .onChange(of: reason) { _, value in
                            reason = ChatTransfersViewModel.canonicalReason(value) ?? ""
                        }

                    if model.financialApprovalUsesBiometrics {
                        Label {
                            Text("Approve with \(model.biometricDisplayName). Your approval covers only this payment and reason.")
                                .font(.footnote)
                                .foregroundStyle(KitColor.secondaryText)
                        } icon: {
                            Image(systemName: model.biometricSymbolName)
                                .foregroundStyle(KitColor.gold)
                        }
                        .padding(17)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .kitGlass(cornerRadius: 18, tint: KitColor.paleGold, shadow: false)
                    } else {
                        SecureField("4-digit wallet PIN", text: $pin)
                            .keyboardType(.numberPad)
                            .textContentType(.password)
                            .multilineTextAlignment(.center)
                            .font(.title2.monospacedDigit())
                            .padding(17)
                            .kitGlass(cornerRadius: 18)
                            .onChange(of: pin) { _, value in
                                pin = String(value.filter(\.isNumber).prefix(4))
                            }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        Task {
                            if await submit(reason, pin) {
                                pin = ""
                                reason = ""
                                dismiss()
                            }
                        }
                    } label: {
                        if isSubmitting {
                            ProgressView().tint(.white).frame(maxWidth: .infinity)
                        } else {
                            Label(
                                "Return unclaimed shares",
                                systemImage: model.financialApprovalUsesBiometrics
                                    ? model.biometricSymbolName
                                    : "lock.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(GroupPaymentGoldButtonStyle())
                    .disabled(
                        isSubmitting
                            || (!model.financialApprovalUsesBiometrics && pin.count != 4)
                    )
                }
                .padding(22)
            }
            .background(KitColor.canvas.ignoresSafeArea())
            .navigationTitle("Return shares")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var shareCountCopy: String {
        let shares = pendingCount == 1 ? "1 share" : "\(pendingCount) shares"
        return "\(shares) nobody has taken yet will come back to your wallet. Shares that have already been taken stay where they are."
    }
}
