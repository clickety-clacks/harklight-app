import AttentionDomain
import Foundation
import UniformTypeIdentifiers

/// Uploads belong to one saved reply. The journal precedes network IO so a
/// lost upload response can be recovered with exactly the same request.
actor QueuedReplyUploads {
    private struct Upload: Codable {
        let file: ConversationFile
        let key: UUID
        let contentType: String
        var attempted = false
        var handle: UploadHandle?
        var receiptMatches: Bool? = nil
    }

    private struct Group: Codable {
        let item: ExactText
        var uploads: [Upload]
        var handedOff = false
    }

    struct CleanupFailure: Sendable {
        let item: ExactText
        let error: any Error
        var retryable = true
    }

    private let url: URL?
    private let files: ClientAPIFiles
    private let source: @Sendable (ConversationFile) throws -> URL
    private var groups: [UUID: Group]
    private var working: Set<UUID> = []

    init(directory: URL?, files: ClientAPIFiles,
         source: @escaping @Sendable (ConversationFile) throws -> URL) throws {
        url = directory?.appendingPathComponent("queued-reply-uploads-v2.json")
        self.files = files
        self.source = source
        if let url, FileManager.default.fileExists(atPath: url.path) {
            groups = try JSONDecoder().decode([UUID: Group].self, from: Data(contentsOf: url))
        } else {
            groups = [:]
        }
    }

    func prepare(_ message: ConversationDraft, operation: UUID, cap: APIUploadCap?,
                 stillQueued: @Sendable () throws -> Bool = { true }) async throws -> [UploadHandle] {
        guard working.insert(operation).inserted else { throw ConversationError.pendingSubmission }
        defer { working.remove(operation) }
        if let prior = groups[operation] {
            guard prior.item == message.binding.request.messageID,
                  prior.uploads.map(\.file) == message.files else { throw ConversationError.conflict }
        } else {
            if case let .bytes(limit) = cap, let file = message.files.first(where: { $0.byteCount > limit }) {
                throw ConversationError.uploadCapExceeded(file: file.name, cap: limit)
            }
            let uploads = message.files.map { file in
                let ext = (file.name.rawValue as NSString).pathExtension
                let type = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
                return Upload(file: file, key: UUID(), contentType: type, handle: nil)
            }
            try save(Group(item: message.binding.request.messageID, uploads: uploads), for: operation)
        }

        guard var group = groups[operation] else { throw ConversationError.missingRequest }
        var handles: [UploadHandle] = []
        for index in group.uploads.indices {
            try Task.checkCancellation()
            guard try stillQueued() else { throw ConversationError.missingRequest }
            if let handle = group.uploads[index].handle {
                guard group.uploads[index].receiptMatches != false else { throw ConversationError.fileMismatch }
                handles.append(handle)
                continue
            }
            let input = group.uploads[index]
            let url: URL
            do {
                url = try source(input.file)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ConversationError.retainedAttachmentUnavailable
            }
            group.uploads[index].attempted = true
            try save(group, for: operation)
            let created: APIFileCreated
            do {
                created = try await upload(input, from: url)
            } catch let error as APIError where error.isPermanent {
                group.uploads[index].attempted = false
                try save(group, for: operation)
                throw error
            }
            group.uploads[index].handle = created.handle
            let matches = created.name == input.file.name && created.size == input.file.byteCount &&
                ExactText(created.sha256) == input.file.sha256
            group.uploads[index].receiptMatches = matches
            try save(group, for: operation)
            guard matches else { throw ConversationError.fileMismatch }
            handles.append(created.handle)
        }
        return handles
    }

    /// Blocks cancellation of the local intent once the write can enter the
    /// outbox. Retry still uses the same handles if hand-off was interrupted.
    func handOff(_ operation: UUID, stillQueued: @Sendable () throws -> Bool) throws -> Bool {
        guard var group = groups[operation], try stillQueued() else { return false }
        group.handedOff = true
        try save(group, for: operation)
        return true
    }

    func cancelBeforeHandOff(_ operation: UUID, restoreDraft: @Sendable () throws -> Void) throws {
        guard groups[operation]?.handedOff != true else { throw ConversationError.pendingSubmission }
        try restoreDraft()
    }

    func accepted(_ operation: UUID) throws {
        guard groups[operation] != nil else { return }
        try save(nil, for: operation)
    }

    /// An edit or cancellation removes the old queued reply. Recover unknown
    /// uploads first, then DELETE them without creating any fresh uploads.
    func discardAbandoned(keeping retained: Set<UUID>,
                          stillQueued: @Sendable (UUID) throws -> Bool = { _ in false }) async -> [CleanupFailure] {
        var failures: [CleanupFailure] = []
        for operation in groups.keys.filter({ !retained.contains($0) }) {
            guard !Task.isCancelled, working.insert(operation).inserted else { continue }
            defer { working.remove(operation) }
            guard var group = groups[operation] else { continue }
            do {
                guard try !stillQueued(operation) else { continue }
            } catch {
                failures.append(CleanupFailure(item: group.item, error: error))
                continue
            }
            for index in group.uploads.indices where group.uploads[index].attempted {
                let input = group.uploads[index]
                do {
                    try Task.checkCancellation()
                    let handle: UploadHandle
                    if let known = input.handle {
                        handle = known
                    } else {
                        handle = try await upload(input, from: source(input.file)).handle
                        group.uploads[index].handle = handle
                        try save(group, for: operation)
                    }
                    if let conflict = try await discard(handle) {
                        failures.append(CleanupFailure(item: group.item, error: conflict, retryable: false))
                    }
                    group.uploads[index].attempted = false
                    group.uploads[index].handle = nil
                    try save(group, for: operation)
                } catch where Task.isCancelled {
                    return failures
                } catch {
                    failures.append(CleanupFailure(item: group.item, error: error))
                }
            }
            if group.uploads.allSatisfy({ !$0.attempted }) {
                do { try save(nil, for: operation) }
                catch { failures.append(CleanupFailure(item: group.item, error: error)) }
            }
        }
        return failures
    }

    private func upload(_ input: Upload, from url: URL) async throws -> APIFileCreated {
        try await files.upload(from: url, byteCount: input.file.byteCount, name: input.file.name,
                               contentType: input.contentType, idempotencyKey: input.key)
    }

    private func discard(_ handle: UploadHandle) async throws -> APIError? {
        do {
            try await files.discard(handle)
            return nil
        } catch let error as APIError where error.token == .notFound {
            return nil
        } catch let error as APIError where error.token == .alreadyClosed {
            // An accepted reply owns these bytes. The conflict is diagnostic only.
            return error
        }
    }

    private func save(_ group: Group?, for operation: UUID) throws {
        var next = groups
        next[operation] = group
        if let url {
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
        }
        groups = next
    }
}
