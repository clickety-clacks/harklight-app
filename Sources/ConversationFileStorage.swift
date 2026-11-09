import AttentionDomain
import CryptoKit
import Foundation

/// Recoverable exact-byte copies belong to the enrolled account/device, not to a picker URL.
struct ConversationFileStorage: Sendable {
    let directory: URL

    init(identity: ProfileIdentity, root: URL? = nil) throws {
        let base = try root ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let scope = [identity.trustedRelayAuthority.rawValue, identity.personID.rawValue,
                     identity.deviceID.rawValue].joined(separator: "\n")
        let name = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        directory = base.appendingPathComponent("ConversationFiles", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    func retain(_ source: URL) throws -> ConversationFile {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        let relative = id + "/" + source.lastPathComponent
        let destination = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            let checked = try measuredBytes(at: destination)
            return ConversationFile(id: ExactText(id), name: ExactText(source.lastPathComponent),
                byteCount: checked.count, sha256: ExactText(checked.sha256), content: .localFile(ExactText(relative)))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func retainInlineContent(of file: ConversationFile) throws -> ConversationFile {
        guard case let .inline(bytes) = file.content else { return file }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard UInt64(bytes.count) == file.byteCount, digest == file.sha256.rawValue else {
            throw ConversationError.fileMismatch
        }
        let relative = "Inline/\(digest).bin"
        let folder = directory.appendingPathComponent("Inline", isDirectory: true)
        let destination = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bytes.write(to: destination, options: .atomic)
        try verify(destination, for: file)
        return ConversationFile(id: file.id, name: file.name, byteCount: file.byteCount,
            sha256: file.sha256, content: .localFile(ExactText(relative)))
    }

    func fileURL(for file: ConversationFile) throws -> URL {
        guard case let .localFile(name) = file.content else { throw ConversationError.fileMismatch }
        return directory.appendingPathComponent(name.rawValue)
    }

    func previewDestination(for file: ConversationFile) throws -> URL {
        guard file.name.rawValue == URL(fileURLWithPath: file.name.rawValue).lastPathComponent,
              file.sha256.rawValue.utf8.count == 64,
              file.sha256.rawValue.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ConversationError.fileMismatch
        }
        let folder = temporaryPreviewRoot.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(file.name.rawValue)
    }

    func cachedPreview(for file: ConversationFile) throws -> URL? {
        guard case .localFile = file.content else { return nil }
        let url = try fileURL(for: file)
        try verify(url, for: file)
        return url
    }

    func writeInlinePreview(of file: ConversationFile, to destination: URL) throws {
        guard case let .inline(bytes) = file.content else { throw ConversationError.fileMismatch }
        do {
            try bytes.write(to: destination, options: .atomic)
            try verify(destination, for: file)
        } catch {
            removeTemporaryPreview(at: destination)
            throw error
        }
    }

    func removeTemporaryPreview(at url: URL) {
        let rootPath = temporaryPreviewRoot.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        guard candidate.hasPrefix(rootPath + "/") else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func removeAccountFiles() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func removeUnreferencedInlineContent(preserving relativePaths: Set<String>) throws {
        let inlineDirectory = directory.appendingPathComponent("Inline", isDirectory: true)
        guard FileManager.default.fileExists(atPath: inlineDirectory.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: inlineDirectory,
            includingPropertiesForKeys: nil) {
            let relativePath = "Inline/" + file.lastPathComponent
            guard !relativePaths.contains(relativePath) else { continue }
            try FileManager.default.removeItem(at: file)
        }
        if try FileManager.default.contentsOfDirectory(atPath: inlineDirectory.path).isEmpty {
            try FileManager.default.removeItem(at: inlineDirectory)
        }
    }

    func clearCachedPreviews() throws {
        let previews = directory.appendingPathComponent("Downloads", isDirectory: true)
        if FileManager.default.fileExists(atPath: previews.path) {
            try FileManager.default.removeItem(at: previews)
        }
        if FileManager.default.fileExists(atPath: temporaryPreviewRoot.path) {
            try FileManager.default.removeItem(at: temporaryPreviewRoot)
        }
    }

    private var temporaryPreviewRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HarklightConversationPreviews", isDirectory: true)
    }

    /// This is also used after an uploaded file is downloaded: transport completion is not byte integrity.
    func verify(_ url: URL, for file: ConversationFile) throws {
        let checked = try measuredBytes(at: url)
        guard checked.count == file.byteCount, checked.sha256 == file.sha256.rawValue else {
            throw ConversationError.fileMismatch
        }
    }

    private func measuredBytes(at url: URL) throws -> (count: UInt64, sha256: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var count: UInt64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            count += UInt64(chunk.count)
            digest.update(data: chunk)
        }
        return (count, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

extension ConversationFileStorage: ConversationFileReferenceStore {}
