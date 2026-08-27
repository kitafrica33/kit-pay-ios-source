import Foundation
import SwiftUI

// MARK: - View model

/// Server-authoritative accept/reject/reverse actions for Kit Pay → Kit Pay transfers shown as
/// chat events. State is never guessed offline; the claim is re-read immediately before every
/// action and the backend settles each claim exactly once.
@MainActor
final class ChatTransfersViewModel: ObservableObject {
    @Published private(set) var items: [TransferAcceptanceDTO] = []
    @Published private(set) var isLoading = false
    @Published private(set) var actionTransferId: String?
    @Published var errorMessage: String?

    private let api: APIClient
    init(api: APIClient = .shared) {
        self.api = api
    }

    func load(isOnline: Bool, transferIds: [String] = []) async {
        guard !isLoading, isOnline else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            items = try await api.transferAcceptances().items
            var loaded = Set(items.map { $0.id.lowercased() })
            for transferId in transferIds.suffix(100) {
                let transferId = transferId.lowercased()
                guard loaded.insert(transferId).inserted else { continue }
                if let transfer = try? await api.transferAcceptance(transferId: transferId) {
                    upsert(transfer)
                }
            }
        } catch {
            // A capability rollout gap or old backend must not paint the chat red; the
            // transfer bubbles simply stay in their verifying state.
            items = []
        }
    }

    func authoritativeTransfer(
        for descriptor: KitPaymentMessage,
        binding: KitTransferPartyBinding?
    ) -> TransferAcceptanceDTO? {
        guard let binding,
              case .match(let transfer) = KitTransferResolutionPolicy.resolve(
                  descriptor,
                  in: items,
                  binding: binding
              )
        else { return nil }
        return transfer
    }

    /// Recipient accepts: money becomes finally theirs.
    func accept(
        _ descriptor: KitPaymentMessage,
        binding: KitTransferPartyBinding?,
        acceptanceEnabled: Bool,
        isOnline: Bool
    ) async -> Bool {
        return await performResolution(
            descriptor,
            binding: binding,
            acceptanceEnabled: acceptanceEnabled,
            isOnline: isOnline,
            expectedStatus: .accepted,
            serverAllows: \.canAccept,
            failureCopy: "Kit did not confirm accepting this payment. Refresh and try again."
        ) { transferId in
            try await self.api.acceptTransfer(transferId: transferId)
        }
    }

    /// Recipient rejects: money returns to the sender.
    func reject(
        _ descriptor: KitPaymentMessage,
        binding: KitTransferPartyBinding?,
        reason: String?,
        acceptanceEnabled: Bool,
        isOnline: Bool
    ) async -> Bool {
        let reason = Self.canonicalReason(reason)
        return await performResolution(
            descriptor,
            binding: binding,
            acceptanceEnabled: acceptanceEnabled,
            isOnline: isOnline,
            expectedStatus: .rejected,
            serverAllows: \.canReject,
            failureCopy: "Kit did not confirm declining this payment. Refresh and try again."
        ) { transferId in
            try await self.api.rejectTransfer(transferId: transferId, reason: reason)
        }
    }

    /// Sender reverses a not-yet-accepted transfer with a claim-bound step-up proof.
    func reverse(
        _ descriptor: KitPaymentMessage,
        binding: KitTransferPartyBinding?,
        reason: String?,
        acceptanceEnabled: Bool,
        pin: String,
        isOnline: Bool,
        authorize: KitFinancialStepUpAuthorization
    ) async -> Bool {
        let reason = Self.canonicalReason(reason)
        return await performResolution(
            descriptor,
            binding: binding,
            acceptanceEnabled: acceptanceEnabled,
            isOnline: isOnline,
            expectedStatus: .reversed,
            serverAllows: \.canReverse,
            failureCopy: "Kit did not confirm reversing this payment. Refresh and try again."
        ) { transferId in
            let verification = try await authorize(
                "wallet_transfer_reverse",
                [
                    "action": "reverse",
                    "claim_id": transferId,
                    "reason": reason,
                ],
                pin,
                "Approve reversing this payment"
            )
            return try await self.api.reverseTransfer(
                transferId: transferId,
                reason: reason,
                stepUpToken: verification.stepUpToken
            )
        }
    }

    private func performResolution(
        _ descriptor: KitPaymentMessage,
        binding: KitTransferPartyBinding?,
        acceptanceEnabled: Bool,
        isOnline: Bool,
        expectedStatus: TransferAcceptanceStatus,
        serverAllows: KeyPath<TransferAcceptanceDTO, Bool>,
        failureCopy: String,
        operation: (_ transferId: String) async throws -> TransferAcceptanceDTO
    ) async -> Bool {
        guard actionTransferId == nil else { return false }
        guard acceptanceEnabled else {
            errorMessage = "Transfer decisions are not available right now."
            return false
        }
        guard isOnline else {
            errorMessage =
                "Connect to the internet first. Transfer decisions cannot be queued offline."
            return false
        }
        // Claim the in-flight marker BEFORE any suspension: the actor can interleave a second
        // tap at the refresh await, and Accept-then-Decline must never race two resolutions.
        actionTransferId = descriptor.paymentRequestId
        errorMessage = nil
        defer { actionTransferId = nil }
        // Re-read the authoritative state at the moment of acting. A failed fetch must never
        // fall back to a cached permission flag because the other party may already have settled.
        let refreshed: TransferAcceptanceDTO
        do {
            refreshed = try await api.transferAcceptance(
                transferId: descriptor.paymentRequestId
            )
            upsert(refreshed)
        } catch {
            errorMessage = message(for: error)
            return false
        }
        guard let binding,
              case .match(let transfer) = KitTransferResolutionPolicy.resolve(
                  descriptor,
                  in: [refreshed],
                  binding: binding
              ),
              transfer.knownStatus == .pending,
              transfer[keyPath: serverAllows]
        else {
            errorMessage = "This payment is not pending anymore. Refresh to see its latest state."
            return false
        }
        do {
            let resolved = try await operation(transfer.id)
            guard resolved.id.caseInsensitiveCompare(transfer.id) == .orderedSame,
                  resolved.knownStatus == expectedStatus
            else {
                throw ChatTransferFlowError.unconfirmedResolution(failureCopy)
            }
            upsert(resolved)
            return true
        } catch {
            errorMessage = message(for: error)
            return false
        }
    }

    private func upsert(_ transfer: TransferAcceptanceDTO) {
        if let index = items.firstIndex(where: {
            $0.id.caseInsensitiveCompare(transfer.id) == .orderedSame
        }) {
            items[index] = transfer
        } else {
            items.append(transfer)
        }
    }

    private func message(for error: Error) -> String {
        let message = (error as? APIErrorPayload)?.message ?? error.localizedDescription
        return CustomerFacingPaymentCopy.neutralizedServiceMessage(message)
    }

    nonisolated static func canonicalReason(_ reason: String?) -> String? {
        guard let clean = reason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clean.isEmpty
        else { return nil }
        var result = ""
        for character in clean {
            guard result.utf16.count + String(character).utf16.count
                    <= KitPaymentMessage.maximumReasonLength
            else { break }
            result.append(character)
        }
        return result.isEmpty ? nil : result
    }

    nonisolated static func autoReversalReceiptReason(_ serverReason: String?) -> String {
        canonicalReason(serverReason) ?? TransferAcceptanceWindowPolicy.autoReversalReason
    }
}

