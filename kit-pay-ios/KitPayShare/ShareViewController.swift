import ImageIO
import Intents
import UIKit
import UniformTypeIdentifiers

/// Direct encrypted sending from the system share sheet. Staging is provisional until the
/// explicit Send tap journals a recoverable message; completion requires a validated receipt.
final class ShareViewController: UIViewController {
    private struct PendingShare {
        let batchID: UUID
        let ownerAccountID: String
        let items: [SharedInboxItem]
        let text: String?
        let warning: String?
    }

    private let store = DirectShareSendRecord.stagingStore

    private let cancelButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusSymbol = UIImageView()
    private let summaryLabel = UILabel()
    private let messageLabel = UILabel()
    private let previewStrip = UIStackView()
    private let captionInput = UITextView()
    private let searchBar = UISearchBar()
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private let secondaryActionButton = UIButton(type: .system)

    private var pendingShare: PendingShare?
    private var destinations: [SharedInboxDestination] = []
    private var filteredDestinations: [SharedInboxDestination] = []
    private var requestedDestination: SharedInboxDestination?
    private var hasRequestedDestination = false
    private var batchIDBeingStaged: UUID?
    private var hasPublishedBatch = false
    private var hasPresentedFailure = false
    private var hasFinished = false
    private var isCollecting = false
    private var collectionTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var queuedDestination: SharedInboxDestination?
    private var isPresentingEditor = false
    private var isCommittingSend = false
    private var hasLeftShareSheet = false
    private var sendScope: MessagingProcessBroker.Scope?

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasLeftShareSheet = false
        guard !hasFinished,
              !hasPublishedBatch,
              !hasPresentedFailure,
              !isCollecting,
              pendingShare == nil
        else { return }
        isCollecting = true
        collectionTask = Task { await collectShare() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !isPresentingEditor else { return }
        hasLeftShareSheet = true
        // Dismissal before Send discards staging; an explicitly queued message must survive.
        sendTask?.cancel()
        if !hasFinished, !hasPublishedBatch, !isCommittingSend {
            collectionTask?.cancel()
            if let batchIDBeingStaged { store.remove(batchID: batchIDBeingStaged) }
        }
    }

    // MARK: Collecting

