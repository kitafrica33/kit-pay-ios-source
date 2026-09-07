import Foundation

enum ChatMediaTempFiles {
    private static let previewDirectoryPrefix = "kit-preview-"

    /// Kept visible to tests so the protection contract can be verified even on Simulator
    /// filesystems, which do not consistently expose `NSFileProtectionKey` attributes.
    static let previewFileWritingOptions: Data.WritingOptions = [
        .atomic,
        .completeFileProtectionUnlessOpen,
    ]

    static func fileExtension(forMediaType mediaType: String) -> String {
        switch mediaType.lowercased() {
        case "image/jpeg": "jpg"
        case "image/png": "png"
        case "image/webp": "webp"
        case "image/gif": "gif"
        case "audio/mp4": "m4a"
        case "audio/aac": "aac"
        case "audio/mpeg": "mp3"
        case "audio/ogg": "ogg"
        case "video/mp4": "mp4"
        case "video/quicktime": "mov"
        case "video/webm": "webm"
        case "application/pdf": "pdf"
        case "application/zip": "zip"
        case "application/msword": "doc"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx"
        case "application/vnd.ms-excel": "xls"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx"
        case "application/vnd.ms-powerpoint": "ppt"
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx"
        case "text/plain": "txt"
        case "text/csv": "csv"
        default: "bin"
        }
    }

    /// Decrypted media is staged in a file-protected temporary file only for the lifetime of a
    /// preview; callers remove it when the preview closes. `UnlessOpen` is intentional: video
    /// players hold a read handle for their lifetime, so playback that began while unlocked can
    /// finish across a device-lock/background transition without ever making the plaintext
    /// generally readable while the device is locked.
    static func writeTemporaryFile(
        data: Data,
        mediaType: String,
        suggestedName: String? = nil
    ) throws -> URL {
        let base = suggestedName?
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = (base?.isEmpty == false ? base! : "kit-media-\(UUID().uuidString)")
        let ext = fileExtension(forMediaType: mediaType)
        let named = stem.lowercased().hasSuffix(".\(ext)") ? stem : "\(stem).\(ext)"
        let directory = try makeProtectedPreviewDirectory()
        let url = directory
            .appendingPathComponent(named, isDirectory: false)
        do {
            try data.write(to: url, options: previewFileWritingOptions)
            return url
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// File-to-file export for a protected local original. This preserves bounded memory while
    /// giving share/save consumers an independently owned, correctly extended temporary path.
    static func copyTemporaryFile(
        from sourceURL: URL,
        mediaType: String,
        suggestedName: String? = nil
    ) throws -> URL {
        let base = suggestedName?
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = base?.isEmpty == false ? base! : "kit-media-\(UUID().uuidString)"
        let ext = fileExtension(forMediaType: mediaType)
        let named = stem.lowercased().hasSuffix(".\(ext)") ? stem : "\(stem).\(ext)"
        let directory = try makeProtectedPreviewDirectory()
        let destination = directory.appendingPathComponent(named, isDirectory: false)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: destination.path
            )
            return destination
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Gives AVFoundation a filename that agrees with the container bytes without copying a
    /// potentially 200 MiB received original. The source lease remains the lifetime authority;
    /// this same-volume hard link is presentation-owned and removed with its private directory.
    static func linkTemporaryFile(from sourceURL: URL, mediaType: String) throws -> URL {
        let directory = try makeProtectedPreviewDirectory()
        let destination = directory.appendingPathComponent(
            "kit-video.\(fileExtension(forMediaType: mediaType))",
            isDirectory: false
        )
        do {
            try FileManager.default.linkItem(at: sourceURL, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func removeTemporaryFile(_ url: URL?) {
        guard let url else { return }
        let directory = url.deletingLastPathComponent().standardizedFileURL
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
        guard directory.lastPathComponent.hasPrefix(previewDirectoryPrefix),
              directory.deletingLastPathComponent() == temporaryDirectory
        else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Every plaintext preview directory is itself protected and excluded from backup before a
    /// file is published inside it. A video alias is a hard link, so its inode keeps the source's
    /// equal-or-stronger file protection while this directory prevents an unprotected path from
    /// being exposed during creation or cleanup.
    private static func makeProtectedPreviewDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(previewDirectoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
#if targetEnvironment(simulator)
            // Host filesystems do not consistently implement iOS Data Protection attributes.
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: directory.path
            )
#else
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: directory.path
            )
#endif
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDirectory = directory
            try? mutableDirectory.setResourceValues(values)
            return directory
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
