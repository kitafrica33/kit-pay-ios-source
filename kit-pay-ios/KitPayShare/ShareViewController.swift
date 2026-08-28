import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Kit Pay's entry in the system share sheet.
///
/// A share extension cannot rely on launching its containing app, and it must never inherit the
/// app's identity keys or authenticated store. Kit Pay therefore publishes a small, account-bound
/// list of chat names into the protected app-group container. This controller stages the selected
/// bytes, lets the customer choose a direct chat or group here, and records that requested route.
/// The containing app revalidates it and moves the share into the visible composer the next time
/// Kit Pay becomes active. After queueing, the extension asks iOS to bring Kit Pay forward and
/// completes only once iOS accepts that request (`KitShareHandoffAttempt` holds the rules); if
/// iOS declines or never answers, the sheet stays up saying exactly that the share is queued,
/// with an explicit retry — it never closes optimistically and implies that an unsent file was
/// delivered.
final class ShareViewController: UIViewController {
    private struct PendingShare {
        let batchID: UUID
        let ownerAccountID: String
        let items: [SharedInboxItem]
        let text: String?
        let warning: String?
    }

    private let store = SharedInboxStore()

    private let cancelButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusSymbol = UIImageView()
    private let summaryLabel = UILabel()
    private let messageLabel = UILabel()
    private let searchBar = UISearchBar()
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private let secondaryActionButton = UIButton(type: .system)

