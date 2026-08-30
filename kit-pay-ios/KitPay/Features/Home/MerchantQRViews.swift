import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import SwiftUI
import UIKit

@MainActor
final class MerchantQRPaymentViewModel: ObservableObject {
    @Published private(set) var resolvedCode: MerchantQRCodeDTO?
    @Published private(set) var paidIntent: MerchantPaymentIntentDTO?
    @Published private(set) var isResolving = false
    @Published private(set) var isPaying = false
    @Published var errorMessage: String?

    private let api: APIClient
    private var payload: String?
    private var pendingPayment: (fingerprint: String, key: String)?

    init(api: APIClient = .shared) {
        self.api = api
    }

    func resolve(payload rawPayload: String, permitted: Bool, online: Bool) async -> Bool {
        guard !isResolving, !isPaying else { return false }
        guard permitted else {
            errorMessage = "QR payments are not enabled for this Kit Pay account."
            return false
        }
        guard online else {
            errorMessage = "Connect to the internet to verify this QR code."
            return false
        }
        let cleanPayload = rawPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPayload.isEmpty, cleanPayload.utf8.count <= 4_096 else {
            errorMessage = "Scan or paste a valid Kit merchant QR code."
            return false
        }

        isResolving = true
        errorMessage = nil
        defer { isResolving = false }
        do {
            let resolved = try await api.resolveMerchantQRCode(payload: cleanPayload)
            guard resolved.type == "merchant_qr",
                  resolved.isPayable,
                  ["static", "dynamic"].contains(resolved.kind.lowercased()),
                  !resolved.merchant.id.isEmpty
            else { throw MerchantQRFlowError.invalidResolution }
            if resolved.isDynamic {
                guard resolved.merchantPaymentIntentId?.isEmpty == false,
                      resolved.amount?.isEmpty == false,
                      resolved.currency != nil
                else { throw MerchantQRFlowError.invalidResolution }
            }
            payload = cleanPayload
            resolvedCode = resolved
            paidIntent = nil
            return true
        } catch {
            payload = nil
            resolvedCode = nil
            errorMessage = message(for: error)
            return false
        }
    }

