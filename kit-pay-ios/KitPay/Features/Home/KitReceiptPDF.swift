import SwiftUI
import UIKit

// MARK: - Receipt content

/// Everything the renderer needs; built from a `WalletTransaction` so future transaction-like
/// screens can construct it from their own models.
struct KitReceiptContent {
    enum Disposition {
        case successful
        case pending
        case failed
        case reversed
    }

    let disposition: Disposition
    /// PDF metadata title and visible uppercase heading.
    let documentTitle: String
    let documentKicker: String
    /// "Payment Successful" / "Payment Pending" / "Payment Failed" / "Payment Reversed".
    let statusLabel: String
    /// "UGX 150,000" — grouped, unsigned.
    let headlineAmount: String
    /// "Sent to ABC Company" / "Received from ABC Company".
    let directionLine: String
    /// Reference, Date, Type, Status, From/To, Note, Wallet — only non-empty values.
    let rows: [(label: String, value: String)]
    /// "Sent UGX 150,000 to ABC. Receipt attached." — direction and status aware.
    let shareMessage: String
    /// "Kit-Receipt-<reference>.pdf", sanitized for the filesystem.
    let fileName: String
    /// Product-specific verification language shown in the footer.
    let footerNote: String

    static func from(transaction: WalletTransaction, senderName: String?) -> KitReceiptContent {
        // Mirrors TransactionDetailView.statusColor exactly: anything not explicitly terminal
        // is treated as pending. A non-successful payment must never read as successful.
        let disposition: Disposition
        switch transaction.status.lowercased() {
        case "completed", "successful", "success":
            disposition = .successful
        case "failed":
            disposition = .failed
        case "reversed":
            disposition = .reversed
        default:
            disposition = .pending
        }

        let statusLabel: String
        switch disposition {
        case .successful: statusLabel = "Payment Successful"
        case .pending: statusLabel = "Payment Pending"
        case .failed: statusLabel = "Payment Failed"
        case .reversed: statusLabel = "Payment Reversed"
        }

        let headlineAmount = KitMoney.formatted(transaction.amount, currency: transaction.currency)

        let typeLabel = transaction.type.replacingOccurrences(of: "_", with: " ").capitalized
        let counterpartyName = trimmedNonEmpty(transaction.counterparty?.name) ?? "Kit Pay user"

        let directionLine: String
        switch transaction.direction {
        case "debit":
            directionLine = "Sent to \(counterpartyName)"
        case "credit":
            directionLine = "Received from \(counterpartyName)"
        default:
            directionLine = trimmedNonEmpty(transaction.counterparty?.name) ?? typeLabel
        }

        var rows: [(label: String, value: String)] = []
        func appendRow(_ label: String, _ value: String?) {
            guard let value = trimmedNonEmpty(value) else { return }
            rows.append((label: label, value: value))
        }
        appendRow("Reference", transaction.reference)
        appendRow("Date", displayDate(from: transaction.occurredAt))
        appendRow("Type", typeLabel)
        appendRow("Status", transaction.status.capitalized)
        switch transaction.direction {
        case "debit":
            appendRow("From", trimmedNonEmpty(senderName))
            appendRow("To", counterpartyName)
        case "credit":
            appendRow("From", counterpartyName)
            appendRow("To", trimmedNonEmpty(senderName))
        default:
            appendRow("Counterparty", transaction.counterparty?.name)
        }
        appendRow("Note", transaction.note)
        appendRow("Wallet", transaction.walletId)

        // "to" for debits (and unknown directions), "from" for credits.
        let preposition = transaction.direction == "credit" ? "from" : "to"
        let shareMessage: String
        switch disposition {
        case .successful:
            shareMessage = transaction.direction == "credit"
                ? "Received \(headlineAmount) from \(counterpartyName). Receipt attached."
                : "Sent \(headlineAmount) to \(counterpartyName). Receipt attached."
        case .pending:
            shareMessage = "Payment of \(headlineAmount) \(preposition) \(counterpartyName) is pending. Receipt attached."
        case .failed:
            shareMessage = "Payment of \(headlineAmount) \(preposition) \(counterpartyName) failed. Receipt attached."
        case .reversed:
            shareMessage = "Payment of \(headlineAmount) \(preposition) \(counterpartyName) was reversed. Receipt attached."
        }

        let safeReference = sanitizedFileComponent(transaction.reference)
        let fileName = safeReference.isEmpty ? "Kit-Receipt.pdf" : "Kit-Receipt-\(safeReference).pdf"

        return KitReceiptContent(
            disposition: disposition,
            documentTitle: "Kit Pay receipt",
            documentKicker: "PROOF OF PAYMENT",
            statusLabel: statusLabel,
            headlineAmount: headlineAmount,
            directionLine: directionLine,
            rows: rows,
            shareMessage: shareMessage,
            fileName: fileName,
            footerNote: "This receipt was generated from the sender's Kit Pay transaction record."
        )
    }