private enum ChatTransferFlowError: LocalizedError {
    case unconfirmedResolution(String)

    var errorDescription: String? {
        switch self {
        case .unconfirmedResolution(let copy): copy
        }
    }
}

// MARK: - Reverse approval sheet

/// Confirms reversal with biometrics or wallet PIN and collects the sender's optional reason.
struct TransferReverseApprovalView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let descriptor: KitPaymentMessage
    let recipientName: String
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
                        .foregroundStyle(KitColor.green)
                        .frame(width: 88, height: 88)
                        .kitGlass(cornerRadius: 28, tint: KitColor.paleGreen)
                    Text("Reverse this payment")
                        .font(.title2.bold())
                        .foregroundStyle(KitColor.primaryText)
                    Text(KitMoney.formatted(descriptor.decimalAmount, code: descriptor.currencyCode, scale: descriptor.currencyScale))
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(KitColor.primaryText)
                    Text("\(recipientName) has not accepted it yet, so the money returns to your wallet. Once they accept, a payment can no longer be reversed.")
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
                            Text("Approve with \(model.biometricDisplayName). Your approval covers only this transfer and reason.")
                                .font(.footnote)
                                .foregroundStyle(KitColor.secondaryText)
                        } icon: {
                            Image(systemName: model.biometricSymbolName)
                                .foregroundStyle(KitColor.green)
                        }
                        .padding(17)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .kitGlass(cornerRadius: 18, tint: KitColor.paleGreen, shadow: false)
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
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity)
                        } else {
                            Label(
                                "Reverse \(KitMoney.formatted(descriptor.decimalAmount, code: descriptor.currencyCode, scale: descriptor.currencyScale))",
                                systemImage: model.financialApprovalUsesBiometrics
                                    ? model.biometricSymbolName
                                    : "lock.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(KitPrimaryButtonStyle())
                    .disabled(
                        isSubmitting
                            || (!model.financialApprovalUsesBiometrics && pin.count != 4)
                    )
                }
                .padding(22)
            }
            .background(KitColor.canvas.ignoresSafeArea())
            .navigationTitle("Reverse payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// Collects the recipient's optional reason before returning a held transfer to its sender.
struct TransferRejectApprovalView: View {
    @Environment(\.dismiss) private var dismiss
    let descriptor: KitPaymentMessage
    let isSubmitting: Bool
    let errorMessage: String?
    let submit: (String?) async -> Bool
    @State private var reason = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(KitColor.green)
                Text("Decline this payment")
                    .font(.title2.bold())
                Text("The money will return to the sender.")
                    .font(.subheadline)
                    .foregroundStyle(KitColor.secondaryText)
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
                .buttonStyle(KitPrimaryButtonStyle())
                .disabled(isSubmitting)
                Spacer()
            }
            .padding(22)
            .background(KitColor.canvas.ignoresSafeArea())
            .navigationTitle("Decline payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
