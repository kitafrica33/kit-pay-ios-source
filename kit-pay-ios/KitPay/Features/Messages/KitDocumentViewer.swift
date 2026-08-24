import PDFKit
import QuickLook
import SwiftUI
import UIKit

// MARK: - Viewer shell

/// Full-screen in-app viewer for a decrypted document temp file.
///
/// PDFs get a native PDFKit reader (continuous scroll, pinch zoom, page indicator, text search).
/// CSV gets a capped safe table, TXT a selectable text reader, and every office/unknown format
/// falls back to an embedded QuickLook preview under the same glass header.
struct KitDocumentViewerView: View {
    let fileURL: URL          // decrypted plaintext temp file, extension already correct
    let displayName: String
    let mediaType: String
    let byteCount: Int
    let onClose: () -> Void

    @State private var showsPDFSearch = false

    /// CSV/TXT are the only routes that materialise the whole file in memory; anything larger
    /// streams through PDFKit/QuickLook instead.
    private static let maximumInMemoryTextBytes = 32 * 1_024 * 1_024

    private enum PreviewRoute {
        case pdf
        case csv
        case text
        case quickLook
        case unavailable
    }

    private var route: PreviewRoute {
        guard FileManager.default.fileExists(atPath: fileURL.path), byteCount > 0 else {
            return .unavailable
        }
        switch mediaType.lowercased() {
        case "application/pdf":
            return .pdf
        case "text/csv":
            return byteCount <= Self.maximumInMemoryTextBytes ? .csv : .quickLook
        case "text/plain":
            return byteCount <= Self.maximumInMemoryTextBytes ? .text : .quickLook
        default:
            return .quickLook
        }
    }

    private var typeLabel: String {
        ChatMediaTempFiles.fileExtension(forMediaType: mediaType).uppercased()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(KitColor.canvas.ignoresSafeArea())
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            GlassIconButton(systemName: "xmark", tint: KitColor.primaryText) {
                onClose()
            }
            .accessibilityLabel("Close document")

            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(
                    text: displayName,
                    font: .subheadline.weight(.semibold),
                    color: KitColor.primaryText
                )
                Text("\(typeLabel) · \(ChatMediaBytes.label(byteCount))")
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
                    .lineLimit(1)
            }

            if route == .pdf {
                GlassIconButton(
                    systemName: showsPDFSearch ? "magnifyingglass.circle.fill" : "magnifyingglass",
                    tint: KitColor.green
                ) {
                    withAnimation(.snappy(duration: 0.2)) { showsPDFSearch.toggle() }
                }
                .accessibilityLabel(showsPDFSearch ? "Hide search" : "Search in document")
            }

            ShareLink(item: fileURL) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(KitColor.green)
                    .kitCircularGlass(diameter: 44)
            }
            .accessibilityLabel("Share \(displayName)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .kitGlass(cornerRadius: 26)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: Routed content

    @ViewBuilder
    private var content: some View {
        switch route {
        case .pdf:
            KitPDFPreview(
                fileURL: fileURL,
                displayName: displayName,
                typeLabel: typeLabel,
                byteCount: byteCount,
                showsSearch: $showsPDFSearch
            )
        case .csv:
            KitCSVPreview(
                fileURL: fileURL,
                displayName: displayName,
                typeLabel: typeLabel,
                byteCount: byteCount
            )
        case .text:
            KitTextPreview(
                fileURL: fileURL,
                displayName: displayName,
                typeLabel: typeLabel,
                byteCount: byteCount
            )
        case .quickLook:
            KitInlineQuickLookView(fileURL: fileURL)
                .ignoresSafeArea(edges: .bottom)
        case .unavailable:
            DocumentInfoCard(
                fileURL: fileURL,
                displayName: displayName,
                typeLabel: typeLabel,
                byteCount: byteCount
            )
        }
    }
}

// MARK: - PDF preview (PDFKit)

private struct KitPDFPreview: View {
    let fileURL: URL
    let displayName: String
    let typeLabel: String
    let byteCount: Int
    @Binding var showsSearch: Bool

    private enum LoadState: Equatable {
        case loading, ready, locked, failed
    }