    static func bankDepositInstructions(
        from deposit: BankDepositRequestDTO,
        walletName: String?
    ) -> KitReceiptContent {
        let disposition: Disposition
        let statusLabel: String
        switch deposit.status.lowercased() {
        case "approved", "completed":
            disposition = .successful
            statusLabel = "Wallet Credited"
        case "rejected", "cancelled", "canceled":
            disposition = .failed
            statusLabel = "Deposit Not Approved"
        case "expired":
            disposition = .reversed
            statusLabel = "Deposit Expired"
        case "proof_submitted":
            disposition = .pending
            statusLabel = "Receipt Submitted"
        case "awaiting_approval":
            disposition = .pending
            statusLabel = "Under Review"
        default:
            disposition = .pending
            statusLabel = "Awaiting Receipt"
        }

        var rows = BankDepositInstructions.receivingFields(for: deposit)
            .map { (label: $0.label, value: $0.value) }
        func appendRow(_ label: String, _ rawValue: String?) {
            guard let value = trimmedNonEmpty(rawValue) else { return }
            rows.append((label: label, value: value))
        }
        appendRow("Kit Pay wallet", walletName)
        appendRow("Status", statusLabel)
        appendRow("Created", displayDate(from: deposit.createdAt ?? ""))
        appendRow("Expires", displayDate(from: deposit.expiresAt))
        appendRow("Your note", deposit.customerNote)
        appendRow("Bank instructions", deposit.fundingAccount.instructions)

        let amount = KitMoney.formatted(
            deposit.amount,
            currency: deposit.currency,
            trimZeroFraction: true
        )
        let reference = deposit.reference
        let isInstruction = !deposit.isTerminal
        return KitReceiptContent(
            disposition: disposition,
            documentTitle: isInstruction
                ? "Kit Pay bank deposit instructions"
                : "Kit Pay bank deposit record",
            documentKicker: isInstruction ? "BANK DEPOSIT INSTRUCTIONS" : "BANK DEPOSIT RECORD",
            statusLabel: statusLabel,
            headlineAmount: amount,
            directionLine: "Transfer to \(deposit.fundingAccount.bank.name)",
            rows: rows,
            shareMessage: isInstruction
                ? "Bank deposit instructions for \(amount), reference \(reference). PDF attached."
                : "Bank deposit record for \(amount), reference \(reference). PDF attached.",
            fileName: "Kit-Bank-Deposit-\(sanitizedFileComponent(reference)).pdf",
            footerNote: "Use the exact amount and reference. Wallet credit follows verification."
        )
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func displayDate(from occurredAt: String) -> String {
        guard let date = KitReceiptDateParser.date(from: occurredAt) else { return occurredAt }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func sanitizedFileComponent(_ raw: String) -> String {
        let sanitized = raw.map { character -> Character in
            if character.isASCII, character.isLetter || character.isNumber { return character }
            if character == "-" || character == "_" { return character }
            return "-"
        }
        return String(String(sanitized).prefix(64))
    }
}

/// The backend emits both plain and fractional-second ISO 8601 timestamps; the shared
/// `KitServerDateParser` is file-private to `WalletFlowViews`, so the same dual-formatter
/// approach is re-implemented here with cached formatters.
private enum KitReceiptDateParser {
    private static let plain = ISO8601DateFormatter()
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func date(from value: String) -> Date? {
        plain.date(from: value) ?? fractional.date(from: value)
    }
}

// MARK: - PDF renderer

enum KitReceiptPDFRenderer {
    /// Renders a single-page (auto-paginating if rows overflow) A4 PDF and writes it to a
    /// protected temporary file. Each call yields a fresh file; the caller shares it directly.
    static func render(_ content: KitReceiptContent) throws -> URL {
        let data = pdfData(for: content)

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("kit-receipts", isDirectory: true)
        // Single-user temp hygiene: previous receipts must not accumulate where another
        // transaction's PDF could be picked up or linger on disk.
        try? fileManager.removeItem(at: root)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(content.fileName)
        try data.write(to: url, options: [.completeFileProtection])
        return url
    }

    // MARK: Palette — fixed print colors, never dynamic system colors.

    private enum Palette {
        static let navy = UIColor(red: 18 / 255, green: 45 / 255, blue: 70 / 255, alpha: 1)
        static let deepNavy = UIColor(red: 8 / 255, green: 33 / 255, blue: 52 / 255, alpha: 1)
        static let green = UIColor(red: 52 / 255, green: 185 / 255, blue: 139 / 255, alpha: 1)
        static let amber = UIColor(red: 232 / 255, green: 161 / 255, blue: 58 / 255, alpha: 1)
        static let red = UIColor(red: 214 / 255, green: 69 / 255, blue: 69 / 255, alpha: 1)
        static let bodyGray = UIColor(white: 0.40, alpha: 1)
        static let labelGray = UIColor(white: 0.45, alpha: 1)
        static let footerGray = UIColor(white: 0.52, alpha: 1)
        static let hairline = UIColor(white: 0.86, alpha: 1)
        static let cardStroke = UIColor(white: 0.88, alpha: 1)
        static let cardFill = UIColor(white: 0.97, alpha: 1)
    }

    private enum Metrics {
        static let pageSize = CGSize(width: 595, height: 842) // A4 in points
        static let margin: CGFloat = 48
        static var contentWidth: CGFloat { pageSize.width - margin * 2 }
        static let cardPadding: CGFloat = 18
        static let cardCornerRadius: CGFloat = 12
        static let labelColumnWidth: CGFloat = 150
        static let columnGap: CGFloat = 16
        static let rowVerticalPadding: CGFloat = 10
        static let headerRuleY: CGFloat = 106
        /// Lowest y a card's bottom edge may reach before the footer zone.
        static let rowAreaBottom: CGFloat = 748
        static let continuationCardTop: CGFloat = 96
        static let footerY: CGFloat = 766
    }

    private struct RowMetrics {
        let label: NSAttributedString
        let value: NSAttributedString
        /// Full row height including vertical padding; values wrap, so this is measured.
        let height: CGFloat
    }

    private static func pdfData(for content: KitReceiptContent) -> Data {
        let valueWidth = Metrics.contentWidth
            - Metrics.cardPadding * 2
            - Metrics.labelColumnWidth
            - Metrics.columnGap

        // Measure every row up-front: long names and international text wrap to as many
        // lines as they need — never truncated.
        let rowMetrics: [RowMetrics] = content.rows.map { row in
            let label = attributed(
                row.label.uppercased(),
                font: .systemFont(ofSize: 10, weight: .semibold),
                color: Palette.labelGray,
                kern: 1
            )
            let value = attributed(
                row.value,
                font: .systemFont(ofSize: 12, weight: .regular),
                color: Palette.navy,
                alignment: .right
            )
            let labelHeight = measuredHeight(of: label, width: Metrics.labelColumnWidth)
            let valueHeight = measuredHeight(of: value, width: valueWidth)
            return RowMetrics(
                label: label,
                value: value,
                height: max(labelHeight, valueHeight) + Metrics.rowVerticalPadding * 2
            )
        }

        // Hero measurements (page 1 only).
        let pillColor: UIColor
        switch content.disposition {
        case .successful: pillColor = Palette.green
        case .pending: pillColor = Palette.amber
        case .failed, .reversed: pillColor = Palette.red
        }
        let pillText = attributed(
            content.statusLabel,
            font: .systemFont(ofSize: 11, weight: .bold),
            color: .white,
            kern: 0.5,
            alignment: .center
        )
        let pillTextSize = pillText.size()
        let pillSize = CGSize(
            width: ceil(pillTextSize.width) + 32,
            height: ceil(pillTextSize.height) + 12
        )
        let headline = attributed(
            content.headlineAmount,
            font: .monospacedDigitSystemFont(ofSize: 34, weight: .bold),
            color: Palette.navy,
            alignment: .center
        )
        let headlineHeight = measuredHeight(of: headline, width: Metrics.contentWidth)
        let direction = attributed(
            content.directionLine,
            font: .systemFont(ofSize: 15, weight: .medium),
            color: Palette.bodyGray,
            alignment: .center
        )
        let directionHeight = measuredHeight(of: direction, width: Metrics.contentWidth)

        let pillY = Metrics.headerRuleY + 34
        let headlineY = pillY + pillSize.height + 18
        let directionY = headlineY + headlineHeight + 10
        let firstCardTop = directionY + directionHeight + 32

        // Paginate: measuring pass so every page can carry "x of N".
        var pages: [[RowMetrics]] = []
        var cardTops: [CGFloat] = []
        var currentRows: [RowMetrics] = []
        var cardTop = firstCardTop
        var y = cardTop + Metrics.cardPadding
        for metric in rowMetrics {
            let projectedCardBottom = y + metric.height + Metrics.cardPadding
            if projectedCardBottom > Metrics.rowAreaBottom, !currentRows.isEmpty {
                pages.append(currentRows)
                cardTops.append(cardTop)
                currentRows = []
                cardTop = Metrics.continuationCardTop
                y = cardTop + Metrics.cardPadding
            }
            currentRows.append(metric)
            y += metric.height
        }
        pages.append(currentRows)
        cardTops.append(cardTop)

        let reference = content.rows.first(where: {
            $0.label == "Reference" || $0.label == "Payment reference"
        })?.value ?? ""

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: content.documentTitle,
            kCGPDFContextCreator as String: "Kit Pay",
        ]
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: Metrics.pageSize),
            format: format
        )
        return renderer.pdfData { context in
            for (pageIndex, pageRows) in pages.enumerated() {
                context.beginPage()
                let cg = context.cgContext

                // Explicit white — print-friendly, never a dynamic surface color.
                cg.setFillColor(UIColor.white.cgColor)
                cg.fill(CGRect(origin: .zero, size: Metrics.pageSize))

                if pageIndex == 0 {
                    drawPrimaryHeader(kicker: content.documentKicker, in: cg)

                    // Hero block, centered.
                    let pillRect = CGRect(
                        x: (Metrics.pageSize.width - pillSize.width) / 2,
                        y: pillY,
                        width: pillSize.width,
                        height: pillSize.height
                    )
                    let pillPath = UIBezierPath(
                        roundedRect: pillRect,
                        cornerRadius: pillSize.height / 2
                    )
                    pillColor.setFill()
                    pillPath.fill()
                    pillText.draw(in: CGRect(
                        x: pillRect.minX,
                        y: pillRect.minY + (pillSize.height - ceil(pillTextSize.height)) / 2,
                        width: pillRect.width,
                        height: ceil(pillTextSize.height)
                    ))
                    headline.draw(in: CGRect(
                        x: Metrics.margin,
                        y: headlineY,
                        width: Metrics.contentWidth,
                        height: headlineHeight
                    ))
                    direction.draw(in: CGRect(
                        x: Metrics.margin,
                        y: directionY,
                        width: Metrics.contentWidth,
                        height: directionHeight
                    ))
                } else {
                    drawContinuationHeader(
                        documentTitle: content.documentTitle,
                        reference: reference,
                        in: cg
                    )
                }

                drawCard(
                    rows: pageRows,
                    top: cardTops[pageIndex],
                    valueWidth: valueWidth,
                    in: cg
                )
                drawFooter(
                    note: content.footerNote,
                    page: pageIndex + 1,
                    of: pages.count,
                    in: cg
                )
            }
        }
    }

    // MARK: Header / footer

    private static func drawPrimaryHeader(kicker: String, in cg: CGContext) {
        let logoWidth: CGFloat = 120
        let logoHeight = logoWidth
            * (KitLogoGeometry.fullViewBox.height / KitLogoGeometry.fullViewBox.width)
        drawFullLogo(
            in: CGRect(x: Metrics.margin, y: 48, width: logoWidth, height: logoHeight),
            context: cg
        )

        let rightX = Metrics.margin + logoWidth + 24
        let rightWidth = Metrics.pageSize.width - Metrics.margin - rightX
        let proof = attributed(
            kicker,
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: Palette.navy,
            kern: 2,
            alignment: .right
        )
        proof.draw(in: CGRect(x: rightX, y: 52, width: rightWidth, height: 16))
        let stamp = attributed(
            "Generated \(Date().formatted(date: .abbreviated, time: .shortened))",
            font: .systemFont(ofSize: 9, weight: .regular),
            color: Palette.labelGray,
            alignment: .right
        )
        stamp.draw(in: CGRect(x: rightX, y: 71, width: rightWidth, height: 12))

        cg.setFillColor(Palette.green.cgColor)
        cg.fill(CGRect(
            x: Metrics.margin,
            y: Metrics.headerRuleY,
            width: Metrics.contentWidth,
            height: 1.5
        ))
    }

    private static func drawContinuationHeader(
        documentTitle: String,
        reference: String,
        in cg: CGContext
    ) {
        let logoWidth: CGFloat = 60
        let logoHeight = logoWidth
            * (KitLogoGeometry.fullViewBox.height / KitLogoGeometry.fullViewBox.width)
        drawFullLogo(
            in: CGRect(x: Metrics.margin, y: 48, width: logoWidth, height: logoHeight),
            context: cg
        )
        let rightX = Metrics.margin + logoWidth + 24
        let rightWidth = Metrics.pageSize.width - Metrics.margin - rightX
        let referenceText = attributed(
            reference.isEmpty
                ? "\(documentTitle) (continued)"
                : "\(documentTitle) · \(reference) (continued)",
            font: .systemFont(ofSize: 10, weight: .medium),
            color: Palette.labelGray,
            alignment: .right
        )
        referenceText.draw(in: CGRect(x: rightX, y: 55, width: rightWidth, height: 14))

        cg.setFillColor(Palette.green.cgColor)
        cg.fill(CGRect(x: Metrics.margin, y: 80, width: Metrics.contentWidth, height: 1))
    }

    private static func drawFooter(note: String, page: Int, of total: Int, in cg: CGContext) {
        let markHeight: CGFloat = 18
        let markWidth = markHeight
            * (KitLogoGeometry.markViewBox.width / KitLogoGeometry.markViewBox.height)
        drawMark(
            in: CGRect(x: Metrics.margin, y: Metrics.footerY, width: markWidth, height: markHeight),
            context: cg
        )
        let textX = Metrics.margin + markWidth + 10
        let line1 = attributed(
            "Generated by Kit Pay · pay.kit.africa",
            font: .systemFont(ofSize: 9, weight: .medium),
            color: Palette.footerGray
        )
        line1.draw(in: CGRect(x: textX, y: Metrics.footerY, width: 380, height: 12))
        let line2 = attributed(
            note,
            font: .systemFont(ofSize: 8, weight: .regular),
            color: Palette.footerGray
        )
        line2.draw(in: CGRect(x: textX, y: Metrics.footerY + 14, width: 380, height: 11))

        if total > 1 {
            let number = attributed(
                "\(page) of \(total)",
                font: .systemFont(ofSize: 9, weight: .regular),
                color: Palette.footerGray,
                alignment: .right
            )
            number.draw(in: CGRect(
                x: Metrics.pageSize.width - Metrics.margin - 80,
                y: Metrics.footerY + 14,
                width: 80,
                height: 12
            ))
        }
    }

    // MARK: Details card

    private static func drawCard(
        rows: [RowMetrics],
        top: CGFloat,
        valueWidth: CGFloat,
        in cg: CGContext
    ) {
        guard !rows.isEmpty else { return }
        let cardHeight = rows.reduce(0) { $0 + $1.height } + Metrics.cardPadding * 2
        let cardRect = CGRect(
            x: Metrics.margin,
            y: top,
            width: Metrics.contentWidth,
            height: cardHeight
        )
        let cardPath = UIBezierPath(
            roundedRect: cardRect.insetBy(dx: 0.5, dy: 0.5),
            cornerRadius: Metrics.cardCornerRadius
        )
        Palette.cardFill.setFill()
        cardPath.fill()
        Palette.cardStroke.setStroke()
        cardPath.lineWidth = 1
        cardPath.stroke()

        let labelX = Metrics.margin + Metrics.cardPadding
        let valueX = labelX + Metrics.labelColumnWidth + Metrics.columnGap
        var y = top + Metrics.cardPadding
        for (index, row) in rows.enumerated() {
            row.label.draw(in: CGRect(
                x: labelX,
                y: y + Metrics.rowVerticalPadding + 1,
                width: Metrics.labelColumnWidth,
                height: row.height - Metrics.rowVerticalPadding * 2
            ))
            row.value.draw(in: CGRect(
                x: valueX,
                y: y + Metrics.rowVerticalPadding,
                width: valueWidth,
                height: row.height - Metrics.rowVerticalPadding * 2
            ))
            y += row.height
            if index < rows.count - 1 {
                cg.setFillColor(Palette.hairline.cgColor)
                cg.fill(CGRect(
                    x: labelX,
                    y: y - 0.25,
                    width: Metrics.contentWidth - Metrics.cardPadding * 2,
                    height: 0.5
                ))
            }
        }
    }

    // MARK: Logo drawing (converted from the SwiftUI brand shapes)

    private static func drawFullLogo(in rect: CGRect, context cg: CGContext) {
        let markPath = KitLogoMarkShape().path(in: rect).cgPath
        let accentPath = KitLogoAccentShape().path(in: rect).cgPath
        let lettersPath = KitLogoLettersShape().path(in: rect).cgPath

        cg.saveGState()
        // Bubble mark: even-odd so the inner cut-out stays white.
        cg.addPath(markPath)
        cg.setFillColor(Palette.navy.cgColor)
        cg.fillPath(using: .evenOdd)
        // Green sweep, clipped to the mark exactly as KitLogoView does.
        cg.saveGState()
        cg.addPath(markPath)
        cg.clip(using: .evenOdd)
        cg.addPath(accentPath)
        cg.setFillColor(Palette.green.cgColor)
        cg.fillPath()
        cg.restoreGState()
        // Letterforms.
        cg.addPath(lettersPath)
        cg.setFillColor(Palette.navy.cgColor)
        cg.fillPath()
        cg.restoreGState()
    }

    private static func drawMark(in rect: CGRect, context cg: CGContext) {
        let viewBox = KitLogoGeometry.markViewBox
        let markPath = KitLogoMarkShape(viewBox: viewBox).path(in: rect).cgPath
        let accentPath = KitLogoAccentShape(viewBox: viewBox).path(in: rect).cgPath

        cg.saveGState()
        cg.addPath(markPath)
        cg.setFillColor(Palette.navy.cgColor)
        cg.fillPath(using: .evenOdd)
        cg.saveGState()
        cg.addPath(markPath)
        cg.clip(using: .evenOdd)
        cg.addPath(accentPath)
        cg.setFillColor(Palette.green.cgColor)
        cg.fillPath()
        cg.restoreGState()
        cg.restoreGState()
    }

    // MARK: Text helpers

    private static func attributed(
        _ string: String,
        font: UIFont,
        color: UIColor,
        kern: CGFloat = 0,
        alignment: NSTextAlignment = .left
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        if kern != 0 { attributes[.kern] = kern }
        return NSAttributedString(string: string, attributes: attributes)
    }

    private static func measuredHeight(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height)
    }
}

