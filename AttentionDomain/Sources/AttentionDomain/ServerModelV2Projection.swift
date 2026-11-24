import Foundation

/// Projects the client API v2 model onto the store's existing server-state
/// shape (`CachedAttentionServerState`), so the app's presentation and UI read
/// v2 data through the same path they use today. Only the sync bookkeeping is
/// replaced; the product content is carried as the server sent it.
///
/// - An item is keyed by its opaque `item_id` (in `RequestKey.messageID`); the
///   sender is display data.
/// - Arrival order (`acceptanceOrder`) is the server's `Item.arrival`, placed
///   above every local number, so the new-messages area orders exactly as
///   today. Items without one (from before free order, drawn as earlier
///   messages) keep the model's durable local number and never count as new.
/// - The inbox view follows `Rank.key` byte-wise, with today's sections from
///   `Rank.section`/`Rank.group` and unread-reply rows from `Chat.reply_group`
///   and `Chat.reply_rank_key`.
/// - Conversation turns are entries ordered by `Entry.position`, which also
///   serves as each turn's conversation sequence within its item.
public enum ServerModelV2Projection {
    public static func key(for itemID: ExactText, sender: ExactText, identity: ProfileIdentity) -> RequestKey {
        RequestKey(accountScope: identity.personID, senderID: sender, messageID: itemID)
    }

    public static func cachedState(_ model: ServerModelV2, identity: ProfileIdentity, handoffCaptions: Bool = false) -> CachedAttentionServerState {
        let ordered = model.orderedItems
        let keys = Dictionary(uniqueKeysWithValues: ordered.map {
            ($0.itemID, key(for: $0.itemID, sender: $0.sender, identity: identity))
        })

        var requests: [RequestKey: StoredRequest] = [:]
        for item in ordered {
            guard let key = keys[item.itemID] else { continue }
            let order: UInt64
            if let arrival = item.arrival {
                order = serverArrivalBase + arrival
            } else if let local = model.arrivalOrder[item.itemID] {
                order = local
            } else {
                continue
            }
            requests[key] = StoredRequest(key: key, originalPayload: item.message)
                .assigningAcceptanceOrder(order)
        }

        var remoteStates: [RequestKey: RemoteRequestState] = [:]
        var conversations: [RequestKey: ConversationThread] = [:]
        var readPositions: [RequestKey: UInt64] = [:]
        for item in ordered {
            guard let key = keys[item.itemID] else { continue }
            remoteStates[key] = RemoteRequestState(state: terminalState(item.terminal),
                                                   accountAnswerOutcome: answerOutcome(item.terminal?.answer))
            let entries = model.orderedEntries(of: item.itemID)
            var conversation = thread(for: item, key: key, entries: entries)
            conversation.handoffCaptions = handoffCaptions
            if handoffCaptions {
                for entry in entries where model.needsHandoffCaptionRefresh(entry) {
                    conversation.facts[entry.entryID]?.handoffCaptionRefreshPending = true
                }
            }
            conversations[key] = conversation
            if let read = item.chat.readPosition,
               let position = entries.first(where: { $0.entryID == read })?.position {
                readPositions[key] = position
            }
        }

        return CachedAttentionServerState(
            identity: identity, requests: requests, remoteStates: remoteStates,
            cursor: 0, conversationCursor: 0, conversations: conversations,
            inboxView: inboxView(ordered, keys: keys, model: model),
            currentRequestKeys: Set(keys.values),
            chatReadPositions: readPositions, priorityLevels: model.settings?.priorityLevels)
    }

    /// Server arrival numbers sit above every local one.
    static let serverArrivalBase: UInt64 = 1 << 40

    static func priority(_ level: String?) -> InboxMessagePriority? {
        level.flatMap(InboxMessagePriority.init(rawValue:))
    }

    // MARK: Terminal and answer

    static func terminalState(_ terminal: APITerminal?) -> TerminalState? {
        guard let terminal else { return nil }
        switch terminal.state {
        case "answered": return terminal.isNoComment ? .noComment : .answered
        case "cleared": return .cleared
        case "expired": return .expired
        case "superseded": return .superseded
        // Shown as retracted on the thread; the answer flow is closed.
        case "retracted": return .cleared
        default: return nil
        }
    }

    static func answerOutcome(_ answer: APIAnswer?) -> AccountAnswerOutcome? {
        guard let answer else { return nil }
        switch answer.kind {
        case "seen": return .seen
        case "reply": return .reply(answer.text ?? ExactText(""))
        case "no_comment": return .noComment
        case "default": return .defaultAnswer(value: answer.value, text: answer.text)
        case "choice":
            guard let id = answer.id, let label = answer.label else { return nil }
            return .choice(id: id, label: label)
        case "result":
            // Chosen by the screen, never by the value's shape; null is a value.
            guard let value = answer.value else { return nil }
            return .result(value)
        default: return nil
        }
    }

