import AttentionDomain
import CryptoKit
import Foundation

public struct CachedServerRequest: Codable, Equatable, Sendable {
    public let request: StoredRequest
    public let remoteState: RemoteRequestState?

    public init(request: StoredRequest, remoteState: RemoteRequestState?) {
        self.request = request
        self.remoteState = remoteState
    }
}

public struct CachedServerConversation: Codable, Equatable, Sendable {
    public let thread: ConversationThread

    public init(thread: ConversationThread) {
        self.thread = thread
    }
}

/// Server data used for a fast first paint. Drafts, local read positions,
/// send attempts and relay event journals are deliberately excluded.
public struct ServerStateCacheSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public let version: Int
    public let identity: ProfileIdentity
    public let cursor: UInt64
    public let conversationCursor: UInt64
    public let requests: [CachedServerRequest]
    public let conversations: [CachedServerConversation]
    public let inboxView: InboxView?
    public let currentRequestKeys: Set<RequestKey>?
    public let chatReadPositions: [RequestKey: UInt64]?
    public let pendingRelayOverlays: [UInt64: RelayEvent]?
    public let inboxReferences: [RequestKey: RemoteRequestState]?

    public init(identity: ProfileIdentity, cursor: UInt64,
                conversationCursor: UInt64,
                requests: [CachedServerRequest],
                conversations: [CachedServerConversation],
                inboxView: InboxView?,
                currentRequestKeys: Set<RequestKey>?,
                chatReadPositions: [RequestKey: UInt64]? = nil,
                pendingRelayOverlays: [UInt64: RelayEvent]? = nil,
                inboxReferences: [RequestKey: RemoteRequestState]? = nil) {
        version = Self.currentVersion
        self.identity = identity
        self.cursor = cursor
        self.conversationCursor = conversationCursor
        self.requests = requests.sorted {
            if $0.request.acceptanceOrder != $1.request.acceptanceOrder {
                return ($0.request.acceptanceOrder ?? 0) < ($1.request.acceptanceOrder ?? 0)
            }
            return Self.key($0.request.key) < Self.key($1.request.key)
        }
        self.conversations = conversations
        self.inboxView = inboxView
        self.currentRequestKeys = currentRequestKeys
        self.chatReadPositions = chatReadPositions
        self.pendingRelayOverlays = pendingRelayOverlays
        self.inboxReferences = inboxReferences
    }

    public static func make(identity: ProfileIdentity, from inbox: AttentionStoreSnapshot,
                            conversations: ConversationSnapshot,
                            cursorOverride: UInt64? = nil) -> ServerStateCacheSnapshot {
        let currentKeys = inbox.inboxCandidate?.currentKeys ?? inbox.inboxCurrentKeys
        let requests = inbox.requests.values.map { request in
            CachedServerRequest(request: request,
                                remoteState: inbox.remoteStates[request.key])
        }
        let recentThreads = conversations.threads.values
            .sorted {
                let lhs = $0.turns.compactMap(\.conversationSequence).max() ?? 0
                let rhs = $1.turns.compactMap(\.conversationSequence).max() ?? 0
                if lhs != rhs { return lhs > rhs }
                return key($0.request) < key($1.request)
            }
            .map { original -> CachedServerConversation in
                var thread = original
                thread.drafts.removeAll()
                thread.answerDrafts = nil
                thread.uploadGroups = nil
                thread.uploadCleanups = nil
                return CachedServerConversation(thread: thread)
            }
        return ServerStateCacheSnapshot(identity: identity, cursor: cursorOverride ?? inbox.cursor,
                                        conversationCursor: conversations.cursor,
                                        requests: requests,
                                        conversations: Array(recentThreads),
                                        inboxView: inbox.inboxView,
                                        currentRequestKeys: currentKeys,
                                        chatReadPositions: conversations.chatReadPositions,
                                        pendingRelayOverlays: inbox.pendingRelayOverlays,
                                        inboxReferences: inbox.inboxReferences)
    }

    public func attentionDomainState(for identity: ProfileIdentity) throws -> CachedAttentionServerState {
        guard self.identity == identity else { throw ServerStateCacheError.identityMismatch }
        var requests: [RequestKey: StoredRequest] = [:]
        var remoteStates: [RequestKey: RemoteRequestState] = [:]
        for row in self.requests {
            guard requests[row.request.key] == nil else {
                throw ServerStateCacheError.storage("The cache contains duplicate request rows.")
            }
            requests[row.request.key] = row.request
            if let remoteState = row.remoteState {
                remoteStates[row.request.key] = remoteState
            }
        }
        var conversations: [RequestKey: ConversationThread] = [:]
        for row in self.conversations {
            guard conversations[row.thread.request] == nil else {
                throw ServerStateCacheError.storage("The cache contains duplicate conversation rows.")
            }
            conversations[row.thread.request] = row.thread
        }
        return CachedAttentionServerState(identity: identity, requests: requests,
                                          remoteStates: remoteStates,
                                          cursor: cursor,
                                          conversationCursor: conversationCursor,
                                          conversations: conversations,
                                          inboxView: inboxView,
                                          currentRequestKeys: currentRequestKeys,
                                          chatReadPositions: chatReadPositions,
                                          pendingRelayOverlays: pendingRelayOverlays ?? [:],
                                          inboxReferences: inboxReferences ?? [:])
    }

    private static func key(_ value: RequestKey) -> String {
        [value.accountScope.rawValue, value.senderID.rawValue, value.messageID.rawValue]
            .map { "\($0.utf8.count)#\($0)" }
            .joined()
    }
}