    func pay(
        enteredAmount: String,
        pin: String,
        wallet: Wallet?,
        permitted: Bool,
        online: Bool,
        authorization: KitFinancialStepUpAuthorization
    ) async -> Bool {
        guard !isPaying else { return false }
        guard permitted, online else {
            errorMessage = permitted
                ? "Connect to the internet to pay this QR code."
                : "QR payments are not enabled for this Kit Pay account."
            return false
        }
        guard let code = resolvedCode, let payload, code.isPayable else {
            errorMessage = "Scan and verify a Kit merchant QR code first."
            return false
        }
        guard let wallet else {
            errorMessage = "Choose an active Kit Pay wallet."
            return false
        }
        let amount: String
        if code.isDynamic {
            guard let fixedAmount = code.amount,
                  let currency = code.currency,
                  currency == wallet.currency
            else {
                errorMessage = "Choose a \(code.currency?.code ?? "matching") wallet for this QR payment."
                return false
            }
            amount = fixedAmount
        } else {
            guard let parsed = MerchantQRMoney.apiAmount(
                enteredAmount,
                scale: wallet.currency.decimalScale
            ) else {
                errorMessage = "Enter an amount greater than zero."
                return false
            }
            amount = parsed
        }

        let payloadHash = SHA256.hash(data: Data(payload.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        let intent: [String: String?] = [
            "action": "qr_payment",
            "qr_code_id": code.id,
            "qr_payload_hash": payloadHash,
            "source_wallet_id": wallet.id,
            "amount": amount,
            "currency": wallet.currency.code,
        ]
        let fingerprint = [code.id, payloadHash, wallet.id, amount].joined(separator: ":")
        let idempotencyKey: String
        if pendingPayment?.fingerprint == fingerprint {
            idempotencyKey = pendingPayment!.key
        } else {
            idempotencyKey = "ios-merchant-qr-pay-\(UUID().uuidString.lowercased())"
            pendingPayment = (fingerprint, idempotencyKey)
        }

        isPaying = true
        errorMessage = nil
        defer { isPaying = false }
        do {
            let verification = try await authorization(
                "qr_payment",
                intent,
                pin,
                "Approve \(KitMoney.formatted(amount, currency: wallet.currency)) to \(code.merchant.displayName)"
            )
            guard !verification.stepUpToken.isEmpty else {
                throw MerchantQRFlowError.invalidStepUp
            }

            let paid = try await api.payMerchantQRCode(
                payload: payload,
                sourceWalletId: wallet.id,
                amount: amount,
                idempotencyKey: idempotencyKey,
                stepUpToken: verification.stepUpToken
            )
            guard paid.type == "merchant_payment_intent",
                  paid.status.caseInsensitiveCompare("captured") == .orderedSame,
                  paid.sourceWalletId == nil || paid.sourceWalletId == wallet.id,
                  paid.amount == amount,
                  paid.currency == wallet.currency,
                  paid.walletTransactionId?.isEmpty == false
            else { throw MerchantQRFlowError.unconfirmedPayment }
            paidIntent = paid
            pendingPayment = nil
            return true
        } catch {
            errorMessage = message(for: error)
            return false
        }
    }

    func reset() {
        payload = nil
        resolvedCode = nil
        paidIntent = nil
        errorMessage = nil
    }

    private func message(for error: Error) -> String {
        let message = (error as? APIErrorPayload)?.message ?? error.localizedDescription
        return CustomerFacingPaymentCopy.neutralizedServiceMessage(message)
    }
}

private enum MerchantQRFlowError: LocalizedError {
    case invalidResolution
    case invalidStepUp
    case unconfirmedPayment

    var errorDescription: String? {
        switch self {
        case .invalidResolution:
            "Kit could not verify this merchant QR code. Nothing was paid."
        case .invalidStepUp:
            "Kit could not bind approval to this exact QR payment. Nothing was paid."
        case .unconfirmedPayment:
            "Kit did not confirm this QR payment with a wallet transaction. Check activity before retrying."
        }
    }
}

struct MerchantQRPaymentView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = MerchantQRPaymentViewModel()
    @State private var manualPayload = ""
    @State private var amount = ""
    @State private var pin = ""
    @State private var scannerGeneration = UUID()
    @State private var cameraError: String?

    private var permitted: Bool { app.capabilities?.enablesMerchantQRPayments == true }

    var body: some View {
        NavigationStack {
            MoneyAccessBoundary {
                Group {
                    if let paid = model.paidIntent {
                        successView(paid)
                    } else {
                        ScrollView {
                            VStack(spacing: 18) {
                                if let code = model.resolvedCode {
                                    paymentForm(code)
                                } else {
                                    scanner
                                    manualEntry
                                }
                                if let error = model.errorMessage ?? cameraError {
                                    Text(error)
                                        .font(.footnote)
                                        .foregroundStyle(.red)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(14)
                                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                                }
                            }
                            .padding(20)
                            .padding(.bottom, 24)
                        }
                    }
                }
                .background(KitColor.canvas.ignoresSafeArea())
                .navigationTitle("Scan to pay")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { dismiss() }.disabled(model.isPaying)
                    }
                    if model.resolvedCode != nil, model.paidIntent == nil {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Scan again") {
                                model.reset()
                                pin = ""
                                amount = ""
                                scannerGeneration = UUID()
                            }
                            .disabled(model.isPaying)
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.isPaying)
    }

    private var scanner: some View {
        ZStack {
            MerchantQRScannerCamera(
                onCode: { payload in
                    Task { _ = await model.resolve(payload: payload, permitted: permitted, online: app.isOnline) }
                },
                onError: { cameraError = $0 }
            )
            .id(scannerGeneration)
            .frame(height: 330)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

            RoundedRectangle(cornerRadius: 22)
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [12, 8]))
                .frame(width: 230, height: 230)
                .allowsHitTesting(false)
            if model.isResolving {
                ProgressView("Verifying with Kit…")
                    .tint(.white)
                    .foregroundStyle(.white)
                    .padding(16)
                    .background(.black.opacity(0.62), in: Capsule())
            }
        }
        .overlay(alignment: .bottom) {
            Text("Align a signed Kit merchant QR inside the frame")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(.bottom, 16)
        }
    }

    private var manualEntry: some View {
        DisclosureGroup("Enter QR payload manually") {
            VStack(spacing: 12) {
                TextEditor(text: $manualPayload)
                    .frame(minHeight: 90)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task {
                        _ = await model.resolve(
                            payload: manualPayload,
                            permitted: permitted,
                            online: app.isOnline
                        )
                    }
                } label: {
                    Label("Verify QR", systemImage: "checkmark.shield.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KitSecondaryButtonStyle())
                .disabled(model.isResolving || manualPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 12)
        }
        .padding(18)
        .kitGlass(cornerRadius: 22)
    }

    private func paymentForm(_ code: MerchantQRCodeDTO) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(KitColor.green)
                Text(code.merchant.displayName)
                    .font(.title2.bold()).foregroundStyle(KitColor.primaryText)
                Text(code.isDynamic ? "Verified dynamic Kit QR" : "Verified Kit merchant QR")
                    .font(.subheadline).foregroundStyle(KitColor.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(22)
            .kitGlass(cornerRadius: 26, tint: KitColor.paleGreen)

            if code.isDynamic, let fixedAmount = code.amount, let currency = code.currency {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Amount").font(.caption).foregroundStyle(KitColor.secondaryText)
                    Text(KitMoney.formatted(fixedAmount, currency: currency))
                        .font(.largeTitle.bold()).foregroundStyle(KitColor.primaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18).kitGlass(cornerRadius: 20)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Amount").font(.headline).foregroundStyle(KitColor.primaryText)
                    HStack {
                        Text(app.selectedWallet?.currency.code ?? "UGX").bold().foregroundStyle(KitColor.green)
                        KitAmountTextField(
                            "0",
                            value: $amount,
                            mode: .decimal(
                                maximumFractionDigits:
                                    app.selectedWallet?.currency.decimalScale ?? 2
                            ),
                            textStyle: .monospacedTitle
                        )
                    }
                }
                .padding(18).kitGlass(cornerRadius: 20, tint: KitColor.paleGreen)
            }

            if app.financialApprovalUsesBiometrics {
                HStack(spacing: 12) {
                    Image(systemName: app.biometricSymbolName)
                        .font(.title2)
                        .foregroundStyle(KitColor.green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Approve with \(app.biometricDisplayName)")
                            .font(.headline).foregroundStyle(KitColor.primaryText)
                        Text("You will approve this exact merchant and amount when you tap Pay.")
                            .font(.caption).foregroundStyle(KitColor.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16).kitGlass(cornerRadius: 18)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Wallet PIN").font(.headline).foregroundStyle(KitColor.primaryText)
                    SecureField("Four digits", text: $pin)
                        .keyboardType(.numberPad)
                        .onChange(of: pin) { _, value in
                            pin = String(value.filter(\.isNumber).prefix(4))
                        }
                        .padding(16).kitGlass(cornerRadius: 18)
                }
            }

            Button {
                Task {
                    if await model.pay(
                        enteredAmount: amount,
                        pin: pin,
                        wallet: app.selectedWallet,
                        permitted: permitted,
                        online: app.isOnline,
                        authorization: { purpose, intent, pin, reason in
                            try await app.authorizeFinancialStepUp(
                                purpose: purpose,
                                intent: intent,
                                pin: pin,
                                reason: reason
                            )
                        }
                    ) { await app.refresh() }
                }
            } label: {
                if model.isPaying {
                    ProgressView().tint(.white).frame(maxWidth: .infinity)
                } else {
                    Label(
                        "Pay \(code.merchant.displayName)",
                        systemImage: app.financialApprovalUsesBiometrics
                            ? app.biometricSymbolName
                            : "qrcode"
                    )
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(KitPrimaryButtonStyle())
            .disabled(
                model.isPaying
                    || (!app.financialApprovalUsesBiometrics && pin.count != 4)
                    || (!code.isDynamic && MerchantQRMoney.apiAmount(
                        amount,
                        scale: app.selectedWallet?.currency.decimalScale ?? 2
                    ) == nil)
            )
        }
    }

    private func successView(_ paid: MerchantPaymentIntentDTO) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 92, height: 92)
                .background(KitColor.green.gradient, in: Circle())
            Text("Payment complete").font(.largeTitle.bold()).foregroundStyle(KitColor.primaryText)
            Text("\(KitMoney.formatted(paid.amount, currency: paid.currency)) paid to \(paid.merchant.displayName).")
                .multilineTextAlignment(.center).foregroundStyle(KitColor.secondaryText)
            if let transactionID = paid.walletTransactionId {
                Text("Transaction \(transactionID)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button("Done") { dismiss() }
                .frame(maxWidth: .infinity)
                .buttonStyle(KitPrimaryButtonStyle())
        }
        .padding(28)
    }
}

private struct MerchantQRScannerCamera: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> MerchantQRScannerViewController {
        MerchantQRScannerViewController(onCode: onCode, onError: onError)
    }

    func updateUIViewController(_ controller: MerchantQRScannerViewController, context: Context) {
        controller.onCode = onCode
        controller.onError = onError
    }

    static func dismantleUIViewController(_ controller: MerchantQRScannerViewController, coordinator: ()) {
        controller.stop()
    }
}