    private func collectShare() async {
        let batchID = UUID()
        batchIDBeingStaged = batchID

        let ownerAccountID: String
        do {
            let directory = try await MessagingProcessBroker.shared.authorizeShare()
            ownerAccountID = directory.accountID
            destinations = directory.destinations
            filteredDestinations = destinations
            // A system suggestion selects a current, approved row only. Sending always needs
            // the customer's explicit Send tap after the share sheet has opened.
            if let intent = extensionContext?.intent as? INSendMessageIntent {
                requestedDestination = ShareSuggestions.destination(
                    conversationIdentifier: intent.conversationIdentifier,
                    accountID: ownerAccountID, destinations: destinations
                )
            }
        } catch {
            store.remove(batchID: batchID)
            batchIDBeingStaged = nil
            isCollecting = false
            present(failure: (error as? LocalizedError)?.errorDescription)
            return
        }

        var items: [SharedInboxItem] = []
        var textFragments: [String] = []
        var firstFailure: String?
        var skippedCount = 0

        // Hosts describe accompanying text two ways: `attributedContentText` on the extension
        // item itself, and/or a plain-text provider. Collect both, exactly as written — no
        // Foundation trimming, which would mutate contract-valid NBSP/U+0085/U+2028/U+2029.
        // Fragments deduplicate verbatim because many hosts mirror the same string into both
        // channels, and one caption must not say it twice.
        func appendTextFragment(_ fragment: String) {
            guard !SharedInboxPolicy.carriesNoContent(fragment),
                  !textFragments.contains(fragment)
            else { return }
            textFragments.append(fragment)
        }

        // One handoff is one message, and the payload is untrusted. `boundedPayload` walks the
        // extension items and their providers only up to the enumeration bound — it never
        // materializes an unbounded host array — and reports overflow instead of keeping a
        // prefix. Overflow, or more files than one batch may carry, fails the whole share here,
        // visibly, before any bytes are copied: silently sending part of a share would let
        // provider order decide which files (or whose caption) the recipient never sees. Text
        // providers do not spend the attachment budget: they become the caption, not attachments.
        let providers: [NSItemProvider]
        do {
            let payload = try boundedPayload()
            providers = payload.providers
            for attributed in payload.attributedTextFragments {
                appendTextFragment(attributed)
            }
        } catch {
            store.remove(batchID: batchID)
            batchIDBeingStaged = nil
            isCollecting = false
            present(failure: (error as? LocalizedError)?.errorDescription
                ?? SharedInboxError.tooManyItems.errorDescription)
            return
        }
        guard providers.filter({ isProspectiveAttachment($0) }).count
                <= SharedInboxPolicy.maximumItems
        else {
            store.remove(batchID: batchID)
            batchIDBeingStaged = nil
            isCollecting = false
            present(failure: SharedInboxError.tooManyItems.errorDescription)
            return
        }
        presentPreparingPicker(itemCount: providers.count)
        previewSelectedProviders(providers, batchID: batchID)

        for provider in providers {
            guard !Task.isCancelled, !hasFinished else {
                store.remove(batchID: batchID)
                batchIDBeingStaged = nil
                isCollecting = false
                return
            }
            let usedBytes = items.reduce(into: 0) { $0 += $1.byteCount }
            let loaded = await load(
                provider,
                batchID: batchID,
                maximumAcceptedBytes: SharedInboxPolicy.maximumBatchBytes - usedBytes
            )
            guard !Task.isCancelled, !hasFinished else {
                store.remove(batchID: batchID)
                batchIDBeingStaged = nil
                isCollecting = false
                return
            }
            switch loaded {
            case .staged(let item):
                // Backstop for the pre-copy count above: if classification ever drifts from
                // `load(_:)`, overflow still fails the whole share instead of trimming it —
                // removing the batch also unwinds the item `load` just staged into it.
                guard items.count < SharedInboxPolicy.maximumItems else {
                    store.remove(batchID: batchID)
                    batchIDBeingStaged = nil
                    isCollecting = false
                    present(failure: SharedInboxError.tooManyItems.errorDescription)
                    return
                }
                items.append(item)
            case .text(let value):
                appendTextFragment(value)
            case .failure(let message):
                skippedCount += 1
                firstFailure = firstFailure
                    ?? message
                    ?? SharedInboxError.unreadable.errorDescription
            }
        }

        // Byte-for-byte: the joined fragments reach the composer exactly as the source app wrote
        // them. The only normalization a caption ever gets is the V2 queue's six-scalar strip at
        // seal time; over-limit text fails visibly below instead of being cut to fit.
        let text = SharedInboxPolicy.carriedText(textFragments.joined(separator: "\n"))
        guard !Task.isCancelled, !hasFinished else {
            store.remove(batchID: batchID)
            batchIDBeingStaged = nil
            isCollecting = false
            return
        }
        if let text, SharedInboxPolicy.exceedsTextLimit(text) {
            store.remove(batchID: batchID)
            batchIDBeingStaged = nil
            isCollecting = false
            present(failure: SharedInboxError.textTooLong.errorDescription)
            return
        }
        guard !items.isEmpty || text != nil else {
            store.remove(batchID: batchID)
            batchIDBeingStaged = nil
            isCollecting = false
            present(failure: firstFailure ?? SharedInboxError.empty.errorDescription)
            return
        }

        let warning: String?
        if skippedCount > 0 {
            let countText = skippedCount == 1 ? "One item" : "\(skippedCount) items"
            warning = "\(countText) could not be included. "
                + (firstFailure ?? "Only supported items can be shared.")
        } else {
            warning = nil
        }

        let pending = PendingShare(
            batchID: batchID,
            ownerAccountID: ownerAccountID,
            items: items,
            text: text,
            warning: warning
        )
        pendingShare = pending
        isCollecting = false
        presentPicker(for: pending)
    }

    /// The untrusted payload, walked under a hard bound. Every element of `inputItems` — and
    /// every attached provider — counts against `SharedInboxPolicy.maximumEnumeratedProviders`;
    /// the walk stops and throws `tooManyItems` the moment either count would pass it, so a
    /// hostile host can neither make this extension materialize an unbounded array nor have a
    /// prefix of its payload silently chosen. Attributed accompanying text rides along exactly
    /// as written; an attributed string whose O(1) UTF-16 length already proves the text over
    /// the storage bound throws `textTooLong` without materializing it (every UTF-16 unit
    /// encodes to at least one UTF-8 byte, so the byte bound is certainly exceeded).
    private func boundedPayload() throws -> (
        providers: [NSItemProvider],
        attributedTextFragments: [String]
    ) {
        let limit = SharedInboxPolicy.maximumEnumeratedProviders
        var providers: [NSItemProvider] = []
        var fragments: [String] = []
        var walkedItems = 0
        for rawItem in extensionContext?.inputItems ?? [] {
            walkedItems += 1
            guard walkedItems <= limit else { throw SharedInboxError.tooManyItems }
            guard let item = rawItem as? NSExtensionItem else { continue }
            if let attributed = item.attributedContentText {
                guard attributed.length <= SharedInboxPolicy.maximumTextUTF8Bytes else {
                    throw SharedInboxError.textTooLong
                }
                fragments.append(attributed.string)
            }
            for provider in item.attachments ?? [] {
                guard providers.count < limit else { throw SharedInboxError.tooManyItems }
                providers.append(provider)
            }
        }
        return (providers, fragments)
    }

    /// Mirrors the branch order of `load(_:)`: exactly the providers whose payload would stage
    /// as an attachment, decided from registered metadata alone so the handoff can be sized
    /// against the attachment budget before any bytes are copied.
    private func isProspectiveAttachment(_ provider: NSItemProvider) -> Bool {
        fileTypeIdentifier(for: provider) != nil
            || provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }

    private enum LoadedShare {
        case staged(SharedInboxItem)
        case text(String)
        case failure(String?)
    }

