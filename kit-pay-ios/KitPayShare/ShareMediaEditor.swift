import Foundation
import ImageIO
import SwiftUI
import UIKit

/// Reuses the app's editors inside the extension. The caller replaces its pending row only
/// after a fresh staged item is returned, then revalidates account/destination/send admission.
/// The original item is never changed or removed; cancel and any failure leave it intact.
@MainActor
enum ShareMediaEditor {
    static func supportsEditing(_ item: SharedInboxItem) -> Bool {
        item.mediaType.hasPrefix("image/") || item.mediaType.hasPrefix("video/")
            || item.mediaType == "application/pdf"
    }

    static func present(
        item: SharedInboxItem, batchID: UUID, from presenter: UIViewController,
        maximumAcceptedBytes: Int,
        completion: @escaping (Result<SharedInboxItem?, Error>) -> Void
    ) {
        guard presenter.presentedViewController == nil,
              maximumAcceptedBytes > 0, supportsEditing(item)
        else { completion(.failure(ShareMediaEditorError.unavailable)); return }
        let session = ShareMediaEditorSession(
            item: item, batchID: batchID, maximumAcceptedBytes: maximumAcceptedBytes,
            completion: completion
        )
        session.present(from: presenter)
    }
}

private enum ShareMediaEditorError: LocalizedError {
    case unavailable
    case imageUnavailable
    case couldNotSave

    var errorDescription: String? {
        switch self {
        case .unavailable: "This attachment cannot be edited right now. Please try again."
        case .imageUnavailable: "This photo could not be opened for editing. The original is still attached."
        case .couldNotSave: "The edit could not be saved. The original is still attached."
        }
    }
}

@MainActor
private final class ShareMediaEditorSession {
    private let item: SharedInboxItem
    private let batchID: UUID
    private let maximumAcceptedBytes: Int
    private let store = DirectShareSendRecord.stagingStore
    private var completion: ((Result<SharedInboxItem?, Error>) -> Void)?
    private weak var controller: UIHostingController<AnyView>?
    private var finished = false
    private var saving = false
    private var work: Task<Void, Never>?

    init(
        item: SharedInboxItem, batchID: UUID, maximumAcceptedBytes: Int,
        completion: @escaping (Result<SharedInboxItem?, Error>) -> Void
    ) {
        self.item = item
        self.batchID = batchID
        self.maximumAcceptedBytes = maximumAcceptedBytes
        self.completion = completion
    }

    func present(from presenter: UIViewController) {
        let source: URL
        do { source = try store.fileURL(for: item, in: batchID) }
        catch { finish(.failure(ShareMediaEditorError.unavailable)); return }
        let host = UIHostingController(rootView: progress("Opening attachment…", allowsCancel: true))
        host.modalPresentationStyle = .fullScreen
        host.isModalInPresentation = true
        controller = host
        if item.mediaType == "application/pdf" {
            host.rootView = AnyView(KitPDFPageSelectionView(
                fileURL: source, displayName: item.displayName,
                onFinish: { output in
                    guard let output else { self.finish(.success(nil)); return }
                    self.saveFile(output, source: source, mediaType: "application/pdf")
                }
            ))
        } else if item.mediaType.hasPrefix("video/") {
            showMediaEditor(.video(source, mediaType: item.mediaType), source: source, in: host)
        } else {
            let expectedByteCount = item.byteCount
            work = Task { @MainActor in
                let image = await Task.detached(priority: .userInitiated) {
                    ShareMediaEditorImage.preview(at: source, expectedByteCount: expectedByteCount)
                }.value
                guard !finished, !Task.isCancelled else { return }
                guard let image, let controller else {
                    finish(.failure(ShareMediaEditorError.imageUnavailable))
                    return
                }
                showMediaEditor(.photo(image), source: source, in: controller)
            }
        }
        presenter.present(host, animated: true)
    }

