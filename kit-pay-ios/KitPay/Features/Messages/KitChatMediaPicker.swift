import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Keep the provider's small preview independent of its original (which may live in iCloud).
/// NSItemProvider supports concurrent representation requests; originals are imported by two
/// bounded workers and never materialized as Data on the main actor.
struct KitChatPickedItem: Identifiable, @unchecked Sendable {
    let id = UUID()
    let provider: NSItemProvider

    var isVideo: Bool { provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }
    var displayName: String { isVideo ? "Video" : "Photo" }

    func preview() async -> UIImage? {
        let image: UIImage? = await withCheckedContinuation { continuation in
            provider.loadPreviewImage(options: [
                NSItemProviderPreferredImageSizeKey: NSValue(cgSize: CGSize(width: 240, height: 240)),
            ]) { value, _ in
                continuation.resume(returning: value as? UIImage)
            }
        }
        guard let image else { return nil }
        return await Task.detached(priority: .userInitiated) {
            image.preparingThumbnail(of: CGSize(width: 320, height: 320))
        }.value
    }

    func importOriginal() async throws -> (url: URL, mediaType: String, byteCount: Int) {
        let category: UTType = isVideo ? .movie : .image
        let type = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
            .first(where: { $0.conforms(to: category) }) ?? category
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
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
                    continuation.resume(returning: (destination, mediaType, size))
                } catch {
                    if let scratch { try? FileManager.default.removeItem(at: scratch) }
                    continuation.resume(throwing: error)
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
