import Foundation

/// Owns plaintext camera/editor scratch files. Every directory is protected before AVFoundation
/// receives its output URL, and leftovers from a crash or process termination are removed at the
/// next launch.
enum KitCaptureTemporaryFileStore {
    static let cameraDirectoryPrefix = "kit-camera-"
    static let editorDirectoryPrefix = "kit-trim-"

    static func makeFileURL(
        directoryPrefix: String,
        fileName: String,
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        guard [cameraDirectoryPrefix, editorDirectoryPrefix].contains(directoryPrefix) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let directory = temporaryDirectory.appendingPathComponent(
            "\(directoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: directory.path
            )
            return directory.appendingPathComponent(fileName, isDirectory: false)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func protectFile(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    /// Removes only this process's editor/capture scratch directory, never an adopted source
    /// or a shared inbox batch that happens to be passed to an editor callback unchanged.
    static func removeTemporaryFile(_ url: URL?) {
        guard let url else { return }
        let directory = url.deletingLastPathComponent().standardizedFileURL
        let root = FileManager.default.temporaryDirectory.standardizedFileURL
        guard directory.deletingLastPathComponent() == root,
              directory.lastPathComponent.hasPrefix(cameraDirectoryPrefix)
                || directory.lastPathComponent.hasPrefix(editorDirectoryPrefix)
        else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    static func removeAbandonedFiles(
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(cameraDirectoryPrefix)
                    || name.hasPrefix(editorDirectoryPrefix)
            else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