private final class MerchantQRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: (String) -> Void
    var onError: (String) -> Void

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var configured = false
    private var delivered = false

    init(onCode: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.onCode = onCode
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        authorizeAndStart()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
    }

    private func authorizeAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted { self.configureAndStart() }
                    else { self.onError("Camera access is required to scan QR codes. You can paste the payload manually instead.") }
                }
            }
        case .denied, .restricted:
            onError("Camera access is unavailable. Enable it in Settings or paste the QR payload manually.")
        @unknown default:
            onError("The camera is unavailable. Paste the QR payload manually.")
        }
    }

    private func configureAndStart() {
        do {
            if !configured {
                guard let camera = AVCaptureDevice.default(for: .video) else {
                    throw MerchantQRScannerError.cameraUnavailable
                }
                let input = try AVCaptureDeviceInput(device: camera)
                guard session.canAddInput(input) else { throw MerchantQRScannerError.cameraUnavailable }
                session.addInput(input)

                let output = AVCaptureMetadataOutput()
                guard session.canAddOutput(output) else { throw MerchantQRScannerError.cameraUnavailable }
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                guard output.availableMetadataObjectTypes.contains(.qr) else {
                    throw MerchantQRScannerError.qrUnavailable
                }
                output.metadataObjectTypes = [.qr]

                let preview = AVCaptureVideoPreviewLayer(session: session)
                preview.videoGravity = .resizeAspectFill
                preview.frame = view.bounds
                view.layer.insertSublayer(preview, at: 0)
                previewLayer = preview
                configured = true
            }
            delivered = false
            if !session.isRunning {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.session.startRunning() }
            }
        } catch {
            onError(error.localizedDescription)
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !delivered,
              let code = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
                .first(where: { $0.type == .qr })?.stringValue,
              !code.isEmpty
        else { return }
        delivered = true
        stop()
        onCode(code)
    }
}