    private var pendingShare: PendingShare?
    private var destinations: [SharedInboxDestination] = []
    private var filteredDestinations: [SharedInboxDestination] = []
    /// A destination tap is accepted immediately, even while a large provider file is still
    /// being copied into the durable app-group outbox. The manifest is committed as soon as that
    /// copy finishes; a second tap can never create a second batch.
    private var requestedDestination: SharedInboxDestination?
    private var hasRequestedDestination = false
    private var batchIDBeingStaged: UUID?
    private var hasPublishedBatch = false
    private var hasPresentedFailure = false
    private var hasFinished = false
    private var isCollecting = false
    private var collectionTask: Task<Void, Never>?
    private var handoffPhase: KitShareHandoffAttempt.Phase = .queued
    private var handoffTimeoutWorkItem: DispatchWorkItem?
    private var queuedDestination: SharedInboxDestination?

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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
        // A swipe-to-dismiss before a choice is not a reason to retain plaintext. A published
        // batch is different: it is a deliberate queue operation and must survive dismissal.
        if !hasFinished, !hasPublishedBatch {
            collectionTask?.cancel()
            if let batchIDBeingStaged { store.remove(batchID: batchIDBeingStaged) }
        }
    }

    // MARK: Collecting

    private func collectShare() async {
        let batchID = UUID()
        batchIDBeingStaged = batchID

        // The app publishes only an opaque account UUID into the app group. Binding the manifest
        // to it prevents a share staged for one signed-in person from crossing a later sign-out.
        guard let ownerAccountID = store.activeAccountID() else {
            store.remove(batchID: batchID)
            batchIDBeingStaged = nil
            isCollecting = false
            present(failure: SharedInboxError.signedOut.errorDescription)
            return
        }

        destinations = store.destinations(forAccountID: ownerAccountID)
        filteredDestinations = destinations

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
        if hasRequestedDestination {
            publish(to: requestedDestination)
        } else {
            presentPicker(for: pending)
        }
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
                    let staged = try SharedInboxStore().stage(
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
                    let staged = try SharedInboxStore().stage(
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

    // MARK: Queueing

    /// Records the route on the first tap. If provider I/O is still running, the user gets an
    /// immediate committed-looking progress state while that one background copy finishes; if it
    /// is already ready, publishing remains the same synchronous, atomic manifest write as before.
    private func requestPublish(to destination: SharedInboxDestination?) {
        guard !hasFinished, !hasPublishedBatch, !hasRequestedDestination else { return }
        hasRequestedDestination = true
        requestedDestination = destination
        if pendingShare != nil {
            publish(to: destination)
        } else {
            presentPreparingQueue(destination: destination)
        }
    }

    private func publish(to destination: SharedInboxDestination?) {
        guard !hasFinished, !hasPublishedBatch, let pendingShare else { return }
        view.endEditing(true)
        setControlsEnabled(false)

        guard store.activeAccountID() == pendingShare.ownerAccountID else {
            store.remove(batchID: pendingShare.batchID)
            batchIDBeingStaged = nil
            self.pendingShare = nil
            present(failure: "Your Kit Pay account changed. Open Kit Pay and share again.")
            return
        }

        do {
            try store.finishBatch(
                id: pendingShare.batchID,
                items: pendingShare.items,
                text: pendingShare.text,
                ownerAccountID: pendingShare.ownerAccountID,
                receivedAt: Date(),
                destination: destination?.request
            )
        } catch {
            store.remove(batchID: pendingShare.batchID)
            batchIDBeingStaged = nil
            self.pendingShare = nil
            present(failure: (error as? LocalizedError)?.errorDescription
                ?? SharedInboxError.unavailable.errorDescription)
            return
        }

        hasPublishedBatch = true
        self.pendingShare = nil
        queuedDestination = destination
        // Do not complete the extension until iOS has accepted the request to open Kit Pay.
        // Completing first tears down this process and races (usually wins against) the open URL
        // request, which looks to the customer like the share sheet simply disappeared. The first
        // attempt is automatic; if iOS declines it, the queued state below offers an explicit
        // user-initiated retry. The batch is already durable, so "Not now" is also safe.
        handleHandoff(.attemptRequested(canOpen: canOpenHostApp))
    }

    // MARK: Hand-off to the containing app

    private var canOpenHostApp: Bool {
        KitShareHandoffLink.url != nil && extensionContext != nil
    }

    /// Single funnel for the hand-off attempt: every trigger (automatic post-publish, retry tap,
    /// open completion, timeout, "Not now") becomes an event, and only the pure phase machine
    /// decides what happens, so a late or duplicate callback can never double-complete the
    /// request or dismiss the sheet underneath the customer.
    private func handleHandoff(_ event: KitShareHandoffAttempt.Event) {
        if case .openResolved = event {
            handoffTimeoutWorkItem?.cancel()
            handoffTimeoutWorkItem = nil
        }
        let step = KitShareHandoffAttempt.decide(phase: handoffPhase, event: event)
        handoffPhase = step.phase
        switch step.decision {
        case .ignore:
            break
        case .attemptOpen:
            performHostAppOpen()
        case .offerManualHandoff:
            presentQueued(destination: queuedDestination)
        case .finishExtension:
            finish()
        }
    }

    /// UIKit half of one attempt; every outcome reports back through `handleHandoff`.
    private func performHostAppOpen() {
        guard let url = KitShareHandoffLink.url, let extensionContext else {
            handleHandoff(.openResolved(opened: false))
            return
        }
        presentOpeningHostApp()
        // The completion handler is contractual, but an extension should never leave a customer
        // staring at an endless spinner if SpringBoard fails to answer during a transition. A
        // late acceptance after this fires is ignored by the phase machine.
        let timeout = DispatchWorkItem { [weak self] in
            self?.handleHandoff(.openResolved(opened: false))
        }
        handoffTimeoutWorkItem?.cancel()
        handoffTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + KitShareHandoffAttempt.openTimeout,
            execute: timeout
        )
        extensionContext.open(url) { [weak self] opened in
            DispatchQueue.main.async {
                self?.handleHandoff(.openResolved(opened: opened))
            }
        }
    }

    @objc private func retryHostAppOpen() {
        handleHandoff(.attemptRequested(canOpen: canOpenHostApp))
    }

    @objc private func finishWithoutOpening() {
        handleHandoff(.notNowTapped)
    }

    private func presentPreparingPicker(itemCount: Int) {
        titleLabel.text = "Choose a chat"
        summaryLabel.text = itemCount == 1 ? "Preparing your item…" : "Preparing your items…"
        messageLabel.text = destinations.isEmpty
            ? "Your share is being saved securely. You can choose its chat in Kit Pay."
            : "Choose now. Kit Pay will finish saving the share securely in the background."
        messageLabel.textColor = .secondaryLabel
        statusSymbol.isHidden = true
        spinner.isHidden = false
        spinner.startAnimating()
        searchBar.isHidden = destinations.isEmpty
        tableView.isHidden = destinations.isEmpty
        emptyLabel.isHidden = !destinations.isEmpty
        emptyLabel.text = "No recent chats are available here yet.\nYou can choose a chat in Kit Pay."
        actionButton.isHidden = false
        configureActionButton(title: "Choose in Kit Pay later", filled: false)
        actionButton.removeTarget(nil, action: nil, for: .allEvents)
        actionButton.addTarget(self, action: #selector(queueWithoutDestination), for: .touchUpInside)
        secondaryActionButton.isHidden = true
        setControlsEnabled(true)
        tableView.reloadData()
    }

    private func presentPreparingQueue(destination: SharedInboxDestination?) {
        view.endEditing(true)
        titleLabel.text = destination.map { "Adding to \($0.displayName)" } ?? "Saving in Kit Pay"
        summaryLabel.text = "Preparing your share…"
        messageLabel.text = "It is being queued securely on this iPhone."
        messageLabel.textColor = .secondaryLabel
        statusSymbol.isHidden = true
        spinner.isHidden = false
        spinner.startAnimating()
        searchBar.isHidden = true
        tableView.isHidden = true
        emptyLabel.isHidden = true
        actionButton.isHidden = true
        secondaryActionButton.isHidden = true
        setControlsEnabled(false)
        cancelButton.isEnabled = true
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    private func presentPicker(for pending: PendingShare) {
        spinner.stopAnimating()
        spinner.isHidden = true
        statusSymbol.isHidden = true
        titleLabel.text = "Choose a chat"
        summaryLabel.text = SharedInboxPolicy.summary(
            itemCount: pending.items.count,
            hasText: pending.text != nil
        )
        messageLabel.text = pending.warning ?? (destinations.isEmpty
            ? "Your share is safe. Open Kit Pay once to refresh your chats, or choose it there later."
            : "Select a person or group. You will review the share in Kit Pay before sending.")
        messageLabel.textColor = pending.warning == nil ? .secondaryLabel : .systemOrange

        searchBar.isHidden = destinations.isEmpty
        tableView.isHidden = destinations.isEmpty
        emptyLabel.isHidden = !destinations.isEmpty
        emptyLabel.text = "No recent chats are available here yet.\nYou can choose a chat in Kit Pay."
        actionButton.isHidden = false
        configureActionButton(title: "Choose in Kit Pay later", filled: false)
        actionButton.removeTarget(nil, action: nil, for: .allEvents)
        actionButton.addTarget(self, action: #selector(queueWithoutDestination), for: .touchUpInside)
        secondaryActionButton.isHidden = true
        setControlsEnabled(true)
        tableView.reloadData()
    }

    /// Progress state while iOS decides whether to bring Kit Pay forward. Cancel is hidden the
    /// moment the batch is published: cancelling the extension request now would not unpublish it.
    private func presentOpeningHostApp() {
        cancelButton.isHidden = true
        searchBar.isHidden = true
        tableView.isHidden = true
        emptyLabel.isHidden = true
        statusSymbol.isHidden = true
        spinner.isHidden = false
        spinner.startAnimating()
        titleLabel.text = "Opening Kit Pay"
        summaryLabel.text = "Queued securely on this iPhone"
        if let destination = queuedDestination {
            messageLabel.text = "Your share is ready for \(destination.displayName). Review it in Kit Pay and tap Send."
        } else {
            messageLabel.text = "Your share is ready. Choose a person or group in Kit Pay."
        }
        messageLabel.textColor = .secondaryLabel
        actionButton.isHidden = true
        secondaryActionButton.isHidden = true
    }

    /// The durable-queue state, doubling as the manual hand-off fallback when iOS declines or
    /// never answers the open request: an explicit retry stays available, and "Not now" simply
    /// completes because the batch survives in the container either way.
    private func presentQueued(destination: SharedInboxDestination?) {
        cancelButton.isHidden = true
        searchBar.isHidden = true
        tableView.isHidden = true
        emptyLabel.isHidden = true
        spinner.stopAnimating()
        spinner.isHidden = true
        statusSymbol.isHidden = false
        statusSymbol.image = UIImage(systemName: "checkmark.circle.fill")
        statusSymbol.tintColor = UIColor(red: 0.05, green: 0.56, blue: 0.31, alpha: 1)

        if let destination {
            titleLabel.text = "Ready for \(destination.displayName)"
            summaryLabel.text = "Queued securely on this iPhone"
            messageLabel.text = "Tap Continue to review it in Kit Pay and send. If Kit Pay does not open, tap Not now — your share will be waiting there for 24 hours."
        } else {
            titleLabel.text = "Saved in Kit Pay"
            summaryLabel.text = "Queued securely on this iPhone"
            messageLabel.text = "Tap Continue to choose a person or group in Kit Pay. If Kit Pay does not open, tap Not now — your share will be waiting there for 24 hours."
        }
        messageLabel.textColor = .secondaryLabel

        configureActionButton(title: "Continue in Kit Pay", filled: true)
        actionButton.removeTarget(nil, action: nil, for: .allEvents)
        actionButton.addTarget(self, action: #selector(retryHostAppOpen), for: .touchUpInside)
        actionButton.isHidden = false
        actionButton.isEnabled = true
        configureSecondaryButton(title: "Not now")
        secondaryActionButton.removeTarget(nil, action: nil, for: .allEvents)
        secondaryActionButton.addTarget(
            self,
            action: #selector(finishWithoutOpening),
            for: .touchUpInside
        )
        secondaryActionButton.isHidden = false
        secondaryActionButton.isEnabled = true
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

    @objc private func queueWithoutDestination() {
        requestPublish(to: nil)
    }

    @objc private func finish() {
        guard !hasFinished else { return }
        hasFinished = true
        handoffPhase = .finished
        handoffTimeoutWorkItem?.cancel()
        handoffTimeoutWorkItem = nil
        collectionTask?.cancel()
        collectionTask = nil
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    @objc private func cancel() {
        guard !hasFinished else { return }
        hasFinished = true
        handoffPhase = .finished
        handoffTimeoutWorkItem?.cancel()
        handoffTimeoutWorkItem = nil
        collectionTask?.cancel()
        collectionTask = nil
        if !hasPublishedBatch, let batchIDBeingStaged {
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

        let statusStack = UIStackView(arrangedSubviews: [
            spinner,
            statusSymbol,
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
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let rows = destinations(in: indexPath.section)
        guard rows.indices.contains(indexPath.row) else { return }
        requestPublish(to: rows[indexPath.row])
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

    private static func downsampleAvatar(_ data: Data) -> UIImage? {
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
