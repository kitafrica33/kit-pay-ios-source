import PDFKit
import SwiftUI
import UIKit

/// Presented after choosing the conversation and before the final Send action.
/// The presenter retains the input URL. A successful callback transfers ownership of a NEW
/// protected scratch PDF; remove it with ChatMediaTempFiles.removeTemporaryFile after staging
/// has durably copied it, or when the outgoing draft is discarded. Nil means Cancel.
struct KitPDFPageSelectionView: View {
    let fileURL: URL
    let displayName: String
    let onFinish: (URL?) -> Void

    @State private var document: PDFDocument?
    @State private var selection = IndexSet()
    @State private var pageExpression = ""
    @State private var selectionError: String?
    @State private var documentError: String?
    @State private var exportError: String?
    @State private var pageCount = 0
    @State private var currentPageIndex = 0
    @State private var requestedPageIndex = 0
    @State private var navigationGeneration = 0
    @State private var isLoading = true
    @State private var isExporting = false
    @State private var didFinish = false
    @State private var securityScopedAccess = false
    @State private var loadTask: Task<PDFPageSelectionLoadedDocument, Error>?
    @State private var exportTask: Task<URL, Error>?
    @FocusState private var isEditingPages: Bool

    private var canContinue: Bool {
        document != nil && !selection.isEmpty && selectionError == nil && !isExporting
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isLoading {
                ProgressView("Opening PDF…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let document {
                selectionControls
                    .disabled(isExporting)
                PDFPageSelectionPreview(
                    document: document,
                    requestedPageIndex: requestedPageIndex,
                    navigationGeneration: navigationGeneration,
                    onPageChanged: { currentPageIndex = $0 }
                )
                .overlay(alignment: .center) {
                    if isExporting {
                        ProgressView("Preparing selected pages…")
                            .padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .allowsHitTesting(!isExporting)
                previewControls
                    .disabled(isExporting)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "doc.badge.ellipsis")
                        .font(.largeTitle)
                    Text(documentError ?? "This PDF could not be opened.")
                        .multilineTextAlignment(.center)
                    Button("Try again", action: loadDocument)
                        .buttonStyle(.bordered)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(KitColor.canvas.ignoresSafeArea())
        .interactiveDismissDisabled()
        .task { loadDocument() }
        .onDisappear {
            didFinish = true
            loadTask?.cancel()
            exportTask?.cancel()
            document = nil
            if securityScopedAccess {
                fileURL.stopAccessingSecurityScopedResource()
                securityScopedAccess = false
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button("Cancel", action: cancel)
                .frame(minHeight: 44)
                .accessibilityIdentifier("pdf-page-selection-cancel")
            VStack(alignment: .leading, spacing: 2) {
                Text("Select pages")
                    .font(.headline)
                Text(displayName)
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Continue", action: prepareSelection)
                .font(.body.weight(.semibold))
                .frame(minHeight: 44)
                .disabled(!canContinue)
                .accessibilityLabel("Continue with \(selection.count) selected pages")
                .accessibilityIdentifier("pdf-page-selection-continue")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .tint(KitColor.green)
    }

    private var selectionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(selection.count) of \(pageCount) pages selected")
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Button("All") {
                    setSelection((try? PDFPageSelectionPolicy.allPages(pageCount: pageCount)) ?? IndexSet())
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Select all pages")
                Button("Clear") { setSelection(IndexSet()) }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Clear selected pages")
            }
            .frame(minHeight: 36)
            TextField("Pages, for example 1–3, 5", text: $pageExpression)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isEditingPages)
                .onSubmit { isEditingPages = false }
                .onChange(of: pageExpression) { _, text in validateSelection(text) }
                .accessibilityLabel("Selected PDF pages and ranges")
                .accessibilityIdentifier("pdf-page-selection-ranges")
            if let message = selectionError ?? exportError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("pdf-page-selection-error")
            } else {
                Text("Pages stay in their original order. Review them before continuing.")
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .tint(KitColor.green)
    }

    private var previewControls: some View {
        HStack(spacing: 12) {
            Button { navigate(to: currentPageIndex - 1) } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }
            .disabled(currentPageIndex <= 0)
            .accessibilityLabel("Previous PDF page")
            Text("\(currentPageIndex + 1) / \(pageCount)")
                .font(.caption.monospacedDigit())
                .accessibilityLabel("Page \(currentPageIndex + 1) of \(pageCount)")
            Button { navigate(to: currentPageIndex + 1) } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }
            .disabled(currentPageIndex + 1 >= pageCount)
            .accessibilityLabel("Next PDF page")
            Spacer(minLength: 0)
            Button {
                var updated = selection
                if updated.contains(currentPageIndex) {
                    updated.remove(currentPageIndex)
                } else {
                    updated.insert(currentPageIndex)
                }
                setSelection(updated)
            } label: {
                Label(
                    selection.contains(currentPageIndex) ? "Included" : "Include",
                    systemImage: selection.contains(currentPageIndex) ? "checkmark.circle.fill" : "circle"
                )
                .font(.subheadline.weight(.medium))
                .frame(minHeight: 44)
            }
            .accessibilityLabel(
                "\(selection.contains(currentPageIndex) ? "Exclude" : "Include") page \(currentPageIndex + 1)"
            )
            .accessibilityIdentifier("pdf-page-selection-toggle")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .tint(KitColor.green)
    }

    private func loadDocument() {
        guard !didFinish, document == nil, loadTask == nil else { return }
        isLoading = true
        documentError = nil
        if !securityScopedAccess {
            securityScopedAccess = fileURL.startAccessingSecurityScopedResource()
        }
        let sourceURL = fileURL
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            // Hold the worker's own scope if cancellation dismisses the view while PDFKit is
            // opening the source. The view keeps a separate scope for subsequent lazy reads.
            let scopedAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if scopedAccess { sourceURL.stopAccessingSecurityScopedResource() }
            }
            let opened = try KitPDFPageSelectionExporter.openDocument(at: sourceURL)
            let pageCount = opened.pageCount
            try Task.checkCancellation()
            return PDFPageSelectionLoadedDocument(document: opened, pageCount: pageCount)
        }
        loadTask = worker
        Task { @MainActor in
            do {
                let opened = try await worker.value
                guard !didFinish, !worker.isCancelled else { return }
                // Exclusive transfer after the worker has finished. The worker never renders
                // or touches this PDFDocument once the main-actor preview takes ownership.
                document = opened.document
                pageCount = opened.pageCount
                setSelection(try PDFPageSelectionPolicy.allPages(pageCount: opened.pageCount))
            } catch {
                guard !didFinish else { return }
                documentError = error.localizedDescription
            }
            loadTask = nil
            isLoading = false
        }
    }

    private func validateSelection(_ text: String) {
        exportError = nil
        do {
            selection = try PDFPageSelectionPolicy.pageIndexes(from: text, pageCount: pageCount)
            selectionError = nil
        } catch {
            // Invalid edits never leave the last valid selection enabled for confirmation.
            selection = IndexSet()
            selectionError = error.localizedDescription
        }
    }

    private func setSelection(_ indexes: IndexSet) {
        selection = indexes
        pageExpression = PDFPageSelectionPolicy.expression(for: indexes)
        selectionError = indexes.isEmpty ? PDFPageSelectionPolicy.SelectionError.emptySelection.localizedDescription : nil
        exportError = nil
    }

    private func navigate(to index: Int) {
        guard (0..<pageCount).contains(index) else { return }
        isEditingPages = false
        requestedPageIndex = index
        navigationGeneration += 1
    }

    private func cancel() {
        guard !didFinish else { return }
        didFinish = true
        loadTask?.cancel()
        exportTask?.cancel()
        onFinish(nil)
    }

    private func prepareSelection() {
        guard canContinue, !didFinish else { return }
        isEditingPages = false
        isExporting = true
        exportError = nil
        let sourceURL = fileURL
        let name = displayName
        let indexes = selection
        // Preview and exporter never share a PDFDocument across queues. Only the URL and
        // value-type selection cross the boundary; output ownership returns on the main actor.
        let worker = Task.detached(priority: .userInitiated) {
            try KitPDFPageSelectionExporter.export(
                fileURL: sourceURL,
                displayName: name,
                pageIndexes: indexes
            )
        }
        exportTask = worker
        Task { @MainActor in
            do {
                let output = try await worker.value
                guard !didFinish, !worker.isCancelled else {
                    ChatMediaTempFiles.removeTemporaryFile(output)
                    return
                }
                exportTask = nil
                isExporting = false
                didFinish = true
                onFinish(output)
            } catch {
                guard !didFinish else { return }
                exportTask = nil
                isExporting = false
                exportError = error.localizedDescription
            }
        }
    }
}

/// A one-way transfer only: the loading worker finishes before the main actor reads the
/// document. PDFKit objects are never accessed concurrently, and export opens its own instance.
private struct PDFPageSelectionLoadedDocument: @unchecked Sendable {
    let document: PDFDocument
    let pageCount: Int
}

enum KitPDFPageSelectionExporter {
    enum ExportError: LocalizedError {
        case unreadableDocument
        case lockedDocument
        case restrictedDocument
        case tooLarge
        case couldNotExport