private enum MerchantQRScannerError: LocalizedError {
    case cameraUnavailable
    case qrUnavailable

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable: "The camera could not be opened."
        case .qrUnavailable: "This camera cannot scan QR codes."
        }
    }
}

@MainActor
final class MerchantReceiveQRViewModel: ObservableObject {
    @Published private(set) var accounts: [MerchantAccountDTO] = []
    @Published private(set) var code: MerchantQRCodeDTO?
    @Published private(set) var isLoading = false
    @Published private(set) var isSubmitting = false
    @Published var errorMessage: String?

    private let api: APIClient
    private var pendingKey: (fingerprint: String, value: String)?

    init(api: APIClient = .shared) { self.api = api }

    func load(permitted: Bool, online: Bool) async {
        guard permitted, online, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            accounts = try await api.merchantAccounts().items ?? []
        } catch {
            errorMessage = message(for: error)
        }
    }

    func createMerchant(
        wallet: Wallet?,
        displayName: String,
        countryCode: String,
        permitted: Bool,
        online: Bool
    ) async -> Bool {
        guard permitted, online, !isSubmitting else { return false }
        guard let wallet,
              MerchantAccountOnboardingPolicy.isEligibleBusinessWallet(wallet)
        else {
            errorMessage = "An active Kit Pay business wallet is required for merchant setup."
            return false
        }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let country = countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !name.isEmpty, name.count <= 120,
              country.range(of: #"^[A-Z]{2}$"#, options: .regularExpression) != nil
        else {
            errorMessage = "Enter a valid merchant name and two-letter country code."
            return false
        }

        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let created = try await api.createMerchantAccount(
                settlementWalletId: wallet.id,
                displayName: name,
                legalName: nil,
                countryCode: country,
                idempotencyKey: key(for: "merchant:\(wallet.id):\(name):\(country)", prefix: "ios-merchant-create")
            )
            guard created.settlementWalletId == wallet.id,
                  created.status.caseInsensitiveCompare("active") == .orderedSame
            else { throw MerchantReceiveQRFlowError.unconfirmedMerchant }
            accounts = try await api.merchantAccounts().items ?? [created]
            pendingKey = nil
            return true
        } catch {
            errorMessage = message(for: error)
            return false
        }
    }

    func issue(
        merchant: MerchantAccountDTO,
        enteredAmount: String,
        note: String,
        wallet: Wallet?,
        permitted: Bool,
        online: Bool
    ) async -> Bool {
        guard permitted, online, !isSubmitting else { return false }
        guard let wallet, merchant.settlementWalletId == wallet.id else {
            errorMessage = "Choose the business wallet linked to this merchant account."
            return false
        }
        let cleanAmount = enteredAmount.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDynamic = !cleanAmount.isEmpty
        let amount = isDynamic
            ? MerchantQRMoney.apiAmount(cleanAmount, scale: wallet.currency.decimalScale)
            : nil
        guard !isDynamic || amount != nil else {
            errorMessage = "Enter a valid amount or leave it blank for a reusable QR."
            return false
        }

        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let intent: MerchantPaymentIntentDTO?
            if let amount {
                intent = try await api.createMerchantPaymentIntent(
                    merchantAccountId: merchant.id,
                    amount: amount,
                    note: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note,
                    idempotencyKey: key(
                        for: "intent:\(merchant.id):\(amount):\(note)",
                        prefix: "ios-merchant-intent"
                    )
                )
                guard intent?.amount == amount, intent?.currency == wallet.currency else {
                    throw MerchantReceiveQRFlowError.unconfirmedIntent
                }
            } else {
                intent = nil
            }
            let issued = try await api.createMerchantQRCode(
                merchantAccountId: merchant.id,
                kind: isDynamic ? "dynamic" : "static",
                merchantPaymentIntentId: intent?.id,
                idempotencyKey: key(
                    for: "qr:\(merchant.id):\(intent?.id ?? "static")",
                    prefix: "ios-merchant-qr"
                )
            )
            guard issued.type == "merchant_qr",
                  issued.payload?.isEmpty == false,
                  issued.merchant.id == merchant.id,
                  issued.isPayable,
                  issued.isDynamic == isDynamic
            else { throw MerchantReceiveQRFlowError.unconfirmedQR }
            code = issued
            pendingKey = nil
            return true
        } catch {
            errorMessage = message(for: error)
            return false
        }
    }

    func resetCode() { code = nil; errorMessage = nil }

    func prepareForSettlementWalletChange() {
        code = nil
        errorMessage = nil
        pendingKey = nil
    }

    private func key(for fingerprint: String, prefix: String) -> String {
        if pendingKey?.fingerprint == fingerprint { return pendingKey!.value }
        let value = "\(prefix)-\(UUID().uuidString.lowercased())"
        pendingKey = (fingerprint, value)
        return value
    }

    private func message(for error: Error) -> String {
        let message = (error as? APIErrorPayload)?.message ?? error.localizedDescription
        return CustomerFacingPaymentCopy.neutralizedServiceMessage(message)
    }
}