// MARK: - Share button

/// The single "Share receipt" affordance: exports the receipt PDF on tap, then presents the
/// system share sheet with the status-aware message and the PDF attached together.
struct ShareReceiptButton: View {
    let transaction: WalletTransaction
    /// The account holder's display name where the call site has it (e.g. `model.profile?.name`).
    let senderName: String?

    @State private var generatedReceipt: GeneratedReceipt?
    @State private var isGenerating = false
    @State private var generationError: String?

    var body: some View {
        VStack(spacing: 8) {
            Button {
                generateAndShare()
            } label: {
                if isGenerating {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Share receipt", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(KitSecondaryButtonStyle())
            .disabled(isGenerating)

            if let generationError {
                Text(generationError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .sheet(item: $generatedReceipt) { receipt in
            ActivityShareSheet(items: [receipt.message, receipt.url])
                .ignoresSafeArea()
        }
    }

    private func generateAndShare() {
        guard !isGenerating else { return }
        isGenerating = true
        generationError = nil
        let content = KitReceiptContent.from(transaction: transaction, senderName: senderName)
        Task { @MainActor in
            do {
                let url = try KitReceiptPDFRenderer.render(content)
                generatedReceipt = GeneratedReceipt(url: url, message: content.shareMessage)
            } catch {
                generationError = "Could not create the receipt PDF. Please try again."
            }
            isGenerating = false
        }
    }
}

/// Produces a print-ready instruction sheet from the same authoritative fields shown in the
/// deposit flow. The wording intentionally stays plain: customers export a PDF; the visual brand
/// treatment is not presented as a different document type.
struct ExportBankDepositPDFButton: View {
    let deposit: BankDepositRequestDTO
    let walletName: String?

    @State private var generatedDocument: GeneratedReceipt?
    @State private var isGenerating = false
    @State private var generationError: String?

    var body: some View {
        VStack(spacing: 8) {
            Button {
                generateAndShare()
            } label: {
                if isGenerating {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label(
                        BankDepositInstructions.exportActionTitle,
                        systemImage: "square.and.arrow.up"
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(KitSecondaryButtonStyle())
            .disabled(isGenerating)
            .accessibilityIdentifier("bank-deposit-export-pdf")

            if let generationError {
                Text(generationError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .sheet(item: $generatedDocument) { document in
            ActivityShareSheet(items: [document.message, document.url])
                .ignoresSafeArea()
        }
    }

    private func generateAndShare() {
        guard !isGenerating else { return }
        isGenerating = true
        generationError = nil
        let content = KitReceiptContent.bankDepositInstructions(
            from: deposit,
            walletName: walletName
        )
        Task { @MainActor in
            do {
                let url = try KitReceiptPDFRenderer.render(content)
                generatedDocument = GeneratedReceipt(url: url, message: content.shareMessage)
            } catch {
                generationError = "Could not create the bank deposit PDF. Please try again."
            }
            isGenerating = false
        }
    }
}

private struct GeneratedReceipt: Identifiable {
    let id = UUID()
    let url: URL
    let message: String
}

/// `ShareLink` cannot attach a text message alongside a file, so the share sheet is presented
/// through UIKit with both items.
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
