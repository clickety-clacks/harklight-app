import Foundation

/// The only in-memory owner of server request, replay and conversation facts.
/// It is disposable. Authenticated snapshots and updates replace its values.
struct ServerProjectionCache {
    var requests: [RequestKey: StoredRequest] = [:]
    var remoteStates: [RequestKey: RemoteRequestState] = [:]
    var appliedEvents: [UInt64: RelayEvent] = [:]
    var cursor: UInt64 = 0
    var replayBarrier: UInt64?
    var replayPublishedRequests: [RequestKey: StoredRequest]?
    var replayPublishedStates: [RequestKey: RemoteRequestState]?
    var replayPublishedInboxCurrentKeys: Set<RequestKey>?
    var repairIssues: [StoreRepairIssue] = []
    var inboxCheckpoint: InboxPagingCheckpoint?
    var inboxCandidate: InboxPagingCheckpoint?
    var inboxView: InboxView?
    var cachedInboxCurrentKeys: Set<RequestKey>?
    var pendingRelayOverlays: [UInt64: RelayEvent]?
    var inboxReferences: [RequestKey: RemoteRequestState]?
    var conversation: ConversationState?
}