    // MARK: Conversation

    static func thread(for item: APIItem, key: RequestKey, entries: [APIEntry]) -> ConversationThread {
        var thread = ConversationThread(request: key, sessionHandle: item.itemID,
                                        revision: item.requestRevision, payload: item.message)
        thread.terminal = terminalState(item.terminal)
        thread.chatNeverCloses = true
        // Round 13: an item sent without a session has no conversation.
        if item.chat.available == false { thread.hasNoConversation = true }
        if item.terminal?.state == "retracted" {
            thread.reportedRetractedAtMilliseconds = item.terminal?.atMs
        }
        if let availability = item.availability {
            thread.availability = Self.availability(availability)
        }
        for entry in entries {
            guard let kind = turnKind(entry) else { continue }
            let author: ConversationAuthor = switch entry.author {
            case "person": .person
            case "origin": .origin
            default: .server
            }
            let turn = ConversationTurn(
                id: entry.entryID,
                binding: ConversationBinding(request: key, revision: entry.requestRevision),
                author: author, sessionHandle: item.itemID, text: entry.text ?? ExactText(""),
                inReplyTo: entry.inReplyTo, files: entry.files.map(file),
                contentRedacted: entry.state == "retracted" || entry.state == "withdrawn" ? true : nil,
                kind: kind, resultStatus: entry.result?.status, conversationSequence: entry.position)
            thread.turns.append(turn)
            if let delivery = entry.delivery {
                var facts = ConversationTurnFacts(acceptedAtMilliseconds: entry.atMs)
                facts.delivered = delivery.delivered ?? false
                facts.personDelivery = delivery
                // The wire has no handoff timestamp; this is display-only metadata.
                let at = entry.atMs ?? 0
                switch delivery.outcome {
                case "handed":
                    facts.deliveryAck2 = .handed(atMilliseconds: at, rerouted: delivery.rerouted ?? false,
                        acknowledgerSystem: nil, acknowledgerAgent: delivery.agent)
                case "not_handed":
                    facts.deliveryAck2 = .notHanded(atMilliseconds: at, reason: delivery.reason ?? ExactText(""),
                        acknowledgerSystem: nil, acknowledgerAgent: delivery.agent)
                default: break
                }
                thread.facts[entry.entryID] = facts
            }
        }
        if let read = item.chat.readPosition,
           let position = entries.first(where: { $0.entryID == read })?.position {
            thread.accountReadThroughConversationSequence = position
        }
        return thread
    }

    /// Replies are chat turns (the person's are discussions); revision entries
    /// mark a new request revision. Lifecycle and availability entries are
    /// carried on the item instead.
    static func turnKind(_ entry: APIEntry) -> ConversationTurn.Kind? {
        switch entry.kind {
        case "reply": entry.author == "person" ? .discussion : .reply
        case "revision": .revision
        // Today's result status turns (contract round 7).
        case "result": .result
        default: nil
        }
    }

    static func availability(_ availability: APIAvailability) -> ConversationAvailability {
        switch availability.state {
        case "listening": .listening
        case "not_listening": .notListening(lastDetachedAt: availability.lastDetachedAtMs.map { ExactText(String($0)) })
        case "gone": .gone
        default: .unsupported(reason: ExactText(""))
        }
    }

    static func file(_ file: APIFileRef) -> ConversationFile {
        ConversationFile(id: file.fileID.value, name: file.name, byteCount: file.size,
                         sha256: ExactText(file.sha256), content: .v2Download(file.fileID, contentType: file.contentType))
    }

    // MARK: Inbox view