    private func load(
        _ provider: NSItemProvider,
        batchID: UUID,
        maximumAcceptedBytes: Int
    ) async -> LoadedShare {
        if let type = fileTypeIdentifier(for: provider) {
            return await loadFile(
                provider,
                typeIdentifier: type,
                batchID: batchID,
                maximumAcceptedBytes: maximumAcceptedBytes
            )
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return await loadFileURL(
                provider,
                batchID: batchID,
                maximumAcceptedBytes: maximumAcceptedBytes
            )
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            return await loadURL(provider)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            return await loadText(provider)
        }
        return .failure(nil)
    }

    /// Some document providers expose only `public.file-url`, without a separate concrete data
    /// UTI. Copy that security-scoped/provider-owned URL before its callback ends, just like
    /// `loadFileRepresentation`, so generic files from Files do not fall through as unusable links.
    private func loadFileURL(
        _ provider: NSItemProvider,
        batchID: UUID,
        maximumAcceptedBytes: Int
    ) async -> LoadedShare {
        let suggestedName = provider.suggestedName
        let stagingStore = store
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let url = item as? URL, url.isFileURL else {
                    continuation.resume(returning: .failure(nil))
                    return
                }
                // Some Files providers vend a security-scoped URL here rather than a URL already
                // covered by the extension's temporary sandbox grant. Access it only for the
                // synchronous copy below; providers that do not require a scope simply return
                // false and remain readable through their ordinary item-provider grant.
                let accessedSecurityScope = url.startAccessingSecurityScopedResource()
                defer {
                    if accessedSecurityScope { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    let mediaType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                    let staged = try stagingStore.stage(
                        fileAt: url,
                        suggestedName: suggestedName ?? url.lastPathComponent,
                        mediaType: mediaType,
                        batchID: batchID,
                        maximumAcceptedBytes: maximumAcceptedBytes
                    )
                    continuation.resume(returning: .staged(staged))
                } catch {
                    continuation.resume(returning: .failure(
                        (error as? LocalizedError)?.errorDescription
                    ))
                }
            }
        }
    }

    /// The most specific registered type that is a file rather than a link or selected text.
    private func fileTypeIdentifier(for provider: NSItemProvider) -> String? {
        let registered = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        let isFile = registered.contains { $0.conforms(to: .fileURL) }
        let candidates = registered.filter {
            $0.conforms(to: .data)
                && !$0.conforms(to: .url)
                && (isFile || !$0.conforms(to: .text))
        }
        let media = candidates.first {
            $0.conforms(to: .image) || $0.conforms(to: .movie) || $0.conforms(to: .audio)
        }
        return (media ?? candidates.first)?.identifier
    }

    private func loadFile(
        _ provider: NSItemProvider,
        typeIdentifier: String,
        batchID: UUID,
        maximumAcceptedBytes: Int
    ) async -> LoadedShare {
        let suggestedName = provider.suggestedName
        let stagingStore = store
        let mediaType = UTType(typeIdentifier)?.preferredMIMEType
        return await withCheckedContinuation { continuation in
            // The provider URL is valid only inside this closure. Copying it to a scratch URL also
            // keeps large videos off the extension's limited heap.
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: .failure(nil))
                    return
                }
                do {
                    // The representation is valid only while this callback is running. Stage it
                    // directly into the protected app-group outbox here: the old scratch-then-
                    // stage path copied every byte twice and doubled the wait for large files.
                    let staged = try stagingStore.stage(
                        fileAt: url,
                        suggestedName: suggestedName ?? url.lastPathComponent,
                        mediaType: mediaType,
                        batchID: batchID,
                        maximumAcceptedBytes: maximumAcceptedBytes
                    )
                    continuation.resume(returning: .staged(staged))
                } catch {
                    continuation.resume(returning: .failure(
                        (error as? LocalizedError)?.errorDescription
                    ))
                }
            }
        }
    }

    private func loadURL(_ provider: NSItemProvider) async -> LoadedShare {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                guard let url = item as? URL, !url.isFileURL else {
                    continuation.resume(returning: .failure(nil))
                    return
                }
                continuation.resume(returning: .text(url.absoluteString))
            }
        }
    }

    private func loadText(_ provider: NSItemProvider) async -> LoadedShare {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.text.identifier) { item, _ in
                if let text = item as? String, !text.isEmpty {
                    continuation.resume(returning: .text(text))
                } else if let data = item as? Data,
                          let text = String(data: data, encoding: .utf8),
                          !text.isEmpty {
                    continuation.resume(returning: .text(text))
                } else {
                    continuation.resume(returning: .failure(nil))
                }
            }
        }
    }

    // MARK: Sending

    private func selectDestination(_ destination: SharedInboxDestination) {
        guard !hasFinished, !hasPublishedBatch, !hasRequestedDestination else { return }
        requestedDestination = destination
        updateSendButton()
        tableView.reloadData()
    }

    private func updateSendButton() {
        configureActionButton(
            title: requestedDestination.map { "Send to \($0.displayName)" } ?? "Select a chat",
            filled: true
        )
        actionButton.isEnabled = pendingShare != nil && requestedDestination != nil
            && !hasRequestedDestination
    }

    @objc private func editAttachments() {
        guard !hasFinished, !hasPublishedBatch, !isPresentingEditor,
              let pendingShare else { return }
        let editable = pendingShare.items.filter(ShareMediaEditor.supportsEditing)
        guard !editable.isEmpty else { return }
        if editable.count == 1 { editAttachment(editable[0]); return }
        let picker = UIAlertController(title: "Edit an attachment", message: nil, preferredStyle: .actionSheet)
        for item in editable {
            picker.addAction(UIAlertAction(title: item.displayName, style: .default) { [weak self, weak picker] _ in
                guard let self else { return }
                self.isPresentingEditor = true
                picker?.dismiss(animated: true) { [weak self] in
                    self?.isPresentingEditor = false
                    self?.editAttachment(item)
                }
            })
        }
        picker.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        picker.popoverPresentationController?.sourceView = secondaryActionButton
        picker.popoverPresentationController?.sourceRect = secondaryActionButton.bounds
        present(picker, animated: true)
    }

    private func editAttachment(_ item: SharedInboxItem) {
        guard let pendingShare, !isPresentingEditor, !hasPublishedBatch else { return }
        let remaining = SharedInboxPolicy.maximumBatchBytes
            - pendingShare.items.filter { $0.id != item.id }.reduce(0) { $0 + $1.byteCount }
        isPresentingEditor = true
        ShareMediaEditor.present(item: item, batchID: pendingShare.batchID, from: self,
                                 maximumAcceptedBytes: remaining) { [weak self] result in
            guard let self else { return }
            self.isPresentingEditor = false
            guard !self.hasFinished, !self.hasPublishedBatch,
                  let current = self.pendingShare, current.batchID == pendingShare.batchID else {
                if case .success(let replacement?) = result {
                    self.store.remove(item: replacement, in: pendingShare.batchID)
                }
                return
            }
            switch result {
            case .success(let replacement):
                guard let replacement else { return }
                guard let index = current.items.firstIndex(where: { $0.id == item.id }) else {
                    self.store.remove(item: replacement, in: pendingShare.batchID)
                    return
                }
                var items = current.items
                items[index] = replacement
                let edited = PendingShare(batchID: current.batchID, ownerAccountID: current.ownerAccountID,
                                          items: items, text: current.text, warning: current.warning)
                self.pendingShare = edited
                self.store.remove(item: item, in: current.batchID)
                self.refreshEditedPreview(replacement, index: index, batchID: current.batchID)
                self.presentPicker(for: edited)
                self.messageLabel.text = "Edit saved. Select your chat and tap Send."
            case .failure(let error):
                self.messageLabel.text = (error as? LocalizedError)?.errorDescription
                self.messageLabel.textColor = .systemOrange
            }
        }
    }

    private func refreshEditedPreview(_ item: SharedInboxItem, index: Int, batchID: UUID) {
        guard previewStrip.arrangedSubviews.indices.contains(index),
              let thumbnail = previewStrip.arrangedSubviews[index] as? UIImageView else { return }
        thumbnail.image = UIImage(systemName: item.mediaType == "application/pdf" ? "doc.richtext" : "checkmark.rectangle")
        thumbnail.contentMode = .scaleAspectFit
        thumbnail.tag = 1
        thumbnail.accessibilityLabel = "Edited \(item.displayName)"
        let stagingStore = store
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard item.mediaType.hasPrefix("image/"),
                      let url = try? stagingStore.fileURL(for: item, in: batchID),
                      let source = CGImageSourceCreateWithURL(url as CFURL,
                          [kCGImageSourceShouldCache: false] as CFDictionary),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                          kCGImageSourceThumbnailMaxPixelSize: 160,
                      ] as CFDictionary) else { return nil }
                return UIImage(cgImage: image)
            }.value
            guard let self, self.pendingShare?.batchID == batchID,
                  self.pendingShare?.items.contains(where: { $0.id == item.id }) == true else { return }
            if let image { thumbnail.image = image; thumbnail.contentMode = .scaleAspectFill }
        }
    }

    @objc private func sendTapped() {
        guard !hasFinished, !isPresentingEditor, sendTask == nil, let stagedShare = pendingShare,
              let destination = requestedDestination else { return }
        let text = SharedInboxPolicy.carriedText(captionInput.text)
        guard text.map({ !SharedInboxPolicy.exceedsTextLimit($0) }) ?? true else {
            messageLabel.text = SharedInboxError.textTooLong.errorDescription
            messageLabel.textColor = .systemOrange
            return
        }
        let pendingShare = PendingShare(batchID: stagedShare.batchID, ownerAccountID: stagedShare.ownerAccountID,
                                        items: stagedShare.items, text: text, warning: stagedShare.warning)
        self.pendingShare = pendingShare
        hasRequestedDestination = true
        queuedDestination = destination
        presentSending(destination: destination)
        sendTask = Task { [weak self] in
            guard let self else { return }
            defer { self.sendTask = nil }
            do {
                if (try? MessagingProcessBroker.shared.scope()) == nil {
                    let directory = try await MessagingProcessBroker.shared.authorizeShare()
                    guard directory.accountID == pendingShare.ownerAccountID else {
                        throw SharedInboxError.signedOut
                    }
                }
                try Task.checkCancellation()
                let currentScope = try MessagingProcessBroker.shared.scope()
                let scope = self.sendScope ?? currentScope
                guard scope == currentScope, scope.accountID == pendingShare.ownerAccountID else {
                    throw SharedInboxError.signedOut
                }
                self.sendScope = scope
                let inputSHA256 = try DirectShareSendRecord.inputFingerprint(
                    destination: destination, items: pendingShare.items, text: pendingShare.text
                )
                do {
                    // Every retry verifies this exact intent, even after publication. A same-ID
                    // receipt for changed content must never turn into success through a UI flag.
                    // Transfer staging ownership before the actor hop. Dismissal can happen
                    // after its durable commit but before this MainActor resumes.
                    self.isCommittingSend = true
                    do {
                        try await DirectShareSendCoordinator.shared.enqueue(
                            id: pendingShare.batchID, ownerAccountID: pendingShare.ownerAccountID,
                            destination: destination, items: pendingShare.items, text: pendingShare.text,
                            expectedScope: scope
                        )
                        self.hasPublishedBatch = true
                        self.isCommittingSend = false
                    } catch {
                        let ownership = try? MessagingProcessBroker.shared.containsEnqueued(
                            id: pendingShare.batchID, inputSHA256: inputSHA256, scope: scope
                        )
                        self.hasPublishedBatch = ownership == true
                        // Unreadable storage is still uncertain ownership. Keep staging rather
                        // than deleting bytes that a successfully replaced journal may own.
                        self.isCommittingSend = ownership == nil
                        if ownership == false, self.hasFinished || self.hasLeftShareSheet {
                            self.store.remove(batchID: pendingShare.batchID)
                        }
                        throw error
                    }
                }
                try Task.checkCancellation()
                try await DirectShareSendCoordinator.shared.send(id: pendingShare.batchID, expectedScope: scope)
                guard !self.hasFinished, !self.hasLeftShareSheet else { return }
                self.finish()
            } catch {
                guard !self.hasFinished, !self.hasLeftShareSheet else { return }
                self.hasRequestedDestination = false
                self.presentRetry(error: error)
            }
        }
    }

    private func presentRetry(error: Error) {
        spinner.stopAnimating()
        spinner.isHidden = true
        statusSymbol.isHidden = false
        statusSymbol.image = UIImage(systemName: "exclamationmark.circle")
        statusSymbol.tintColor = .systemOrange
        titleLabel.text = hasPublishedBatch || isCommittingSend ? "Send not confirmed" : "Could not prepare share"
        summaryLabel.text = isCommittingSend ? "Your send may have been saved"
            : (hasPublishedBatch ? "Your send is saved securely" : "Nothing was sent")
        messageLabel.text = (error as? LocalizedError)?.errorDescription
            ?? "Check your connection and try again."
        if isCommittingSend {
            messageLabel.text = "Kit Pay could not confirm whether this send was saved. Retry to check its status."
        } else if hasPublishedBatch {
            messageLabel.text = (messageLabel.text ?? "")
                + " You can retry here, or close and let Kit Pay retry when you next unlock it."
        }
        configureActionButton(title: "Retry send", filled: true)
        actionButton.isHidden = false
        actionButton.isEnabled = true
        configureSecondaryButton(title: "Close")
        secondaryActionButton.removeTarget(nil, action: nil, for: .allEvents)
        secondaryActionButton.addTarget(self, action: #selector(closePending), for: .touchUpInside)
        secondaryActionButton.isHidden = false
        secondaryActionButton.isEnabled = true
        cancelButton.isHidden = true
    }

    @objc private func closePending() {
        if hasPublishedBatch { finish() } else { cancel() }
    }

    /// Small provider previews are independent of durable file extraction and recipient choice.
    /// Never decode the full shared video/image simply to draw this strip.
    private func previewSelectedProviders(_ providers: [NSItemProvider], batchID: UUID) {
        let selected = Array(providers.filter { isProspectiveAttachment($0) }.prefix(4))
        var thumbnails: [UIImageView] = []
        for provider in selected {
            let thumbnail = UIImageView(image: UIImage(systemName: "doc"))
            thumbnail.contentMode = .scaleAspectFit
            thumbnail.tintColor = .secondaryLabel
            thumbnail.backgroundColor = .secondarySystemBackground
            thumbnail.layer.cornerRadius = 10
            thumbnail.clipsToBounds = true
            thumbnail.isAccessibilityElement = true
            thumbnail.accessibilityLabel = provider.suggestedName ?? "Shared attachment"
            thumbnail.heightAnchor.constraint(equalToConstant: 64).isActive = true
            previewStrip.addArrangedSubview(thumbnail)
            thumbnails.append(thumbnail)
        }
        previewStrip.isHidden = thumbnails.isEmpty
        // Extension memory is limited. Ask for at most two small provider previews at once,
        // regardless of how quickly a host can return full-size UIImage representations.
        Task { @MainActor [weak self] in
            await withTaskGroup(of: (Int, UIImage?).self) { group in
                var nextIndex = 0
                for index in 0..<min(2, selected.count) {
                    nextIndex += 1
                    group.addTask { (index, await Self.providerPreview(selected[index])) }
                }
                while let (index, preview) = await group.next() {
                    guard let self, !self.hasFinished, self.batchIDBeingStaged == batchID else {
                        group.cancelAll()
                        continue
                    }
                    if let preview, thumbnails[index].tag == 0 {
                        thumbnails[index].image = preview
                        thumbnails[index].contentMode = .scaleAspectFill
                    }
                    if nextIndex < selected.count {
                        let next = nextIndex
                        nextIndex += 1
                        group.addTask { (next, await Self.providerPreview(selected[next])) }
                    }
                }
            }
        }
    }

    nonisolated private static func providerPreview(_ provider: NSItemProvider) async -> UIImage? {
        let image: UIImage? = await withCheckedContinuation { continuation in
            provider.loadPreviewImage(options: [
                NSItemProviderPreferredImageSizeKey: NSValue(cgSize: CGSize(width: 128, height: 128)),
            ]) { value, _ in
                continuation.resume(returning: value as? UIImage)
            }
        }
        guard let image else { return nil }
        return image.preparingThumbnail(of: CGSize(width: 160, height: 160))
    }

    private func presentPreparingPicker(itemCount: Int) {
        titleLabel.text = "Choose a chat"
        summaryLabel.text = itemCount == 1 ? "Preparing your item…" : "Preparing your items…"
        messageLabel.text = "Choose a person or group, then tap Send."
        messageLabel.textColor = .secondaryLabel
        statusSymbol.isHidden = true
        spinner.isHidden = false
        spinner.startAnimating()
        configurePickerControls()
    }

    private func presentPicker(for pending: PendingShare) {
        spinner.stopAnimating()
        spinner.isHidden = true
        statusSymbol.isHidden = true
        titleLabel.text = "Choose a chat"
        summaryLabel.text = SharedInboxPolicy.summary(
            itemCount: pending.items.count, hasText: pending.text != nil
        )
        messageLabel.text = pending.warning ?? "Encrypted and sent directly to your chat."
        messageLabel.textColor = pending.warning == nil ? .secondaryLabel : .systemOrange
        if captionInput.isHidden { captionInput.text = pending.text ?? "" }
        captionInput.isHidden = false
        configurePickerControls()
    }

    private func configurePickerControls() {
        searchBar.isHidden = destinations.isEmpty
        tableView.isHidden = destinations.isEmpty
        emptyLabel.isHidden = !destinations.isEmpty
        emptyLabel.text = "No chats are available yet. Unlock Kit Pay to refresh your chats, then share again."
        actionButton.isHidden = destinations.isEmpty
        actionButton.removeTarget(nil, action: nil, for: .allEvents)
        actionButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        secondaryActionButton.isHidden = true
        setControlsEnabled(true)
        if let pendingShare, pendingShare.items.contains(where: ShareMediaEditor.supportsEditing) {
            configureSecondaryButton(title: "Edit attachments")
            secondaryActionButton.removeTarget(nil, action: nil, for: .allEvents)
            secondaryActionButton.addTarget(self, action: #selector(editAttachments), for: .touchUpInside)
            secondaryActionButton.isHidden = false
        }
        updateSendButton()
        tableView.reloadData()
    }

    private func presentSending(destination: SharedInboxDestination) {
        view.endEditing(true)
        cancelButton.isHidden = true
        searchBar.isHidden = true
        tableView.isHidden = true
        emptyLabel.isHidden = true
        statusSymbol.isHidden = true
        spinner.isHidden = false
        spinner.startAnimating()
        titleLabel.text = "Sending to \(destination.displayName)"
        summaryLabel.text = "Securing your message…"
        messageLabel.text = "Keep this sheet open until the send completes."
        messageLabel.textColor = .secondaryLabel
        actionButton.isHidden = true
        captionInput.isEditable = false
        secondaryActionButton.isHidden = true
        setControlsEnabled(false)
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    private func present(failure: String?) {
        hasPresentedFailure = true
        spinner.stopAnimating()
        spinner.isHidden = true
        statusSymbol.isHidden = false
        statusSymbol.image = UIImage(systemName: "exclamationmark.circle.fill")
        statusSymbol.tintColor = .systemRed
        titleLabel.text = "Could not share"
        summaryLabel.text = "Nothing was sent"
        messageLabel.text = failure ?? SharedInboxError.empty.errorDescription
        messageLabel.textColor = .secondaryLabel
        searchBar.isHidden = true
        tableView.isHidden = true
        emptyLabel.isHidden = true

        configureActionButton(title: "Close", filled: false)
        actionButton.removeTarget(nil, action: nil, for: .allEvents)
        actionButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        actionButton.isHidden = false
        actionButton.isEnabled = true
        secondaryActionButton.isHidden = true
    }

    @objc private func finish() {
        guard !hasFinished else { return }
        hasFinished = true
        sendTask?.cancel()
        sendTask = nil
        collectionTask?.cancel()
        collectionTask = nil
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    @objc private func cancel() {
        guard !hasFinished else { return }
        hasFinished = true
        sendTask?.cancel()
        sendTask = nil
        collectionTask?.cancel()
        collectionTask = nil
        if !hasPublishedBatch, !isCommittingSend, let batchIDBeingStaged {
            store.remove(batchID: batchIDBeingStaged)
        }
        extensionContext?.cancelRequest(withError: SharedInboxError.empty)
    }

    // MARK: Interface

    private func buildInterface() {
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 0, height: 620)

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Share to Kit Pay"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()

        statusSymbol.translatesAutoresizingMaskIntoConstraints = false
        statusSymbol.contentMode = .scaleAspectFit
        statusSymbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 42,
            weight: .semibold
        )
        statusSymbol.isHidden = true

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.text = "Preparing your items…"
        summaryLabel.font = .preferredFont(forTextStyle: .headline)
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.textAlignment = .center
        summaryLabel.numberOfLines = 2

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.text = "Large files can take a moment."
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center

        previewStrip.axis = .horizontal
        previewStrip.spacing = 8
        previewStrip.distribution = .fillEqually
        previewStrip.isHidden = true
        captionInput.font = .preferredFont(forTextStyle: .body)
        captionInput.adjustsFontForContentSizeCategory = true
        captionInput.backgroundColor = .secondarySystemBackground
        captionInput.layer.cornerRadius = 10
        captionInput.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        captionInput.accessibilityLabel = "Message or caption"
        captionInput.isHidden = true
        captionInput.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let statusStack = UIStackView(arrangedSubviews: [
            spinner,
            statusSymbol,
            previewStrip,
            captionInput,
            summaryLabel,
            messageLabel,
        ])
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.axis = .vertical
        statusStack.alignment = .fill
        statusStack.spacing = 9

        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.placeholder = "Search chats"
        searchBar.searchBarStyle = .minimal
        searchBar.autocapitalizationType = .none
        searchBar.delegate = self
        searchBar.isHidden = true

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(
            SharedInboxDestinationCell.self,
            forCellReuseIdentifier: SharedInboxDestinationCell.reuseIdentifier
        )
        tableView.keyboardDismissMode = .onDrag
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 62
        tableView.isHidden = true

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .preferredFont(forTextStyle: .subheadline)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.isHidden = true

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        actionButton.isHidden = true

        secondaryActionButton.translatesAutoresizingMaskIntoConstraints = false
        secondaryActionButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        secondaryActionButton.isHidden = true

        // A stack collapses whichever action is hidden, so single-button states keep the primary
        // action pinned to the bottom without conditional constraints.
        let actionStack = UIStackView(arrangedSubviews: [actionButton, secondaryActionButton])
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.axis = .vertical
        actionStack.alignment = .fill
        actionStack.spacing = 4

        let divider = UIView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.backgroundColor = .separator

        [cancelButton, titleLabel, divider, statusStack, searchBar, tableView, emptyLabel, actionStack]
            .forEach(view.addSubview)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            cancelButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            cancelButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 10),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            titleLabel.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: cancelButton.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -70),

            divider.topAnchor.constraint(equalTo: cancelButton.bottomAnchor, constant: 7),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            statusStack.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 18),
            statusStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            statusStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),

            searchBar.topAnchor.constraint(equalTo: statusStack.bottomAnchor, constant: 8),
            searchBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
            searchBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8),

            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: actionStack.topAnchor, constant: -8),

            emptyLabel.topAnchor.constraint(equalTo: statusStack.bottomAnchor, constant: 36),
            emptyLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 28),
            emptyLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -28),

            actionStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            actionStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
            actionStack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -14),
            actionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
            secondaryActionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    private func configureActionButton(title: String, filled: Bool) {
        var configuration = filled
            ? UIButton.Configuration.filled()
            : UIButton.Configuration.gray()
        configuration.title = title
        configuration.cornerStyle = .large
        configuration.baseBackgroundColor = filled
            ? UIColor(red: 0.05, green: 0.56, blue: 0.31, alpha: 1)
            : .secondarySystemBackground
        configuration.baseForegroundColor = filled ? .white : .label
        actionButton.configuration = configuration
    }

    private func configureSecondaryButton(title: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.baseForegroundColor = .secondaryLabel
        secondaryActionButton.configuration = configuration
    }

    private func setControlsEnabled(_ enabled: Bool) {
        cancelButton.isEnabled = enabled
        searchBar.isUserInteractionEnabled = enabled
        tableView.isUserInteractionEnabled = enabled
        actionButton.isEnabled = enabled
        secondaryActionButton.isEnabled = enabled
    }
}