    private func showMediaEditor(
        _ input: KitMediaEditorInput, source: URL, in host: UIHostingController<AnyView>
    ) {
        host.rootView = AnyView(KitMediaEditorView(input: input) { output in
            guard !self.finished, !self.saving else { return }
            switch output {
            case .photo(let image): self.saveImage(image)
            case .video(let output, let mediaType):
                self.saveFile(output, source: source, mediaType: mediaType)
            case nil: self.finish(.success(nil))
            }
        })
    }

    private func saveImage(_ image: UIImage) {
        guard !finished, !saving else { return }
        saving = true
        controller?.rootView = progress("Saving edit…", allowsCancel: false)
        let budget = min(maximumAcceptedBytes, KitChatMediaLimits.imageEncodeTargetBytes)
        let batchID = batchID
        let store = store
        let name = (item.displayName as NSString).deletingPathExtension + ".jpg"
        work = Task { @MainActor in
            do {
                let replacement = try await Task.detached(priority: .userInitiated) {
                    let data = try ShareMediaEditorImage.jpeg(image, maximumBytes: budget)
                    return try store.stage(data: data, suggestedName: name,
                                           mediaType: "image/jpeg", batchID: batchID)
                }.value
                guard !finished else { return }
                finish(.success(replacement))
            } catch {
                guard !finished else { return }
                finish(.failure(ShareMediaEditorError.couldNotSave))
            }
        }
    }

    private func saveFile(_ output: URL, source: URL, mediaType: String) {
        guard !finished, !saving else { return }
        guard output.standardizedFileURL != source.standardizedFileURL else {
            finish(.success(nil))
            return
        }
        saving = true
        controller?.rootView = progress("Saving edit…", allowsCancel: false)
        let budget = maximumAcceptedBytes
        let batchID = batchID
        let store = store
        let name = (item.displayName as NSString).deletingPathExtension
            + "." + ChatMediaTempFiles.fileExtension(forMediaType: mediaType)
        work = Task { @MainActor in
            defer {
                ChatMediaTempFiles.removeTemporaryFile(output)
                KitCaptureTemporaryFileStore.removeTemporaryFile(output)
            }
            do {
                let replacement = try await Task.detached(priority: .userInitiated) {
                    try store.stage(fileAt: output, suggestedName: name, mediaType: mediaType,
                                    batchID: batchID, maximumAcceptedBytes: budget)
                }.value
                guard !finished else { return }
                finish(.success(replacement))
            } catch {
                guard !finished else { return }
                finish(.failure(ShareMediaEditorError.couldNotSave))
            }
        }
    }

    private func progress(_ title: String, allowsCancel: Bool) -> AnyView {
        AnyView(VStack(spacing: 20) {
            ProgressView(title)
            if allowsCancel {
                Button("Cancel") { self.finish(.success(nil)) }
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KitColor.canvas.ignoresSafeArea()))
    }

    private func finish(_ result: Result<SharedInboxItem?, Error>) {
        guard !finished else { return }
        finished = true
        work?.cancel()
        let callback = completion
        completion = nil
        guard let controller else { callback?(result); return }
        controller.dismiss(animated: true) { callback?(result) }
    }
}

private enum ShareMediaEditorImage {
    static func preview(at fileURL: URL, expectedByteCount: Int) -> UIImage? {
        guard expectedByteCount > 0, expectedByteCount <= SharedInboxPolicy.maximumImageDecodeBytes,
              let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size == expectedByteCount,
              let source = CGImageSourceCreateWithURL(fileURL as CFURL,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_048,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    static func jpeg(_ image: UIImage, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0 else { throw ShareMediaEditorError.couldNotSave }
        for quality: CGFloat in [0.82, 0.72, 0.62, 0.52, 0.42] {
            if let data = image.jpegData(compressionQuality: quality), data.count <= maximumBytes {
                return data
            }
        }
        throw ShareMediaEditorError.couldNotSave
    }
}
