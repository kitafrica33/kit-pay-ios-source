import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum KitChatDocumentPickerPolicy {
    static func failureMessage(for error: Error) -> String? {
        let failure = error as NSError
        guard failure.domain != NSCocoaErrorDomain || failure.code != NSUserCancelledError
        else { return nil }
        return "The selected file could not be opened. Please choose it again in Files."
    }
}

/// A provider may never call back after cancellation. Resolve the waiter ourselves, and let
/// a late successful callback dispose of any temporary bytes it no longer owns.
final class KitChatProviderRequest<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var progress: Progress?
    private var finished = false
    private var cancelled = false

    var isPending: Bool { lock.withLock { !finished } }

    func load(_ start: @Sendable () -> Progress?) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldStart = lock.withLock {
                    guard !finished else { return false }
                    self.continuation = continuation
                    return true
                }
                guard shouldStart else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let progress = start()
                let shouldCancel = lock.withLock {
                    if !finished { self.progress = progress }
                    return cancelled
                }
                if shouldCancel { progress?.cancel() }
            }
        } onCancel: {
            self.cancel()
        }
    }

    @discardableResult
    func finish(_ result: Result<Value, Error>) -> Bool {
        let waiter = lock.withLock { () -> CheckedContinuation<Value, Error>? in
            guard !finished else { return nil }
            finished = true
            progress = nil
            defer { continuation = nil }
            return continuation
        }
        guard let waiter else { return false }
        waiter.resume(with: result)
        return true
    }

    func cancel() {
        let pending = lock.withLock { () -> (CheckedContinuation<Value, Error>?, Progress?) in
            guard !finished else { return (nil, nil) }
            finished = true
            cancelled = true
            defer { continuation = nil; progress = nil }
            return (continuation, progress)
        }
        pending.0?.resume(throwing: CancellationError())
        pending.1?.cancel()
    }
}

/// Busy state belongs only to selections the user still wants. Removing a stalled item must
/// unblock a ready photo immediately, without cancelling other wanted imports or allowing an
/// old batch's completion to change the next batch's state.
struct KitChatLibraryImportState {
    private(set) var generation: Int?
    private var cancellations: [UUID: @Sendable () -> Void] = [:]

    var isLoading: Bool { !cancellations.isEmpty }

    mutating func begin(generation: Int, cancellations: [UUID: @Sendable () -> Void]) {
        retire()
        self.generation = generation
        self.cancellations = cancellations
    }

    @discardableResult
    mutating func finish(_ id: UUID, generation: Int) -> Bool {
        guard self.generation == generation else { return false }
        return remove(id)
    }

    @discardableResult
    mutating func remove(_ id: UUID) -> Bool {
        guard let cancel = cancellations.removeValue(forKey: id) else { return false }
        cancel()
        return true
    }

    mutating func retire() {
        let pending = cancellations.values
        cancellations.removeAll()
        generation = nil
        for cancel in pending { cancel() }
    }
}

private struct KitChatProviderPreview: @unchecked Sendable {
    let image: UIImage?
}

/// Keep the provider's small preview independent of its original (which may live in iCloud).
/// NSItemProvider supports concurrent representation requests; originals are imported by two
/// bounded workers and never materialized as Data on the main actor.
struct KitChatPickedItem: Identifiable, @unchecked Sendable {
    let id = UUID()
    let provider: NSItemProvider
    private let originalRequest = KitChatProviderRequest<(url: URL, mediaType: String, byteCount: Int)>()
    private let previewRequest = KitChatProviderRequest<KitChatProviderPreview>()

    init(provider: NSItemProvider) { self.provider = provider }

    func cancelImport() {
        originalRequest.cancel()
        previewRequest.cancel()
    }

    var isVideo: Bool { provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }
    var displayName: String { isVideo ? "Video" : "Photo" }

    func preview() async -> UIImage? {
        let result = try? await previewRequest.load {
            provider.loadPreviewImage(options: [
                NSItemProviderPreferredImageSizeKey: NSValue(cgSize: CGSize(width: 240, height: 240)),
            ]) { value, _ in
                previewRequest.finish(.success(KitChatProviderPreview(image: value as? UIImage)))
            }
            // The legacy preview API has no cancellable Progress. The waiter still releases
            // immediately, and a late preview cannot restore a removed selection.
            return nil
        }
        guard let image = result?.image else { return nil }
        return await Task.detached(priority: .userInitiated) {
            image.preparingThumbnail(of: CGSize(width: 320, height: 320))
        }.value
    }

    func importOriginal() async throws -> (url: URL, mediaType: String, byteCount: Int) {
        let category: UTType = isVideo ? .movie : .image
        let type = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
            .first(where: { $0.conforms(to: category) }) ?? category
        return try await originalRequest.load {
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard originalRequest.isPending else { return }
                guard let url else {
                    originalRequest.finish(.failure(error ?? CocoaError(.fileReadUnknown)))
                    return
                }
                var scratch: URL?
                do {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard self.isVideo
                        ? ConversationAttachmentStagingPolicy.editableVideoSource(byteCount: Int64(size))
                        : SharedInboxPolicy.shouldDecodeSharedImage(byteCount: size)
                            && KitChatMediaLimits.fits(size, kind: .image)
                    else { throw CocoaError(.fileReadTooLarge) }
                    let ext = url.pathExtension.isEmpty
                        ? (type.preferredFilenameExtension ?? (self.isVideo ? "mov" : "img"))
                        : url.pathExtension
                    let destination = try KitCaptureTemporaryFileStore.makeFileURL(
                        directoryPrefix: KitCaptureTemporaryFileStore.editorDirectoryPrefix,
                        fileName: "library.\(ext)"
                    )
                    scratch = destination
                    // The provider grant ends with this callback. Adopt the file before returning.
                    try FileManager.default.copyItem(at: url, to: destination)
                    try KitCaptureTemporaryFileStore.protectFile(at: destination)
                    guard try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize == size
                    else { throw CocoaError(.fileReadCorruptFile) }
                    let mime = (UTType(filenameExtension: ext)?.preferredMIMEType
                        ?? type.preferredMIMEType ?? (self.isVideo ? "video/mp4" : "image/jpeg")).lowercased()
                    // Photos may name an ordinary MPEG-4 container .m4v. Keep the same wire
                    // MIME used for that format by the prior picker and the recipient player.
                    let mediaType = self.isVideo && mime == "video/x-m4v" ? "video/mp4" : mime
                    guard !self.isVideo || SecureMessagingWire.allowedAttachmentMediaTypes.contains(mediaType)
                    else { throw CocoaError(.fileReadCorruptFile) }
                    if !originalRequest.finish(.success((destination, mediaType, size))) {
                        try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
                    }
                } catch {
                    if let scratch {
                        try? FileManager.default.removeItem(at: scratch.deletingLastPathComponent())
                    }
                    originalRequest.finish(.failure(error))
                }
            }
        }
    }
}

/// Use Photos' current representation to avoid an unnecessary system transcode before Kit Pay
/// can even show the selection. The app's durable preprocessing still sanitizes sent images.
struct KitChatMediaPicker: UIViewControllerRepresentable {
    let selectionLimit: Int
    let onSelect: ([KitChatPickedItem]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = max(1, selectionLimit)
        configuration.selection = .ordered
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        picker.view.accessibilityIdentifier = "conversation-photo-picker"
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onSelect: ([KitChatPickedItem]) -> Void
        init(onSelect: @escaping ([KitChatPickedItem]) -> Void) { self.onSelect = onSelect }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onSelect(results.map { KitChatPickedItem(provider: $0.itemProvider) })
        }
    }
}
