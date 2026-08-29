import SwiftUI
import UIKit

/// The authenticated "Invite friends" screen. Reached only through Settings, and only while the
/// server advertises the exact `referrals` capability — the entry row and this surface are both
/// dark otherwise.
///
/// Every number and rule shown here — reward amount, qualifying balance, business days, window
/// length, per-referral statuses, totals — is a VERBATIM rendering of the server's referral
/// payload. The client never computes qualification, deadlines, or payouts, never promises terms
/// the active policy version didn't send (no program payload ⇒ no share actions), and renders
/// only the coarse public statuses the contract pins.
struct ReferralView: View {
    @EnvironmentObject private var model: AppModel

    /// Session + account this screen was opened under; captured once, checked before every state
    /// write, so a stale response can never paint another account's referrals here.
    @State private var flow: SupportFlowBinding?
    @State private var overview: ReferralOverviewDTO?
    /// The code minted by an explicit "Get my invite link" tap, used until the next overview
    /// fetch returns it authoritatively.
    @State private var mintedCode: ReferralShareCodeDTO?
    @State private var isLoading = false
    @State private var isMintingCode = false
    @State private var errorMessage: String?
    @State private var copiedLink = false

    private var gate: ReferralGateState { ReferralGate.state(for: model.capabilities) }

    private var shareCode: ReferralShareCodeDTO? { overview?.code ?? mintedCode }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if !gate.isAvailable {
                    unavailableNotice
                } else {
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let overview {
                        if let program = overview.program {
                            programCard(program)
                            shareCard
                        } else {
                            pausedNotice
                        }
                        historyCard(overview)
                    } else if isLoading {
                        ProgressView()
                            .padding(.vertical, 48)
                    } else if errorMessage != nil {
                        Button {
                            Task { await load() }
                        } label: {
                            Text("Try again")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(KitPrimaryButtonStyle())
                    }
                }
            }
            .padding(18)
        }
        .background(KitColor.canvas.ignoresSafeArea())
        .navigationTitle("Invite friends")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Sections

    private var unavailableNotice: some View {
        Label(
            "Inviting friends isn't available right now. Check back soon.",
            systemImage: "gift"
        )
        .font(.subheadline)
        .foregroundStyle(KitColor.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .kitGlass(cornerRadius: 22)
    }

    /// Shown when the capability is advertised but the payload carries no active policy terms:
    /// with no terms there is nothing to promise, so sharing is withheld rather than implied.
    private var pausedNotice: some View {
        Label(
            "The referral program is paused right now. Your past invites are still shown below.",
            systemImage: "pause.circle"
        )
        .font(.subheadline)
        .foregroundStyle(KitColor.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .kitGlass(cornerRadius: 22)
    }

    /// The program terms, templated ENTIRELY from the active policy payload.
    private func programCard(_ program: ReferralProgramTermsDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Earn \(money(program.reward)) per friend")
                    .font(.headline)
                    .foregroundStyle(KitColor.primaryText)
            } icon: {
                Image(systemName: "gift.fill")
                    .foregroundStyle(KitColor.green)
            }
            Text(
                "Your friend joins Kit Pay with your link, then holds at least "
                    + "\(money(program.qualifyingBalance)) in Kit Pay for "
                    + "\(dayCount(program.qualifyingBusinessDays, unit: "full business day")) "
                    + "within \(dayCount(program.windowDays, unit: "day")) of joining."
            )
            .font(.subheadline)
            .foregroundStyle(KitColor.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            Text(
                "Kit Pay checks and pays rewards itself — this screen only shows what the "
                    + "program has decided."
            )
            .font(.caption)
            .foregroundStyle(KitColor.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .kitGlass(cornerRadius: 22)
    }

    @ViewBuilder
    private var shareCard: some View {
        VStack(spacing: 12) {
            if let shareCode {
                Text("Your invite code")
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
                Text(shareCode.code)
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .foregroundStyle(KitColor.primaryText)
                    .textSelection(.enabled)
                ShareLink(item: shareCode.shareURL) {
                    Label("Share invite link", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KitPrimaryButtonStyle())
                Button {
                    UIPasteboard.general.string = shareCode.shareURL.absoluteString
                    copiedLink = true
                } label: {
                    Label(
                        copiedLink ? "Link copied" : "Copy link",
                        systemImage: copiedLink ? "checkmark" : "doc.on.doc"
                    )
                    .font(.footnote.weight(.semibold))
                }
            } else {
                Text(
                    "Get your unique invite link to share with friends. You only ever share "
                        + "the link — never your wallet or PIN."
                )
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await mintCode() }
                } label: {
                    if isMintingCode {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Get my invite link", systemImage: "link.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(KitPrimaryButtonStyle())
                .disabled(isMintingCode || !model.appReviewDemoMutationsAllowed)
            }
        }
        .padding(16)
        .kitGlass(cornerRadius: 22)
    }

    private func historyCard(_ overview: ReferralOverviewDTO) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your invites")
                    .font(.headline)
                    .foregroundStyle(KitColor.primaryText)
                Spacer()
                if overview.totals.total > 0 {
                    Text("\(overview.totals.total) invited · \(overview.totals.paid) paid")
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                }
            }
            if overview.referrals.isEmpty {
                Text(
                    shareCode == nil
                        ? "No invites yet."
                        : "No invites yet. Share your link to get started."
                )
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)
            } else {
                ForEach(overview.referrals) { item in
                    referralRow(item)
                    if item.id != overview.referrals.last?.id {
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .kitGlass(cornerRadius: 22)
    }

    private func referralRow(_ item: ReferralListItemDTO) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.referredName ?? "Someone you invited")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KitColor.primaryText)
                    .lineLimit(1)
                if let joined = SupportRelativeTime.text(from: item.attributedAt) {
                    Text("Joined \(joined)")
                        .font(.caption2)
                        .foregroundStyle(KitColor.secondaryText)
                }
                if let paidAt = item.paidAt, let paid = SupportRelativeTime.text(from: paidAt) {
                    Text("Paid \(paid)")
                        .font(.caption2)
                        .foregroundStyle(KitColor.secondaryText)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(statusLabel(item.status))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(statusColor(item.status).opacity(0.14), in: Capsule())
                    .foregroundStyle(statusColor(item.status))
                Text(money(item.reward))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KitColor.secondaryText)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Presentation of the closed status set

    private func statusLabel(_ status: String) -> String {
        switch status {
        case ReferralContract.statusPending: "Pending"
        case ReferralContract.statusQualified: "Qualified"
        case ReferralContract.statusPaid: "Paid"
        case ReferralContract.statusExpired: "Expired"
        case ReferralContract.statusNotEligible: "Not eligible"
        case ReferralContract.statusReversed: "Reversed"
        // Unreachable while the decoder enforces the closed set; render the server's own
        // token rather than guessing a friendlier meaning.
        default: status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case ReferralContract.statusPaid: KitColor.green
        case ReferralContract.statusQualified: KitColor.verifiedBlue
        case ReferralContract.statusPending: .orange
        case ReferralContract.statusReversed: .red
        default: KitColor.secondaryText
        }
    }

    private func money(_ value: ReferralMoneyDTO) -> String {
        KitMoney.formatted(value.amount, code: value.currencyCode, scale: value.currencyScale)
    }

    private func dayCount(_ count: Int, unit: String) -> String {
        count == 1 ? "1 \(unit)" : "\(count) \(unit)s"
    }

    // MARK: - Loading

    private func ensureFlow() async throws -> SupportFlowBinding {
        if let flow {
            guard await SupportSessionScope.isCurrent(flow) else {
                throw APIClientError.signedOut
            }
            return flow
        }
        let captured = try await SupportSessionScope.captureFlow()
        flow = captured
        return captured
    }

    @MainActor
    private func load() async {
        guard gate.isAvailable, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let flow = try await ensureFlow()
            let fresh = try await APIClientSessionBinding.$sessionID.withValue(flow.sessionID) {
                try await APIClient.shared.referralOverview()
            }
            guard await SupportSessionScope.isCurrent(flow) else { return }
            overview = fresh
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = describe(error)
        }
    }

    @MainActor
    private func mintCode() async {
        guard gate.isAvailable, !isMintingCode, model.appReviewDemoMutationsAllowed
        else { return }
        isMintingCode = true
        defer { isMintingCode = false }
        do {
            let flow = try await ensureFlow()
            let code = try await APIClientSessionBinding.$sessionID.withValue(flow.sessionID) {
                try await APIClient.shared.ensureReferralCode()
            }
            guard await SupportSessionScope.isCurrent(flow) else { return }
            mintedCode = code
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = describe(error)
        }
    }

    private func describe(_ error: Error) -> String {
        if let payload = error as? APIErrorPayload {
            return payload.message
        }
        if let client = error as? APIClientError, let text = client.errorDescription {
            return text
        }
        if error is DecodingError {
            return "Kit Pay sent something this app version can't read safely. "
                + "Pull to refresh or try again later."
        }
        if let contract = error as? ReferralContractError, let text = contract.errorDescription {
            return text
        }
        return "Something went wrong. Please try again."
    }
}
