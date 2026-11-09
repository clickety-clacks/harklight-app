import Foundation
import Observation
import AttentionDomain

/// One origin chat reply as currently observed in its conversation thread.
/// The caller supplies these in conversation order for each parent message.
struct ReplyItemObservation: Equatable, Sendable {
    let parent: RequestKey
    let turnID: ExactText
    let conversationSequence: UInt64?
    let isSeen: Bool
    let text: String

    var accountScope: ExactText { parent.accountScope }
}

struct ReplyItemUnseenReply: Codable, Equatable, Sendable {
    let turnID: ExactText
    let conversationSequence: UInt64?
    let text: String
}

struct ReplyItemEntry: Codable, Equatable, Identifiable, Sendable {
    let parent: RequestKey
    /// Unseen replies in conversation order: the earliest is first, the
    /// newest is last. Read position advances monotonically, so replies
    /// only ever leave from the front.
    var unseenReplies: [ReplyItemUnseenReply]
    /// When the newest unseen reply arrived on this device; the item's
    /// ordering key among new-message entries.
    var receivedAt: Date
    var firstSeenAt: Date?

    var id: RequestKey { parent }

    var newestUnseenReply: ReplyItemUnseenReply? { unseenReplies.last }
    var earliestUnseenReply: ReplyItemUnseenReply? { unseenReplies.first }
    var unseenCount: Int { unseenReplies.count }
}

struct ReplyItemNormalRow: Equatable, Identifiable {
    let reference: InboxViewListItem
    let quotedReply: ConversationTurn
    let openTargetTurnID: ExactText
    let receivedAt: Date?

    var id: RequestKey { reference.key }
    var unseenCount: Int { reference.unseenCount ?? 0 }
}

enum ReplyItemLocalReceiptTime {
    static func resolve(_ turnID: ExactText, in thread: ConversationThread?) -> Date? {
        guard let milliseconds = thread?.facts[turnID]?.localLiveArrivalAtMilliseconds else {
            return nil
        }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}

enum ReplyItemNormalRowProjection {
    static func resolve(_ reference: InboxViewListItem,
                        in thread: ConversationThread?) -> ReplyItemNormalRow? {
        guard reference.kind == .reply,
              let quoteSequence = reference.conversationSequence,
              let openSequence = reference.openAtConversationSequence,
              let unseenCount = reference.unseenCount, unseenCount >= 0,
              let thread,
              let quote = originReply(sequence: quoteSequence, in: thread),
              let target = originReply(sequence: unseenCount > 0 ? openSequence : quoteSequence,
                                       in: thread) else { return nil }
        let receivedAt = ReplyItemLocalReceiptTime.resolve(quote.id, in: thread)
        return ReplyItemNormalRow(reference: reference, quotedReply: quote,
                                  openTargetTurnID: target.id, receivedAt: receivedAt)
    }

    private static func originReply(sequence: UInt64,
                                    in thread: ConversationThread) -> ConversationTurn? {
        thread.turns.first { turn in
            turn.conversationSequence == sequence &&
                turn.kind == .reply && turn.author == .origin
        }
    }
}

enum ReplyItemPriorityProjection {
    static func score(for entry: ReplyItemEntry,
                      perReplyScores: [UInt64: Double],
                      serverListItems: [InboxViewListItem]?) -> Double? {
        if let serverListItems {
            guard let group = serverListItems.first(where: {
                $0.kind == .reply && $0.key == entry.parent
            }), group.unseenCount.map({ $0 > 0 }) == true,
                  group.scoreKind == .current else { return nil }
            return group.score
        }
        return entry.unseenReplies.compactMap { reply in
            reply.conversationSequence.flatMap { perReplyScores[$0] }
        }.max()
    }
}

struct ReplyItemIdentity: Codable, Hashable, Sendable {
    let parent: RequestKey
    let turnID: ExactText
}

struct ReplyItemLedger: Codable, Equatable, Sendable {
    static let expiryInterval: TimeInterval = 60 * 60

    private(set) var baselineEstablishedAccounts: Set<ExactText> = []
    private(set) var knownReplyIDs: Set<ReplyItemIdentity> = []
    private(set) var entriesByParent: [RequestKey: ReplyItemEntry] = [:]

    var entries: [ReplyItemEntry] {
        entriesByParent.values.sorted(by: Self.isNewer)
    }

    var nextExpiry: Date? {
        entriesByParent.values.compactMap { entry in
            entry.firstSeenAt.map { $0.addingTimeInterval(Self.expiryInterval) }
        }.min()
    }