// MARK: - Destination table

extension ShareViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { 3 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        destinations(in: section).count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard !destinations(in: section).isEmpty else { return nil }
        switch section {
        case 0: return "Recent"
        case 1: return "Contacts on Kit Pay"
        default: return "Groups"
        }
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let destination = destinations(in: indexPath.section)[indexPath.row]
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: SharedInboxDestinationCell.reuseIdentifier,
            for: indexPath
        ) as? SharedInboxDestinationCell else { return UITableViewCell() }
        cell.configure(destination)
        cell.accessoryType = requestedDestination?.id == destination.id ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let rows = destinations(in: indexPath.section)
        guard rows.indices.contains(indexPath.row) else { return }
        selectDestination(rows[indexPath.row])
    }

    private func destinations(in section: Int) -> [SharedInboxDestination] {
        filteredDestinations.filter {
            switch section {
            case 0:
                // Every direct row is one of the five recent conversations. New snapshots also
                // mark recent groups; old snapshots keep those groups in the Groups section.
                $0.isRecent == true || $0.kind == .direct
            case 1: $0.kind == .contact
            default: $0.kind == .group && $0.isRecent != true
            }
        }
    }
}

/// A destination always paints a local person/group glyph in its first frame, then replaces it
/// with the public profile or group photo when the bounded fetch succeeds. A failed or offline
/// fetch is purely cosmetic and never delays tapping the row or queueing the share.
private final class SharedInboxDestinationCell: UITableViewCell {
    static let reuseIdentifier = "destination"