    /// The unread-reply (or Replied) row for an item with agent chat replies.
    /// It quotes the newest origin reply and opens at the first one after the
    /// read position, as today. It is drawn only once those replies are held;
    /// until then the model lists the item as needing its entries.
    static func replyRow(for item: APIItem, key: RequestKey,
                         model: ServerModelV2) -> (sortKey: [UInt8], item: InboxViewListItem)? {
        guard let replyKey = item.chat.replyRankKey, item.chat.replyGroup != nil,
              let last = item.chat.lastOriginReply else { return nil }
        let originReplies = model.orderedEntries(of: item.itemID).filter { $0.kind == "reply" && $0.author == "origin" }
        guard let quote = originReplies.first(where: { $0.entryID == last }) else { return nil }
        let readPosition = item.chat.readPosition.flatMap { read in
            model.orderedEntries(of: item.itemID).first { $0.entryID == read }?.position
        } ?? 0
        let unread = item.chat.unreadReplies ?? originReplies.filter { $0.position > readPosition }.count
        let open = unread > 0 ? (originReplies.first { $0.position > readPosition } ?? quote) : quote
        let replyGroup: InboxFreeSection.Group = item.chat.replyGroup == "earlier_chat_replies_unknown"
            ? .earlierChatRepliesUnknown : .earlierChatReplies
        let state: InboxFreeSection.State = item.rank.section == "resolved" ? .history : .active
        return (Array(replyKey.rawValue.utf8),
                InboxViewListItem(kind: .reply, key: key, conversationSequence: quote.position,
                                  openAtConversationSequence: open.position, unseenCount: unread,
                                  score: item.chat.replyPriority?.score.flatMap { Double($0.lexeme) },
                                  scoreKind: unread > 0 ? .current : .historical,
                                  freeSection: InboxFreeSection(state: state, group: replyGroup)))
    }

    static func inboxView(_ ordered: [APIItem], keys: [ExactText: RequestKey], model: ServerModelV2) -> InboxView {
        let entries = ordered.compactMap { item -> InboxViewEntry? in
            guard let key = keys[item.itemID] else { return nil }
            return InboxViewEntry(key: key, priority: Self.priority(item.rank.level),
                                  score: item.rank.score.flatMap { Double($0.lexeme) },
                                  dueAtMilliseconds: item.rank.dueAtMs.map { Int($0) })
        }
        // Item rows and unread-reply rows share Rank.key's space.
        var rows: [(sortKey: [UInt8], item: InboxViewListItem)] = []
        for item in ordered {
            guard let key = keys[item.itemID] else { continue }
            let state: InboxFreeSection.State = item.rank.section == "resolved" ? .history : .active
            let group: InboxFreeSection.Group = item.rank.group == "earlier_messages" ? .earlierMessages : .common
            rows.append((Array(item.rank.key.rawValue.utf8),
                         InboxViewListItem(kind: .message, key: key,
                                           score: item.rank.score.flatMap { Double($0.lexeme) },
                                           freeSection: InboxFreeSection(state: state, group: group))))
            if let row = replyRow(for: item, key: key, model: model) {
                rows.append(row)
            }
        }
        let listItems = rows.sorted { $0.sortKey.lexicographicallyPrecedes($1.sortKey) }.map(\.item)
        // Each held agent reply's own priority, for the reply rows and New.
        let replies = ordered.flatMap { item -> [InboxViewReply] in
            guard let key = keys[item.itemID] else { return [] }
            return model.orderedEntries(of: item.itemID).compactMap { entry in
                guard entry.kind == "reply", entry.author == "origin", let priority = entry.priority else { return nil }
                return InboxViewReply(key: key, conversationSequence: entry.position,
                                      priority: Self.priority(priority.level),
                                      score: priority.score.flatMap { Double($0.lexeme) })
            }
        }
        let freeOrder = ordered.contains { $0.rank.group != nil } || listItems.contains { $0.kind == .reply }
        return InboxView(revision: ExactText("v2"), entries: entries, replies: replies, listItems: listItems,
                         freeOrderVersion: freeOrder ? 1 : nil)
    }
}

/// The one way the v2 model reaches the screen. The answer-screen rules
/// `GET /v2/me` publishes are put in force before the first projection, so no
/// screen is ever judged by today's rules or the built-in limits while a v2
/// model is shown (review L-27).
public final class ServerModelV2Presentation: @unchecked Sendable {
    public enum PresentationError: Error, Equatable {
        /// No `GET /v2/me` has been read on this device yet.
        case rulesNotRead
    }

    private let lock = NSLock()
    private var me: APIMe?

    /// `savedMe` is the last `GET /v2/me` kept with the model, so a launch
    /// without a connection shows the saved model under the same rules.
    public init(savedMe: APIMe? = nil) {
        if let savedMe { apply(savedMe) }
    }

    /// Puts a freshly read `GET /v2/me` in force.
    public func apply(_ me: APIMe) {
        lock.withLock {
            self.me = me
            AnswerScreenRules.current = .v2(me)
        }
    }

    public var hasRules: Bool { lock.withLock { me != nil } }
    public var uploadCap: APIUploadCap? { lock.withLock { me?.uploadCap } }

    public func cachedState(_ model: ServerModelV2, identity: ProfileIdentity) throws -> CachedAttentionServerState {
        guard hasRules else { throw PresentationError.rulesNotRead }
        let captions = lock.withLock { me?.handoffCaptionsEnabled == true }
        return ServerModelV2Projection.cachedState(model, identity: identity, handoffCaptions: captions)
    }
}
