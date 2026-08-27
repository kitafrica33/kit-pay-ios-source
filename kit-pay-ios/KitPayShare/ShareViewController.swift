import UIKit
import UniformTypeIdentifiers

/// Kit Pay's entry in the system share sheet.
///
/// A share extension cannot launch its containing app, and it must never inherit the app's
/// identity keys or authenticated store. Kit Pay therefore publishes a small, account-bound list
/// of chat names into the protected app-group container. This controller stages the selected
/// bytes, lets the customer choose a direct chat or group here, and records that requested route.
/// The containing app revalidates it and moves the share into the visible composer the next time
/// Kit Pay becomes active. Until then the extension says exactly that it is queued; it never
/// closes optimistically and implies that an unsent file was delivered.
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

    private var pendingShare: PendingShare?
    private var destinations: [SharedInboxDestination] = []
    private var filteredDestinations: [SharedInboxDestination] = []
    private var batchIDBeingStaged: UUID?
    private var hasPublishedBatch = false
    private var hasPresentedFailure = false
    private var hasFinished = false
    private var isCollecting = false
    private var collectionTask: Task<Void, Never>?

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

        var items: [SharedInboxItem] = []
        var textFragments: [String] = []
        var firstFailure: String?
        var skippedCount = 0
        let providers = itemProviders()

        if providers.count > SharedInboxPolicy.maximumItems {
            skippedCount += providers.count - SharedInboxPolicy.maximumItems
        }

        for provider in providers.prefix(SharedInboxPolicy.maximumItems) {
            guard !Task.isCancelled, !hasFinished else {
                store.remove(batchID: batchID)
                batchIDBeingStaged = nil
                isCollecting = false
                return
            }
            let loaded = await load(provider)
            guard !Task.isCancelled, !hasFinished else {
                if case .file(let url, _, _) = loaded {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                }
                store.remove(batchID: batchID)
                batchIDBeingStaged = nil
                isCollecting = false
                return
            }
            switch loaded {
            case .file(let url, let suggestedName, let mediaType):
                do {
                    // `collectShare` is main-actor isolated with this view controller. Copying a
                    // 200 MiB video here would freeze the extension long enough for iOS to kill
                    // it, recreating the original open-then-exit bug. The provider scratch file
                    // is private to this task and the app-group store is filesystem-only.
                    let usedBytes = items.reduce(into: 0) { $0 += $1.byteCount }
                    let remainingBytes = SharedInboxPolicy.maximumBatchBytes - usedBytes
                    let item = try await Task.detached(priority: .userInitiated) {
                        defer {
                            try? FileManager.default.removeItem(
                                at: url.deletingLastPathComponent()
                            )
                        }
                        return try SharedInboxStore().stage(
                            fileAt: url,
                            suggestedName: suggestedName,
                            mediaType: mediaType,
                            batchID: batchID,
                            maximumAcceptedBytes: remainingBytes
                        )
                    }.value
                    guard !Task.isCancelled, !hasFinished else {
                        // Cancellation can race the detached copy. Remove again after it finishes
                        // so the copy cannot recreate a directory already removed by Cancel.
                        store.remove(batchID: batchID)
                        batchIDBeingStaged = nil
                        isCollecting = false
                        return
                    }
                    items.append(item)
                } catch {
                    skippedCount += 1
                    firstFailure = firstFailure
                        ?? (error as? LocalizedError)?.errorDescription
                }
            case .text(let value):
                textFragments.append(value)
            case .none:
                skippedCount += 1
                firstFailure = firstFailure ?? SharedInboxError.unreadable.errorDescription
            }
        }

        let text = SharedInboxPolicy.normalizedText(
            textFragments.joined(separator: "\n").nilWhenBlank
        )
        guard !Task.isCancelled, !hasFinished else {
            store.remove(batchID: batchID)
            batchIDBeingStaged = nil
            isCollecting = false
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
        destinations = store.destinations(forAccountID: ownerAccountID)
        filteredDestinations = destinations
        isCollecting = false
        presentPicker(for: pending)
    }

    private func itemProviders() -> [NSItemProvider] {
        let inputItems = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        return inputItems.flatMap { $0.attachments ?? [] }
    }

    private enum LoadedShare {
        case file(URL, suggestedName: String?, mediaType: String?)
        case text(String)
        case none
    }

    private func load(_ provider: NSItemProvider) async -> LoadedShare {
        if let type = fileTypeIdentifier(for: provider) {
            return await loadFile(provider, typeIdentifier: type)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return await loadFileURL(provider)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            return await loadURL(provider)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            return await loadText(provider)
        }
        return .none
    }

    /// Some document providers expose only `public.file-url`, without a separate concrete data
    /// UTI. Copy that security-scoped/provider-owned URL before its callback ends, just like
    /// `loadFileRepresentation`, so generic files from Files do not fall through as unusable links.
    private func loadFileURL(_ provider: NSItemProvider) async -> LoadedShare {
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let url = item as? URL, url.isFileURL else {
                    continuation.resume(returning: .none)
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
                let scratch = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    .appendingPathComponent(url.lastPathComponent, isDirectory: false)
                do {
                    try FileManager.default.createDirectory(
                        at: scratch.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.copyItem(at: url, to: scratch)
                    try FileManager.default.setAttributes(
                        [.protectionKey: FileProtectionType.complete],
                        ofItemAtPath: scratch.path
                    )
                } catch {
                    try? FileManager.default.removeItem(at: scratch.deletingLastPathComponent())
                    continuation.resume(returning: .none)
                    return
                }
                let mediaType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                continuation.resume(returning: .file(
                    scratch,
                    suggestedName: suggestedName ?? url.lastPathComponent,
                    mediaType: mediaType
                ))
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
        typeIdentifier: String
    ) async -> LoadedShare {
        let suggestedName = provider.suggestedName
        let mediaType = UTType(typeIdentifier)?.preferredMIMEType
        return await withCheckedContinuation { continuation in
            // The provider URL is valid only inside this closure. Copying it to a scratch URL also
            // keeps large videos off the extension's limited heap.
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: .none)
                    return
                }
                let scratch = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    .appendingPathComponent(url.lastPathComponent, isDirectory: false)
                do {
                    try FileManager.default.createDirectory(
                        at: scratch.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.copyItem(at: url, to: scratch)
                    try FileManager.default.setAttributes(
                        [.protectionKey: FileProtectionType.complete],
                        ofItemAtPath: scratch.path
                    )
                } catch {
                    try? FileManager.default.removeItem(
                        at: scratch.deletingLastPathComponent()
                    )
                    continuation.resume(returning: .none)
                    return
                }
                continuation.resume(returning: .file(
                    scratch,
                    suggestedName: suggestedName ?? url.lastPathComponent,
                    mediaType: mediaType
                ))
            }
        }
    }

    private func loadURL(_ provider: NSItemProvider) async -> LoadedShare {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                guard let url = item as? URL, !url.isFileURL else {
                    continuation.resume(returning: .none)
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
                    continuation.resume(returning: .none)
                }
            }
        }
    }

    // MARK: Queueing

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
        presentQueued(destination: destination)
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
        setControlsEnabled(true)
        tableView.reloadData()
    }

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
            messageLabel.text = "Open Kit Pay within 24 hours to review it and tap Send."
        } else {
            titleLabel.text = "Saved in Kit Pay"
            summaryLabel.text = "Queued securely on this iPhone"
            messageLabel.text = "Open Kit Pay within 24 hours to choose a person or group, review it, and tap Send."
        }
        messageLabel.textColor = .secondaryLabel

        configureActionButton(title: "Done", filled: true)
        actionButton.removeTarget(nil, action: nil, for: .allEvents)
        actionButton.addTarget(self, action: #selector(finish), for: .touchUpInside)
        actionButton.isHidden = false
        actionButton.isEnabled = true
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
    }

    @objc private func queueWithoutDestination() {
        publish(to: nil)
    }

    @objc private func finish() {
        guard !hasFinished else { return }
        hasFinished = true
        collectionTask?.cancel()
        collectionTask = nil
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    @objc private func cancel() {
        guard !hasFinished else { return }
        hasFinished = true
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
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "destination")
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

        let divider = UIView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.backgroundColor = .separator

        [cancelButton, titleLabel, divider, statusStack, searchBar, tableView, emptyLabel, actionButton]
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
            tableView.bottomAnchor.constraint(equalTo: actionButton.topAnchor, constant: -8),

            emptyLabel.topAnchor.constraint(equalTo: statusStack.bottomAnchor, constant: 36),
            emptyLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 28),
            emptyLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -28),

            actionButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            actionButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
            actionButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -14),
            actionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
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

    private func setControlsEnabled(_ enabled: Bool) {
        cancelButton.isEnabled = enabled
        searchBar.isUserInteractionEnabled = enabled
        tableView.isUserInteractionEnabled = enabled
        actionButton.isEnabled = enabled
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
        let cell = tableView.dequeueReusableCell(withIdentifier: "destination", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = destination.displayName
        switch destination.kind {
        case .group:
            content.secondaryText = "Group · \(destination.memberCount ?? 1) members"
            content.image = UIImage(systemName: "person.3.fill")
        case .direct:
            content.secondaryText = "Recent chat"
            content.image = UIImage(systemName: "bubble.left.and.bubble.right.fill")
        case .contact:
            content.secondaryText = "Kit Pay contact"
            content.image = UIImage(systemName: "person.crop.circle.fill")
        }
        content.imageProperties.tintColor = UIColor(red: 0.05, green: 0.56, blue: 0.31, alpha: 1)
        content.textProperties.numberOfLines = 1
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        cell.accessibilityLabel = destination.displayName
        cell.accessibilityValue = content.secondaryText
        cell.accessibilityHint = "Queues the shared items for this chat"
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let rows = destinations(in: indexPath.section)
        guard rows.indices.contains(indexPath.row) else { return }
        publish(to: rows[indexPath.row])
    }

    private func destinations(in section: Int) -> [SharedInboxDestination] {
        filteredDestinations.filter {
            switch section {
            case 0: $0.kind == .direct
            case 1: $0.kind == .contact
            default: $0.kind == .group
            }
        }
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

private extension String {
    var nilWhenBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