    @State private var loadState: LoadState = .loading
    @State private var document: PDFDocument?
    @State private var currentPage = 1
    @State private var pageCount = 0
    @State private var searchText = ""
    @State private var searchResults: [PDFSelection] = []
    @State private var activeResultIndex: Int?
    /// Bumped whenever the active selection should be scrolled to; lets the representable
    /// distinguish "same selection, jump again" from unrelated state updates.
    @State private var searchGeneration = 0

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                ProgressView("Opening PDF…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .locked:
                DocumentInfoCard(
                    fileURL: fileURL,
                    displayName: displayName,
                    typeLabel: typeLabel,
                    byteCount: byteCount,
                    message: "This PDF is password protected and can't be previewed here."
                )
            case .failed:
                DocumentInfoCard(
                    fileURL: fileURL,
                    displayName: displayName,
                    typeLabel: typeLabel,
                    byteCount: byteCount
                )
            case .ready:
                if let document {
                    VStack(spacing: 0) {
                        if showsSearch {
                            searchBar
                        }
                        ZStack(alignment: .bottomTrailing) {
                            PDFKitContainerView(
                                document: document,
                                highlighted: searchResults,
                                activeSelection: activeResultIndex.map { searchResults[$0] },
                                searchGeneration: searchGeneration,
                                onPageChanged: { page in currentPage = page }
                            )
                            pageIndicator
                        }
                    }
                }
            }
        }
        .task {
            guard loadState == .loading else { return }
            // PDFDocument reads pages lazily from the URL; it never loads the whole file eagerly.
            guard let loaded = PDFDocument(url: fileURL) else {
                loadState = .failed
                return
            }
            guard !loaded.isLocked else {
                loadState = .locked
                return
            }
            guard loaded.pageCount > 0 else {
                loadState = .failed
                return
            }
            document = loaded
            pageCount = loaded.pageCount
            loadState = .ready
        }
        .onChange(of: showsSearch) { _, isShown in
            guard !isShown else { return }
            searchText = ""
            searchResults = []
            activeResultIndex = nil
            searchGeneration += 1
        }
    }

    private var pageIndicator: some View {
        Text("\(currentPage) / \(pageCount)")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(KitColor.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(14)
            .accessibilityLabel("Page \(currentPage) of \(pageCount)")
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(KitColor.secondaryText)
                TextField("Search in document", text: $searchText)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { runSearch() }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(.ultraThinMaterial, in: Capsule())

            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(matchCountLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(KitColor.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
            }

            Button { step(-1) } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(searchResults.isEmpty ? KitColor.secondaryText : KitColor.green)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(searchResults.isEmpty)
            .accessibilityLabel("Previous match")

            Button { step(1) } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(searchResults.isEmpty ? KitColor.secondaryText : KitColor.green)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(searchResults.isEmpty)
            .accessibilityLabel("Next match")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .task(id: searchText) {
            // Debounce so a fast typist doesn't run a full-document scan per keystroke.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            runSearch()
        }
    }

    private var matchCountLabel: String {
        guard !searchResults.isEmpty else { return "No matches" }
        let position = (activeResultIndex ?? 0) + 1
        return "\(position) of \(searchResults.count)"
    }

    private func runSearch() {
        guard let document else { return }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            activeResultIndex = nil
            searchGeneration += 1
            return
        }
        let found = document.findString(query, withOptions: .caseInsensitive)
        searchResults = found
        activeResultIndex = found.isEmpty ? nil : 0
        applyHighlightColors()
        searchGeneration += 1
    }

    /// Every match is yellow; the active one is orange so next/previous has a visible cursor.
    private func applyHighlightColors() {
        for (index, selection) in searchResults.enumerated() {
            selection.color = index == activeResultIndex
                ? UIColor.systemOrange
                : UIColor.systemYellow.withAlphaComponent(0.85)
        }
    }

    private func step(_ delta: Int) {
        let count = searchResults.count
        guard count > 0 else { return }
        let current = activeResultIndex ?? 0
        activeResultIndex = ((current + delta) % count + count) % count
        applyHighlightColors()
        searchGeneration += 1
    }
}

private struct PDFKitContainerView: UIViewRepresentable {
    let document: PDFDocument
    let highlighted: [PDFSelection]
    let activeSelection: PDFSelection?
    let searchGeneration: Int
    let onPageChanged: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.backgroundColor = .secondarySystemBackground
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.usePageViewController(false)
        view.document = document

        let coordinator = context.coordinator
        coordinator.onPageChanged = onPageChanged
        coordinator.observer = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: view,
            queue: .main
        ) { [weak view] _ in
            guard let view,
                  let page = view.currentPage,
                  let document = view.document
            else { return }
            coordinator.onPageChanged(document.index(for: page) + 1)
        }

        DispatchQueue.main.async {
            // scaleFactorForSizeToFit is only meaningful after the first layout pass, so the
            // pinch bounds are anchored around it here rather than at construction time.
            let fit = view.scaleFactorForSizeToFit
            if fit > 0 {
                view.minScaleFactor = fit * 0.5
                view.maxScaleFactor = max(fit * 5, 5)
            } else {
                view.minScaleFactor = 0.25
                view.maxScaleFactor = 5
            }
            coordinator.onPageChanged(1)
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.onPageChanged = onPageChanged
        view.highlightedSelections = highlighted.isEmpty ? nil : highlighted
        if context.coordinator.lastSearchGeneration != searchGeneration {
            context.coordinator.lastSearchGeneration = searchGeneration
            if let activeSelection {
                view.go(to: activeSelection)
            }
        }
    }

    static func dismantleUIView(_ uiView: PDFView, coordinator: Coordinator) {
        if let observer = coordinator.observer {
            NotificationCenter.default.removeObserver(observer)
        }
        // The token retains its block, which captures the coordinator; break the cycle so the
        // coordinator does not leak per presentation.
        coordinator.observer = nil
    }

    final class Coordinator {
        var onPageChanged: (Int) -> Void = { _ in }
        var lastSearchGeneration = 0
        var observer: NSObjectProtocol?
    }
}

