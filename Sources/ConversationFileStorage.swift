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
        let destination = directory.appendingPathComponent(id)
        try FileManager.default.copyItem(at: source, to: destination)
        do {
            let checked = try measuredBytes(at: destination)
            return ConversationFile(id: ExactText(id), name: ExactText(source.lastPathComponent),
                byteCount: checked.count, sha256: ExactText(checked.sha256), content: .localFile(ExactText(id)))
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func fileURL(for file: ConversationFile) throws -> URL {
        guard case let .localFile(name) = file.content else { throw ConversationError.fileMismatch }
        return directory.appendingPathComponent(name.rawValue)
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