    private static let imageCache = NSCache<NSURL, UIImage>()
    private static let maximumAvatarBytes = 6 * 1_024 * 1_024
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        return URLSession(configuration: configuration)
    }()

    private var representedDestinationID: String?
    private var avatarTask: Task<Void, Never>?

    override func prepareForReuse() {
        super.prepareForReuse()
        representedDestinationID = nil
        avatarTask?.cancel()
        avatarTask = nil
    }

    func configure(_ destination: SharedInboxDestination) {
        representedDestinationID = destination.id
        avatarTask?.cancel()
        avatarTask = nil
        apply(destination, avatar: nil)

        guard let rawURL = SharedInboxPolicy.destinationAvatarURL(destination.avatarURL),
              let url = URL(string: rawURL)
        else { return }
        if let cached = Self.imageCache.object(forKey: url as NSURL) {
            apply(destination, avatar: cached)
            return
        }

        avatarTask = Task { [weak self] in
            guard let avatar = await Self.loadAvatar(from: url), !Task.isCancelled else { return }
            Self.imageCache.setObject(avatar, forKey: url as NSURL)
            guard self?.representedDestinationID == destination.id else { return }
            self?.apply(destination, avatar: avatar)
        }
    }

    private func apply(_ destination: SharedInboxDestination, avatar: UIImage?) {
        var content = defaultContentConfiguration()
        content.text = destination.displayName
        switch destination.kind {
        case .group:
            content.secondaryText = "Group · \(destination.memberCount ?? 1) members"
            content.image = avatar ?? UIImage(systemName: "person.3.fill")
        case .direct:
            content.secondaryText = "Recent chat"
            content.image = avatar ?? UIImage(systemName: "person.crop.circle.fill")
        case .contact:
            content.secondaryText = "Kit Pay contact"
            content.image = avatar ?? UIImage(systemName: "person.crop.circle.fill")
        }
        content.imageProperties.maximumSize = CGSize(width: 42, height: 42)
        content.imageProperties.reservedLayoutSize = CGSize(width: 42, height: 42)
        content.imageProperties.cornerRadius = 21
        content.imageProperties.tintColor = avatar == nil
            ? UIColor(red: 0.05, green: 0.56, blue: 0.31, alpha: 1)
            : nil
        content.textProperties.numberOfLines = 1
        contentConfiguration = content
        accessoryType = .disclosureIndicator
        selectionStyle = .default
        accessibilityLabel = destination.displayName
        accessibilityValue = content.secondaryText
        accessibilityHint = "Queues the shared items for this chat"
    }

    private static func loadAvatar(from url: URL) async -> UIImage? {
        guard let (data, response) = try? await session.data(from: url),
              !Task.isCancelled,
              !data.isEmpty,
              data.count <= maximumAvatarBytes,
              (response as? HTTPURLResponse).map({ (200 ..< 300).contains($0.statusCode) })
                ?? true
        else { return nil }
        return await Task.detached(priority: .utility) {
            downsampleAvatar(data)
        }.value
    }

    nonisolated private static func downsampleAvatar(_ data: Data) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            sourceOptions as CFDictionary
        ) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 128,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else { return nil }
        return UIImage(cgImage: image)
    }
}

extension ShareViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredDestinations = query.isEmpty
            ? destinations
            : destinations.filter { $0.displayName.localizedStandardContains(query) }
        tableView.reloadData()
        tableView.backgroundView = filteredDestinations.isEmpty
            ? searchEmptyBackground
            : nil
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    private var searchEmptyBackground: UIView {
        let label = UILabel()
        label.text = "No matching chats"
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }
}