// MARK: - CSV table

/// RFC-4180-ish parse result, capped for safe rendering of arbitrary user files.
struct KitCSVTable: Sendable {
    let rows: [[String]]
    let columnCount: Int
    let rowsTruncated: Bool
    let columnsTruncated: Bool

    static let maximumRows = 2_000
    static let maximumColumns = 40

    /// Lenient RFC 4180 parser.
    ///
    /// Handles quoted fields containing commas, newlines, and `""` escaped quotes; accepts CRLF,
    /// LF, and lone-CR row endings; keeps stray mid-field quotes literally; flushes an
    /// unterminated quoted field at EOF; drops fully blank lines; and stops scanning as soon as
    /// the row cap is reached so a huge file costs only the capped prefix.
    static func parse(
        _ text: String,
        maxRows: Int = maximumRows,
        maxColumns: Int = maximumColumns
    ) -> KitCSVTable {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var fieldIndex = 0
        var inQuotes = false
        var columnsTruncated = false
        var rowsTruncated = false

        func endField() {
            if fieldIndex < maxColumns {
                row.append(field)
            } else {
                columnsTruncated = true
            }
            fieldIndex += 1
            field = ""
        }

        /// Returns false once the row cap has been reached.
        func endRow() -> Bool {
            endField()
            let isBlankLine = row.count == 1 && row[0].isEmpty && fieldIndex == 1
            if !isBlankLine {
                rows.append(row)
            }
            row = []
            fieldIndex = 0
            return rows.count < maxRows
        }

        func remainderHasContent(after index: String.Index) -> Bool {
            text[index...].contains { $0 != "\n" && $0 != "\r" }
        }

        var index = text.startIndex
        let end = text.endIndex
        scan: while index < end {
            let character = text[index]
            if inQuotes {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < end, text[next] == "\"" {
                        // Escaped quote inside a quoted field.
                        field.append("\"")
                        index = text.index(after: next)
                        continue
                    }
                    inQuotes = false
                    index = next
                    continue
                }
                field.append(character)
                index = text.index(after: index)
                continue
            }
            switch character {
            case "\"":
                if field.isEmpty {
                    inQuotes = true
                } else {
                    // Lenient: a quote in the middle of an unquoted field stays literal.
                    field.append("\"")
                }
            case ",":
                endField()
            case "\r":
                let next = text.index(after: index)
                if next < end, text[next] == "\n" {
                    index = next // collapse CRLF into one row break
                }
                if !endRow() {
                    index = text.index(after: index)
                    rowsTruncated = remainderHasContent(after: index)
                    break scan
                }
            case "\n":
                if !endRow() {
                    index = text.index(after: index)
                    rowsTruncated = remainderHasContent(after: index)
                    break scan
                }
            default:
                field.append(character)
            }
            index = text.index(after: index)
        }
        // Final record without a trailing newline (also flushes an unterminated quoted field).
        if !field.isEmpty || fieldIndex > 0 || !row.isEmpty {
            _ = endRow()
        }
        let columnCount = rows.reduce(0) { max($0, $1.count) }
        return KitCSVTable(
            rows: rows,
            columnCount: columnCount,
            rowsTruncated: rowsTruncated,
            columnsTruncated: columnsTruncated
        )
    }
}

private struct KitCSVPreview: View {
    let fileURL: URL
    let displayName: String
    let typeLabel: String
    let byteCount: Int

    @State private var table: KitCSVTable?
    @State private var failed = false

    private static let columnWidth: CGFloat = 120