    mutating func reconcile(_ observations: [ReplyItemObservation],
                            accountScopes: Set<ExactText> = [],
                            parentScope: Set<RequestKey>? = nil,
                            now: Date) {
        let scopedObservations = parentScope.map { scope in
            observations.filter { scope.contains($0.parent) }
        } ?? observations
        let observedAccounts = accountScopes.union(scopedObservations.map(\.accountScope))
        let newAccounts = observedAccounts.subtracting(baselineEstablishedAccounts)
        for account in newAccounts {
            // Replies already on the device when this account first runs the
            // feature are baseline history, not new arrivals.
            for observation in scopedObservations where observation.accountScope == account {
                knownReplyIDs.insert(ReplyItemIdentity(parent: observation.parent,
                                                       turnID: observation.turnID))
            }
            baselineEstablishedAccounts.insert(account)
        }

        var seenTurnIDsByParent: [RequestKey: Set<ExactText>] = [:]
        for observation in scopedObservations where observation.isSeen {
            seenTurnIDsByParent[observation.parent, default: []].insert(observation.turnID)
        }

        // Drop replies the account's read position has passed, here or on
        // another device; an item with nothing left unseen leaves. Its
        // replies stay known, so a left item never re-enters on replay.
        if let parentScope {
            for parent in parentScope {
                guard let entry = entriesByParent[parent],
                      let seenTurnIDs = seenTurnIDsByParent[parent],
                      !seenTurnIDs.isEmpty else { continue }
                var updated = entry
                updated.unseenReplies.removeAll { seenTurnIDs.contains($0.turnID) }
                if updated.unseenReplies.isEmpty {
                    entriesByParent.removeValue(forKey: parent)
                } else if updated != entry {
                    entriesByParent[parent] = updated
                }
            }
        } else {
            for (parent, entry) in entriesByParent {
                let seenTurnIDs = seenTurnIDsByParent[parent] ?? []
                guard !seenTurnIDs.isEmpty else { continue }
                var updated = entry
                updated.unseenReplies.removeAll { seenTurnIDs.contains($0.turnID) }
                if updated.unseenReplies.isEmpty {
                    entriesByParent.removeValue(forKey: parent)
                } else if updated != entry {
                    entriesByParent[parent] = updated
                }
            }
        }

        for observation in scopedObservations where !newAccounts.contains(observation.accountScope) {
            let identity = ReplyItemIdentity(parent: observation.parent,
                                             turnID: observation.turnID)
            guard !knownReplyIDs.contains(identity) else { continue }
            knownReplyIDs.insert(identity)
            guard !observation.isSeen else { continue }
            let reply = ReplyItemUnseenReply(turnID: observation.turnID,
                                             conversationSequence: observation.conversationSequence,
                                             text: observation.text)
            if var entry = entriesByParent[observation.parent] {
                // A joining reply re-dates the item and restarts its
                // visible-time clock.
                entry.unseenReplies.append(reply)
                entry.receivedAt = now
                entry.firstSeenAt = nil
                entriesByParent[observation.parent] = entry
            } else {
                entriesByParent[observation.parent] = ReplyItemEntry(
                    parent: observation.parent,
                    unseenReplies: [reply],
                    receivedAt: now,
                    firstSeenAt: nil)
            }
        }
        pruneExpired(now: now)
    }

    mutating func markFirstSeen(_ parent: RequestKey, at date: Date) {
        guard var entry = entriesByParent[parent], entry.firstSeenAt == nil else { return }
        entry.firstSeenAt = date
        entriesByParent[parent] = entry
    }

    @discardableResult
    mutating func removeForSelection(_ parent: RequestKey) -> Bool {
        entriesByParent.removeValue(forKey: parent) != nil
    }

    @discardableResult
    mutating func pruneExpired(now: Date) -> Bool {
        let expiredParents = entriesByParent.values.compactMap { entry -> RequestKey? in
            guard let firstSeenAt = entry.firstSeenAt,
                  now.timeIntervalSince(firstSeenAt) >= Self.expiryInterval else { return nil }
            return entry.parent
        }
        for parent in expiredParents { entriesByParent.removeValue(forKey: parent) }
        return !expiredParents.isEmpty
    }