private enum MerchantReceiveQRFlowError: LocalizedError {
    case unconfirmedMerchant
    case unconfirmedIntent
    case unconfirmedQR

    var errorDescription: String? {
        switch self {
        case .unconfirmedMerchant: "Kit did not confirm the merchant account."
        case .unconfirmedIntent: "Kit did not confirm the exact QR amount."
        case .unconfirmedQR: "Kit did not return a signed payable QR code."
        }
    }
}

struct MerchantReceiveQRView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = MerchantReceiveQRViewModel()
    @State private var businessWalletID = ""
    @State private var merchantID = ""
    @State private var amount = ""
    @State private var note = ""
    @State private var merchantName = ""
    @State private var countryCode = "UG"

    private var permitted: Bool { app.capabilities?.enablesMerchantQRPayments == true }
    private var businessWallets: [Wallet] {
        MerchantAccountOnboardingPolicy.businessWallets(in: app.state.wallets)
    }
    private var selectedBusinessWallet: Wallet? {
        MerchantAccountOnboardingPolicy.selectedBusinessWallet(
            id: businessWalletID,
            from: app.state.wallets
        )
    }
    private var linkedAccounts: [MerchantAccountDTO] {
        MerchantAccountOnboardingPolicy.merchantAccounts(
            model.accounts,
            linkedTo: selectedBusinessWallet
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if let code = model.code, let payload = code.payload {
                    qrDisplay(code: code, payload: payload)
                } else {
                    Form {
                        settlementWalletSetup
                        if selectedBusinessWallet != nil {
                            if model.isLoading {
                                Section {
                                    HStack(spacing: 12) {
                                        ProgressView()
                                        Text("Checking merchant accounts…")
                                    }
                                }
                            } else if linkedAccounts.isEmpty {
                                merchantSetup
                            } else {
                                qrSetup
                            }
                        }
                        if let error = model.errorMessage {
                            Section { Text(error).font(.footnote).foregroundStyle(.red) }
                        }
                    }
                }
            }
            .navigationTitle("Receive by QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() }.disabled(model.isSubmitting) }
                if model.code != nil {
                    ToolbarItem(placement: .topBarTrailing) { Button("New") { model.resetCode() } }
                }
            }
            .task {
                merchantName = app.profile?.name ?? ""
                countryCode = app.profile?.countryCode?.uppercased() ?? "UG"
                reconcileBusinessWalletSelection()
                await model.load(permitted: permitted, online: app.isOnline)
                reconcileMerchantSelection()
            }
            .onChange(of: businessWalletID) { _, _ in
                model.prepareForSettlementWalletChange()
                reconcileMerchantSelection()
            }
        }
        .interactiveDismissDisabled(model.isSubmitting)
    }

    private var settlementWalletSetup: some View {
        Section("Settlement wallet") {
            if businessWallets.isEmpty {
                Label("Business wallet required", systemImage: "building.2.crop.circle")
                    .font(.headline)
                Text(
                    "Create an active Kit Pay business wallet first. You can create a merchant "
                        + "account only after that wallet is available for selection."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
                Picker("Business wallet", selection: $businessWalletID) {
                    Text("Select a business wallet").tag("")
                    ForEach(businessWallets) { wallet in
                        Text(businessWalletLabel(wallet)).tag(wallet.id)
                    }
                }
                Text(
                    "Choose the Kit Pay business wallet that will receive merchant settlements."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            MerchantAccountHelpLinks()
        }
    }

    private var merchantSetup: some View {
        Section {
            ContentUnavailableView(
                "Merchant setup required",
                systemImage: "storefront",
                description: Text(
                    "Your business wallet is ready. Create the merchant account linked to it "
                        + "before issuing signed payment QR codes."
                )
            )
            TextField("Merchant display name", text: $merchantName)
            TextField("Country code", text: $countryCode)
                .textInputAutocapitalization(.characters)
            Button {
                Task {
                    if await model.createMerchant(
                        wallet: selectedBusinessWallet,
                        displayName: merchantName,
                        countryCode: countryCode,
                        permitted: permitted,
                        online: app.isOnline
                    ) { reconcileMerchantSelection() }
                }
            } label: {
                if model.isSubmitting { ProgressView().frame(maxWidth: .infinity) }
                else { Text("Create merchant account").frame(maxWidth: .infinity) }
            }
            .disabled(
                model.isLoading
                    || model.isSubmitting
                    || selectedBusinessWallet == nil
                    || !permitted
                    || !app.isOnline
                    || merchantName.trimmingCharacters(in: .whitespaces).isEmpty
            )
        }
    }

    private var qrSetup: some View {
        Group {
            Section("Merchant") {
                Picker("Merchant", selection: $merchantID) {
                    ForEach(linkedAccounts) { Text($0.displayName).tag($0.id) }
                }
            }
            Section("Payment") {
                KitAmountTextField(
                    "Amount (optional)",
                    value: $amount,
                    mode: .decimal(
                        maximumFractionDigits:
                            selectedBusinessWallet?.currency.decimalScale ?? 2
                    ),
                    textStyle: .monospacedBody
                )
                Text(amount.isEmpty
                     ? "Leave blank for a reusable QR where the payer enters the amount."
                     : "A one-time dynamic QR will be bound to this amount.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Note (optional)", text: $note)
            }
            Section {
                Button {
                    guard let merchant = linkedAccounts.first(where: { $0.id == merchantID }) else { return }
                    Task {
                        _ = await model.issue(
                            merchant: merchant,
                            enteredAmount: amount,
                            note: note,
                            wallet: selectedBusinessWallet,
                            permitted: permitted,
                            online: app.isOnline
                        )
                    }
                } label: {
                    if model.isSubmitting { ProgressView().frame(maxWidth: .infinity) }
                    else { Text("Create signed QR").frame(maxWidth: .infinity) }
                }
                .disabled(
                    model.isSubmitting
                        || merchantID.isEmpty
                        || selectedBusinessWallet == nil
                        || !permitted
                        || !app.isOnline
                )
            }
        }
    }

    private func reconcileBusinessWalletSelection() {
        if selectedBusinessWallet == nil {
            businessWalletID = MerchantAccountOnboardingPolicy.initialBusinessWalletID(
                in: app.state.wallets,
                preferredWalletID: app.selectedWallet?.id
            )
        }
        reconcileMerchantSelection()
    }

    private func reconcileMerchantSelection() {
        guard linkedAccounts.contains(where: { $0.id == merchantID }) else {
            merchantID = linkedAccounts.first?.id ?? ""
            return
        }
    }

    private func businessWalletLabel(_ wallet: Wallet) -> String {
        let accountNumber = wallet.accountNumber?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let accountNumber, !accountNumber.isEmpty {
            return "\(wallet.name) · \(accountNumber)"
        }
        return "\(wallet.name) · \(wallet.currency.code)"
    }

    private func qrDisplay(code: MerchantQRCodeDTO, payload: String) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                if let image = MerchantQRCodeImage.make(payload: payload) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 290)
                        .padding(22)
                        .background(.white, in: RoundedRectangle(cornerRadius: 28))
                        .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
                        .accessibilityLabel("Signed Kit merchant QR code")
                }
                Text(code.merchant.displayName).font(.title2.bold()).foregroundStyle(KitColor.primaryText)
                if let amount = code.amount, let currency = code.currency {
                    Text(KitMoney.formatted(amount, currency: currency)).font(.largeTitle.bold()).foregroundStyle(KitColor.green)
                } else {
                    Text("Reusable merchant QR").foregroundStyle(KitColor.secondaryText)
                }
                Text("Expires \(code.expiresAt)")
                    .font(.caption).foregroundStyle(KitColor.secondaryText)
                ShareLink(item: payload) {
                    Label("Share QR payload", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KitSecondaryButtonStyle())
            }
            .padding(24)
        }
        .background(KitColor.canvas.ignoresSafeArea())
    }
}

private enum MerchantQRCodeImage {
    static func make(payload: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let image = CIContext(options: nil).createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: image)
    }
}