    var body: some View {
        Group {
            if failed {
                DocumentInfoCard(
                    fileURL: fileURL,
                    displayName: displayName,
                    typeLabel: typeLabel,
                    byteCount: byteCount
                )
            } else if let table {
                if table.rows.isEmpty {
                    ContentUnavailableView(
                        "Empty file",
                        systemImage: "tablecells",
                        description: Text("There's no data in this CSV.")
                    )
                } else {
                    tableView(table)
                }
            } else {
                ProgressView("Reading table…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard table == nil, !failed else { return }
        // The caller only routes here after the 32 MB byte-count check.
        let url = fileURL
        let parsed: KitCSVTable? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
            else { return nil }
            return KitCSVTable.parse(text)
        }.value
        if let parsed {
            table = parsed
        } else {
            failed = true
        }
    }

    private func tableView(_ table: KitCSVTable) -> some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: true) {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        csvRow(table.rows[0], columnCount: table.columnCount, isHeader: true)
                        ForEach(1 ..< table.rows.count, id: \.self) { rowIndex in
                            csvRow(
                                table.rows[rowIndex],
                                columnCount: table.columnCount,
                                isHeader: false
                            )
                            .background(
                                rowIndex.isMultiple(of: 2)
                                    ? KitColor.paleGreen.opacity(0.12)
                                    : Color.clear
                            )
                        }
                    }
                }
            }
            if table.rowsTruncated || table.columnsTruncated {
                truncationFootnote(table)
            }
        }
    }

    private func csvRow(_ cells: [String], columnCount: Int, isHeader: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0 ..< max(columnCount, 1), id: \.self) { column in
                Text(column < cells.count ? cells[column] : "")
                    .font(isHeader ? .footnote.weight(.bold) : .footnote.monospacedDigit())
                    .foregroundStyle(KitColor.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .frame(width: Self.columnWidth, alignment: .leading)
            }
        }
        .background(isHeader ? KitColor.paleGreen : Color.clear)
        .accessibilityElement(children: .combine)
    }

    private func truncationFootnote(_ table: KitCSVTable) -> some View {
        var notes: [String] = []
        if table.rowsTruncated {
            notes.append("Showing the first \(KitCSVTable.maximumRows.formatted()) rows")
        }
        if table.columnsTruncated {
            notes.append("showing the first \(KitCSVTable.maximumColumns) columns")
        }
        return Text(notes.joined(separator: " · ") + ".")
            .font(.caption)
            .foregroundStyle(KitColor.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
    }
}

// MARK: - Plain text

private struct KitTextPreview: View {
    let fileURL: URL
    let displayName: String
    let typeLabel: String
    let byteCount: Int

    @State private var text: String?
    @State private var failed = false
    @State private var monospaced = false

    var body: some View {
        Group {
            if failed {
                DocumentInfoCard(
                    fileURL: fileURL,
                    displayName: displayName,
                    typeLabel: typeLabel,
                    byteCount: byteCount
                )
            } else if let text {
                if text.isEmpty {
                    ContentUnavailableView(
                        "Empty file",
                        systemImage: "doc.text",
                        description: Text("There's no text in this file.")
                    )
                } else {
                    reader(text)
                }
            } else {
                ProgressView("Opening text…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
    }

    private func reader(_ text: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    withAnimation(.snappy(duration: 0.2)) { monospaced.toggle() }
                } label: {
                    Label("Monospaced", systemImage: "textformat")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(monospaced ? KitColor.navy : KitColor.secondaryText)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background {
                            if monospaced {
                                Capsule().fill(KitColor.paleGreen)
                            }
                        }
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Monospaced font")
                .accessibilityAddTraits(monospaced ? .isSelected : [])
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            ScrollView {
                Text(text)
                    .font(monospaced ? .footnote.monospaced() : .body)
                    .foregroundStyle(KitColor.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    private func load() async {
        guard text == nil, !failed else { return }
        // The caller only routes here after the 32 MB byte-count check.
        let url = fileURL
        let decoded: String? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        }.value
        if let decoded {
            text = decoded
        } else {
            failed = true
        }
    }
}

// MARK: - QuickLook fallback (office formats and everything else)

/// Bare QLPreviewController without a navigation-controller wrapper: the unified glass header
/// above it already provides the title, Close, and Share affordances.
private struct KitInlineQuickLookView: UIViewControllerRepresentable {
    let fileURL: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let fileURL: URL

        init(fileURL: URL) {
            self.fileURL = fileURL
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            fileURL as NSURL
        }
    }
}

// MARK: - File information fallback

private struct DocumentInfoCard: View {
    let fileURL: URL
    let displayName: String
    let typeLabel: String
    let byteCount: Int
    var message = "This file can't be previewed here."

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(KitColor.green)
                    .frame(width: 74, height: 74)
                    .background(
                        KitColor.paleGreen.opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                Text(displayName)
                    .font(.headline)
                    .foregroundStyle(KitColor.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text("\(typeLabel) · \(ChatMediaBytes.label(byteCount))")
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(KitColor.secondaryText)
                    .multilineTextAlignment(.center)
                ShareLink(item: fileURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .frame(minHeight: 44)
                        .background(KitColor.green, in: Capsule())
                }
                .accessibilityLabel("Share \(displayName)")
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .kitGlass(cornerRadius: 26)
            .padding(.horizontal, 20)
            Spacer()
        }
        .accessibilityElement(children: .contain)
    }
}