    private static func isNewer(_ lhs: ReplyItemEntry, than rhs: ReplyItemEntry) -> Bool {
        if lhs.receivedAt != rhs.receivedAt {
            return lhs.receivedAt > rhs.receivedAt
        }
        if lhs.parent.accountScope != rhs.parent.accountScope {
            return lhs.parent.accountScope.rawValue < rhs.parent.accountScope.rawValue
        }
        if lhs.parent.senderID != rhs.parent.senderID {
            return lhs.parent.senderID.rawValue < rhs.parent.senderID.rawValue
        }
        return lhs.parent.messageID.rawValue < rhs.parent.messageID.rawValue
    }
}

struct PreparedReplyItemAreaReconciliation: Sendable {
    let ledger: ReplyItemLedger
    let didChange: Bool
}

enum NewMessageAreaRowOrder {
    /// Merges message entries and reply items, each already newest-first,
    /// into one newest-received-on-device-first list. A tie goes to the
    /// message, which keeps same-batch messages contiguous in their
    /// accepted order.
    static func merged<Message, Reply, Combined>(
        messages: [Message], replies: [Reply],
        messageDate: (Message) -> Date, replyDate: (Reply) -> Date,
        message: (Message) -> Combined, reply: (Reply) -> Combined) -> [Combined] {
        var combined: [Combined] = []
        combined.reserveCapacity(messages.count + replies.count)
        var messageIndex = messages.startIndex
        var replyIndex = replies.startIndex
        while messageIndex < messages.endIndex, replyIndex < replies.endIndex {
            if replyDate(replies[replyIndex]) > messageDate(messages[messageIndex]) {
                combined.append(reply(replies[replyIndex]))
                replyIndex += 1
            } else {
                combined.append(message(messages[messageIndex]))
                messageIndex += 1
            }
        }
        combined.append(contentsOf: messages[messageIndex...].map(message))
        combined.append(contentsOf: replies[replyIndex...].map(reply))
        return combined
    }
}

@MainActor
@Observable
final class ReplyItemAreaStore {
    static let defaultsKey = "harklight.reply-item-area.v1"

    @ObservationIgnored private var reconciliationGeneration: UInt64 = 0
    private(set) var ledger: ReplyItemLedger

    init(defaults: UserDefaults? = nil, defaultsKey: String = ReplyItemAreaStore.defaultsKey,
         initialLedger: ReplyItemLedger? = nil) {
        ledger = initialLedger ?? ReplyItemLedger()
    }

    var entries: [ReplyItemEntry] { ledger.entries }
    var nextExpiry: Date? { ledger.nextExpiry }

    func reconcile(_ observations: [ReplyItemObservation],
                   accountScopes: Set<ExactText> = [],
                   parentScope: Set<RequestKey>? = nil,
                   now: Date = .now) {
        let prepared = Self.prepareReconciliation(ledger: ledger,
            observations: observations, accountScopes: accountScopes,
            parentScope: parentScope, now: now)
        ledger = prepared.ledger
        reconciliationGeneration &+= 1
    }

    nonisolated static func prepareReconciliation(
        ledger seed: ReplyItemLedger,
        observations: [ReplyItemObservation],
        accountScopes: Set<ExactText> = [],
        parentScope: Set<RequestKey>? = nil,
        now: Date = .now
    ) -> PreparedReplyItemAreaReconciliation {
        var ledger = seed
        ledger.reconcile(observations, accountScopes: accountScopes,
                         parentScope: parentScope, now: now)
        return PreparedReplyItemAreaReconciliation(ledger: ledger, didChange: ledger != seed)
    }

    func reconciliationSeed() -> (ledger: ReplyItemLedger, generation: UInt64) {
        (ledger, reconciliationGeneration)
    }

    @discardableResult
    func applyPreparedReconciliation(_ prepared: PreparedReplyItemAreaReconciliation,
                                     basedOn generation: UInt64) -> Bool {
        guard reconciliationGeneration == generation else { return false }
        ledger = prepared.ledger
        reconciliationGeneration &+= 1
        return true
    }

    func markFirstSeen(_ parent: RequestKey, at date: Date = .now) {
        let oldEntries = ledger.entriesByParent
        ledger.markFirstSeen(parent, at: date)
        guard oldEntries != ledger.entriesByParent else { return }
        reconciliationGeneration &+= 1
    }

    func removeForSelection(_ parent: RequestKey) {
        guard ledger.removeForSelection(parent) else { return }
        reconciliationGeneration &+= 1
    }

    func removeExpired(now: Date = .now) {
        guard ledger.pruneExpired(now: now) else { return }
        reconciliationGeneration &+= 1
    }
}
