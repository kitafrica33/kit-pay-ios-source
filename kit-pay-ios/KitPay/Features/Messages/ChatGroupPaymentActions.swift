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
