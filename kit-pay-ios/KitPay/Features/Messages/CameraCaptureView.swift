import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum CameraCaptureMode {
    case photo
    case videoNote

    /// Video notes are quick in-chat clips, capped well under the transfer limit.
    static let videoNoteMaximumDuration: TimeInterval = 3 * 60
}

enum CameraCaptureResult {
    case photo(UIImage)
    case video(URL)
}

/// System camera capture for in-chat photos and video notes.
struct CameraCaptureView: UIViewControllerRepresentable {
    let mode: CameraCaptureMode
    let completion: (CameraCaptureResult?) -> Void

    static var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        switch mode {
        case .photo:
            picker.mediaTypes = [UTType.image.identifier]
            picker.cameraCaptureMode = .photo
        case .videoNote:
            picker.mediaTypes = [UTType.movie.identifier]
            picker.cameraCaptureMode = .video
            picker.cameraDevice = .front
            picker.videoQuality = .typeMedium
            picker.videoMaximumDuration = CameraCaptureMode.videoNoteMaximumDuration
        }
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (CameraCaptureResult?) -> Void

        init(completion: @escaping (CameraCaptureResult?) -> Void) {
            self.completion = completion
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let videoURL = info[.mediaURL] as? URL {
                completion(.video(videoURL))
            } else if let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage {
                completion(.photo(image))
            } else {
                completion(nil)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            completion(nil)
        }
    }
}