public enum ServerStateCacheError: Error, LocalizedError {
    case unavailable
    case identityMismatch
    case storage(String)
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .identityMismatch:
            return "The cache belongs to a different server, account or device."
        case .unavailable:
            return "The Harklight cache is unavailable."
        case let .storage(message):
            return "The Harklight cache could not be read or written: \(message)"
        case let .unsupportedVersion(version):
            return "The Harklight cache version \(version) is unsupported."
        }
    }
}

public protocol ServerStateCaching: Sendable {
    func load() async throws -> ServerStateCacheSnapshot?
    func save(_ snapshot: ServerStateCacheSnapshot) async throws
    func discard() async throws
}

/// A single atomic cache file. The relay repository actor owns it, so disk
/// encoding and I/O stay off the main actor.
public actor FileServerStateCache: ServerStateCaching {
    private let fileURL: URL?
    private let identity: ProfileIdentity
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var memorySnapshot: ServerStateCacheSnapshot?

    public init(identity: ProfileIdentity, fileURL: URL? = nil) {
        self.identity = identity
        self.fileURL = fileURL
        encoder.outputFormatting = [.sortedKeys]
    }

    public static func applicationCache(for identity: ProfileIdentity) throws -> FileServerStateCache {
        guard let cacheRoot = FileManager.default.urls(for: .cachesDirectory,
                                                     in: .userDomainMask).first else {
            throw ServerStateCacheError.unavailable
        }
        let identityValue = [
            identity.trustedRelayAuthority.rawValue,
            identity.personID.rawValue,
            identity.deviceID.rawValue
        ].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(identityValue.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let directory = cacheRoot.appendingPathComponent("HarklightCache", isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        return FileServerStateCache(identity: identity,
            fileURL: directory.appendingPathComponent("\(digest).json", isDirectory: false))
    }

    public func load() throws -> ServerStateCacheSnapshot? {
        guard let fileURL else { return memorySnapshot }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let snapshot = try decoder.decode(ServerStateCacheSnapshot.self, from: data)
            guard snapshot.version == ServerStateCacheSnapshot.currentVersion,
                  snapshot.identity == identity else {
                try discard()
                return nil
            }
            return snapshot
        } catch {
            try? discard()
            return nil
        }
    }

    public func save(_ snapshot: ServerStateCacheSnapshot) throws {
        guard snapshot.identity == identity else { throw ServerStateCacheError.identityMismatch }
        guard snapshot.version == ServerStateCacheSnapshot.currentVersion else {
            throw ServerStateCacheError.unsupportedVersion(snapshot.version)
        }
        guard let fileURL else {
            memorySnapshot = snapshot
            return
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw ServerStateCacheError.storage(error.localizedDescription)
        }
    }

    public func discard() throws {
        memorySnapshot = nil
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