        var errorDescription: String? {
            switch self {
            case .unreadableDocument: "This PDF could not be opened. Choose another file."
            case .lockedDocument: "Unlock this PDF before selecting its pages."
            case .restrictedDocument: "This PDF does not allow its pages to be copied."
            case .tooLarge: "This PDF is larger than the document attachment limit."
            case .couldNotExport: "The selected pages could not be prepared. Please try again."
            }
        }
    }

    static func openDocument(at fileURL: URL) throws -> PDFDocument {
        guard fileURL.isFileURL else { throw ExportError.unreadableDocument }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw ExportError.unreadableDocument
        }
        guard size <= KitChatMediaLimits.maximumTransferBytes else { throw ExportError.tooLarge }
        guard let document = PDFDocument(url: fileURL) else { throw ExportError.unreadableDocument }
        guard !document.isLocked else { throw ExportError.lockedDocument }
        guard document.allowsCopying, document.allowsDocumentAssembly else {
            throw ExportError.restrictedDocument
        }
        _ = try PDFPageSelectionPolicy.allPages(pageCount: document.pageCount)
        return document
    }

    /// Synchronous worker entry point. The caller must keep expensive page assembly off the
    /// main actor. Neither the original PDF nor the preview's PDFDocument is ever modified.
    static func export(
        fileURL: URL,
        displayName: String,
        pageIndexes: IndexSet,
        beforePublishing: (URL) -> Void = { _ in }
    ) throws -> URL {
        try Task.checkCancellation()
        let scopedAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if scopedAccess { fileURL.stopAccessingSecurityScopedResource() }
        }
        let source = try openDocument(at: fileURL)
        let indexes = try PDFPageSelectionPolicy.validatedPageIndexes(pageIndexes, pageCount: source.pageCount)
        let selected = PDFDocument()
        for index in indexes {
            try Task.checkCancellation()
            guard let page = source.page(at: index)?.copy() as? PDFPage else {
                throw ExportError.couldNotExport
            }
            selected.insert(page, at: selected.pageCount)
        }
        try Task.checkCancellation()

