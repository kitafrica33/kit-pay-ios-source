import UIKit
import UniformTypeIdentifiers

/// Kit Pay's entry in the system share sheet.
///
/// The extension deliberately does almost nothing. It cannot send a message: the account's
/// identity keys and the encrypted local store belong to the app and stay there, and an extension
/// that could reach them would be a second copy of the most sensitive thing Kit Pay owns. So it
/// copies what the user chose into the shared container, brings the app forward, and lets the app
/// ask the only question that is left — which chat.
///
/// It shows a small card while it copies, because "share to Kit Pay" on a long video is not
/// instant and a share sheet that appears to hang is a share people stop trusting.
final class ShareViewController: UIViewController {
    private let card = UIView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private lazy var closeButton = UIButton(type: .system)

    private var hasFinished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasFinished else { return }
        Task { await collectShare() }
    }

    // MARK: Collecting

    private func collectShare() async {
        let batchID = UUID()
        let store = SharedInboxStore()
        // The app publishes only an opaque account UUID into the app group. Binding the manifest
        // to it prevents a share staged for one signed-in person from crossing a later sign-out
        // and being offered to the next person who uses this device.
        guard let ownerAccountID = store.activeAccountID() else {
            present(failure: SharedInboxError.signedOut.errorDescription)
            return
        }
        var items: [SharedInboxItem] = []
        var textFragments: [String] = []
        /// Why the first thing that could not be shared could not be shared. Only ever surfaced
        /// when NOTHING made it through — a share of five photos and one oversized video is a
        /// share of five photos, and interrupting it to complain would help nobody.
        var firstFailure: String?

        for provider in itemProviders() {
            guard items.count < SharedInboxPolicy.maximumItems else { break }
            switch await load(provider) {
            case .file(let url, let suggestedName, let mediaType):
                do {
                    items.append(try store.stage(
                        fileAt: url,
                        suggestedName: suggestedName,
                        mediaType: mediaType,
                        batchID: batchID
                    ))
                } catch {
                    firstFailure = firstFailure
                        ?? (error as? LocalizedError)?.errorDescription
                }
                try? FileManager.default.removeItem(
                    at: url.deletingLastPathComponent()
                )
            case .text(let value):
                textFragments.append(value)
            case .none:
                firstFailure = firstFailure ?? SharedInboxError.unreadable.errorDescription
            }
        }

        let text = SharedInboxPolicy.normalizedText(
            textFragments.joined(separator: "\n").nilWhenBlank
        )
        guard !items.isEmpty || text != nil else {
            store.remove(batchID: batchID)
            present(failure: firstFailure ?? SharedInboxError.empty.errorDescription)
            return
        }

        do {
            try store.finishBatch(
                id: batchID,
                items: items,
                text: text,
                ownerAccountID: ownerAccountID,
                receivedAt: Date()
            )
        } catch {
            store.remove(batchID: batchID)
            present(failure: (error as? LocalizedError)?.errorDescription
                ?? SharedInboxError.unavailable.errorDescription)
            return
        }

        openHostApp()
        finish()
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
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            return await loadURL(provider)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            return await loadText(provider)
        }
        return .none
    }

    /// The most specific registered type that is a *file* rather than a link or a run of selected
    /// text. A `.txt` shared out of Files also registers `public.file-url`, which is what separates
    /// it from a paragraph someone highlighted in Notes.
    private func fileTypeIdentifier(for provider: NSItemProvider) -> String? {
        let registered = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        let isFile = registered.contains { $0.conforms(to: .fileURL) }
        let candidates = registered.filter {
            $0.conforms(to: .data)
                && !$0.conforms(to: .url)
                && (isFile || !$0.conforms(to: .text))
        }
        // Media first: a photo may also register a generic `public.data`, and the concrete type is
        // what tells the recipient's app what it is holding.
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
            // The URL handed to this closure is valid only until it returns, so the file is copied
            // out to a location of ours before resuming. `loadFileRepresentation` also spools
            // provider-supplied data to disk on its own, which keeps a large share off the
            // extension's very small memory budget.
            provider.loadFileRepresentation(
                forTypeIdentifier: typeIdentifier
            ) { url, _ in
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
                } catch {
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

    // MARK: Handing over

    /// Brings Kit Pay forward so the user can pick the chat straight away. If the system declines,
    /// nothing is lost: the share is already in the container and the app finds it the next time
    /// it opens.
    private func openHostApp() {
        guard let url = KitShareHandoffLink.url else { return }
        extensionContext?.open(url, completionHandler: nil)
    }

    private func finish() {
        guard !hasFinished else { return }
        hasFinished = true
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    @objc private func cancel() {
        guard !hasFinished else { return }
        hasFinished = true
        extensionContext?.cancelRequest(withError: SharedInboxError.empty)
    }

    // MARK: Interface

    private func present(failure: String?) {
        spinner.stopAnimating()
        spinner.isHidden = true
        titleLabel.text = "Could not share"
        messageLabel.text = failure ?? SharedInboxError.empty.errorDescription
        closeButton.isHidden = false
    }

    private func buildInterface() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)

        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        view.addSubview(card)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Sharing to Kit Pay"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.text = "Choose the chat in Kit Pay. Your files stay encrypted end to end."
        messageLabel.font = .preferredFont(forTextStyle: .footnote)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("Close", for: .normal)
        closeButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        closeButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        closeButton.isHidden = true

        let stack = UIStackView(arrangedSubviews: [
            spinner,
            titleLabel,
            messageLabel,
            closeButton,
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor,
                constant: 28
            ),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }
}

private extension String {
    var nilWhenBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