        // Bound filename bytes even for multibyte names. Repairing a truncated UTF-8 scalar
        // is harmless for a display stem, while preserving the original attachment name is
        // the presenter's responsibility when it stages the returned file.
        let stem = String(decoding: (displayName as NSString).deletingPathExtension.utf8.prefix(120), as: UTF8.self)
        // The shared helper creates a protected, backup-excluded directory and protected empty
        // destination BEFORE PDFKit writes plaintext. Any replacement inherits that directory's
        // protection. No complete-PDF Data representation or unprotected staging path is used.
        let destination = try ChatMediaTempFiles.writeTemporaryFile(
            data: Data(),
            mediaType: "application/pdf",
            suggestedName: "\(stem.isEmpty ? "Document" : stem)-selected.pdf"
        )
        do {
            guard selected.write(to: destination) else { throw ExportError.couldNotExport }
            try Task.checkCancellation()
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
#if targetEnvironment(simulator)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: destination.path
            )
#else
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: destination.path
            )
#endif
            let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 else { throw ExportError.couldNotExport }
            guard size <= KitChatMediaLimits.maximumTransferBytes else { throw ExportError.tooLarge }
            guard let verified = PDFDocument(url: destination), verified.pageCount == indexes.count else {
                throw ExportError.couldNotExport
            }
            // This synchronous internal observer permits a deterministic late-cancellation
            // test. It does not transfer ownership; only a successful return publishes a URL.
            beforePublishing(destination)
            try Task.checkCancellation()
            return destination
        } catch {
            ChatMediaTempFiles.removeTemporaryFile(destination)
            throw error
        }
    }
}

private struct PDFPageSelectionPreview: UIViewRepresentable {
    let document: PDFDocument
    let requestedPageIndex: Int
    let navigationGeneration: Int
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
        ) { [weak view, weak coordinator] _ in
            guard let view, let document = view.document, let page = view.currentPage else { return }
            let index = document.index(for: page)
            guard (0..<document.pageCount).contains(index) else { return }
            DispatchQueue.main.async { [weak coordinator] in coordinator?.onPageChanged(index) }
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.onPageChanged = onPageChanged
        guard context.coordinator.navigationGeneration != navigationGeneration else { return }
        context.coordinator.navigationGeneration = navigationGeneration
        if let page = document.page(at: requestedPageIndex) { view.go(to: page) }
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
        coordinator.observer = nil
        coordinator.onPageChanged = { _ in }
        view.document = nil
    }

    final class Coordinator {
        var onPageChanged: (Int) -> Void = { _ in }
        var navigationGeneration = -1
        var observer: NSObjectProtocol?
    }
}
