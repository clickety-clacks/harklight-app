import Foundation
import Observation
import AttentionDomain
#if canImport(FoundationModels)
import FoundationModels
#endif

struct NewMessageAreaMessage: Equatable, Sendable {
    let key: RequestKey
    let acceptanceOrder: UInt64
    let isResolved: Bool
    let hasSubmittedAnswer: Bool

    var accountScope: ExactText { key.accountScope }
    var isUnresolved: Bool { !isResolved && !hasSubmittedAnswer }
}

struct NewMessageAreaEntry: Codable, Equatable, Identifiable, Sendable {
    let key: RequestKey
    let acceptanceOrder: UInt64
    let receivedAt: Date
    var firstSeenAt: Date?

    var id: RequestKey { key }
}

struct NewMessageAreaLedger: Codable, Equatable {
    static let expiryInterval: TimeInterval = 60 * 60

    private(set) var baselineEstablishedAccounts: Set<ExactText> = []
    private(set) var highestAcceptanceOrderByAccount: [ExactText: UInt64] = [:]
    private(set) var knownMessageKeys: Set<RequestKey> = []
    private(set) var entriesByKey: [RequestKey: NewMessageAreaEntry] = [:]

    var entries: [NewMessageAreaEntry] {
        entriesByKey.values.sorted(by: Self.isNewer)
    }

    var nextExpiry: Date? {
        entriesByKey.values.compactMap { entry in
            entry.firstSeenAt.map { $0.addingTimeInterval(Self.expiryInterval) }
        }.min()
    }

    var hasMoreThanFiveEntries: Bool { entriesByKey.count > 5 }

    func visibleEntries(isExpanded: Bool) -> [NewMessageAreaEntry] {
        let ordered = entries
        return isExpanded ? ordered : Array(ordered.prefix(5))
    }

    mutating func reconcile(_ messages: [NewMessageAreaMessage],
                            accountScopes: Set<ExactText> = [], now: Date) {
        let observedAccounts = accountScopes.union(messages.map(\.accountScope))
        let newAccounts = observedAccounts.subtracting(baselineEstablishedAccounts)
        for account in newAccounts {
            for message in messages where message.accountScope == account {
                knownMessageKeys.insert(message.key)
                highestAcceptanceOrderByAccount[account] = max(
                    highestAcceptanceOrderByAccount[account] ?? 0,
                    message.acceptanceOrder)
            }
            baselineEstablishedAccounts.insert(account)
        }

        // Process in acceptance order so a snapshot containing several new messages
        // admits all of them before advancing each account's high-water mark.
        let ordered = messages.filter { !newAccounts.contains($0.accountScope) }.sorted {
            if $0.accountScope != $1.accountScope {
                return $0.accountScope.rawValue < $1.accountScope.rawValue
            }
            return $0.acceptanceOrder < $1.acceptanceOrder
        }

        for message in ordered {
            if knownMessageKeys.contains(message.key) {
                if !message.isUnresolved { entriesByKey.removeValue(forKey: message.key) }
            } else {
                knownMessageKeys.insert(message.key)
                let priorHighWater = highestAcceptanceOrderByAccount[message.accountScope] ?? 0
                if message.acceptanceOrder > priorHighWater, message.isUnresolved {
                    entriesByKey[message.key] = NewMessageAreaEntry(
                        key: message.key,
                        acceptanceOrder: message.acceptanceOrder,
                        receivedAt: now,
                        firstSeenAt: nil)
                }
            }

            highestAcceptanceOrderByAccount[message.accountScope] = max(
                highestAcceptanceOrderByAccount[message.accountScope] ?? 0,
                message.acceptanceOrder)
        }
        pruneExpired(now: now)
    }

    mutating func markFirstSeen(_ key: RequestKey, at date: Date) {
        guard var entry = entriesByKey[key], entry.firstSeenAt == nil else { return }
        entry.firstSeenAt = date
        entriesByKey[key] = entry
    }

    mutating func remove(_ key: RequestKey) {
        entriesByKey.removeValue(forKey: key)
    }

    @discardableResult
    mutating func pruneExpired(now: Date) -> Bool {
        let expiredKeys = entriesByKey.values.compactMap { entry -> RequestKey? in
            guard let firstSeenAt = entry.firstSeenAt,
                  now.timeIntervalSince(firstSeenAt) >= Self.expiryInterval else { return nil }
            return entry.key
        }
        for key in expiredKeys { entriesByKey.removeValue(forKey: key) }
        return !expiredKeys.isEmpty
    }

    private static func isNewer(_ lhs: NewMessageAreaEntry,
                                than rhs: NewMessageAreaEntry) -> Bool {
        if lhs.acceptanceOrder != rhs.acceptanceOrder {
            return lhs.acceptanceOrder > rhs.acceptanceOrder
        }
        if lhs.key.accountScope != rhs.key.accountScope {
            return lhs.key.accountScope.rawValue < rhs.key.accountScope.rawValue
        }
        if lhs.key.senderID != rhs.key.senderID {
            return lhs.key.senderID.rawValue < rhs.key.senderID.rawValue
        }
        return lhs.key.messageID.rawValue < rhs.key.messageID.rawValue
    }
}

struct NewMessageAreaSummaryKey: Hashable, Sendable {
    let request: RequestKey
    let revision: UInt64
}

struct NewMessageAreaSummaryInput: Sendable {
    let key: RequestKey
    let revision: UInt64
    let text: String
}

enum NewMessageAreaSummaryText {
    static func source(title: String, body: String?) -> String {
        let parts = [title, body].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return parts.joined(separator: "\n")
    }

    static func fallback(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(2)
            .joined(separator: "\n")
    }
}

@MainActor
@Observable
final class NewMessageAreaStore {
    static let defaultsKey = "harklight.new-message-area.v1"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let defaultsKey: String
    @ObservationIgnored private var inFlightSummaries: [NewMessageAreaSummaryKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var currentRevisionByKey: [RequestKey: UInt64] = [:]
    private(set) var ledger: NewMessageAreaLedger
    private(set) var summaries: [NewMessageAreaSummaryKey: String] = [:]

    init(defaults: UserDefaults = .standard, defaultsKey: String = NewMessageAreaStore.defaultsKey) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        if let data = defaults.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(NewMessageAreaLedger.self, from: data) {
            ledger = saved
        } else {
            ledger = NewMessageAreaLedger()
        }
    }

    var entries: [NewMessageAreaEntry] { ledger.entries }
    var nextExpiry: Date? { ledger.nextExpiry }
    var hasMoreThanFiveEntries: Bool { ledger.hasMoreThanFiveEntries }

    func visibleEntries(isExpanded: Bool) -> [NewMessageAreaEntry] {
        ledger.visibleEntries(isExpanded: isExpanded)
    }

    func reconcile(_ messages: [NewMessageAreaMessage], revisions: [RequestKey: UInt64],
                   accountScopes: Set<ExactText> = [], now: Date = .now) {
        let previousLedger = ledger
        let oldEntries = Set(ledger.entriesByKey.keys)
        ledger.reconcile(messages, accountScopes: accountScopes, now: now)
        currentRevisionByKey = revisions
        let activeEntries = Set(ledger.entriesByKey.keys)
        for key in oldEntries.subtracting(activeEntries) { cancelSummaries(for: key) }
        for summaryKey in Array(inFlightSummaries.keys)
            where revisions[summaryKey.request] != summaryKey.revision {
            cancelSummary(summaryKey)
        }
        for summaryKey in Array(summaries.keys)
            where revisions[summaryKey.request] != summaryKey.revision {
            summaries.removeValue(forKey: summaryKey)
        }
        if ledger != previousLedger { persist() }
    }

    func markFirstSeen(_ key: RequestKey, at date: Date = .now) {
        let oldEntries = ledger.entriesByKey
        ledger.markFirstSeen(key, at: date)
        guard oldEntries != ledger.entriesByKey else { return }
        persist()
    }

    func open(_ key: RequestKey) {
        remove(key)
    }

    func remove(_ key: RequestKey) {
        guard ledger.entriesByKey[key] != nil else { return }
        ledger.remove(key)
        cancelSummaries(for: key)
        persist()
    }

    func removeExpired(now: Date = .now) {
        let oldEntries = Set(ledger.entriesByKey.keys)
        guard ledger.pruneExpired(now: now) else { return }
        let activeEntries = Set(ledger.entriesByKey.keys)
        for key in oldEntries.subtracting(activeEntries) { cancelSummaries(for: key) }
        persist()
    }

    func summary(for key: RequestKey, revision: UInt64) -> String? {
        summaries[NewMessageAreaSummaryKey(request: key, revision: revision)]
    }

    func createSummaryIfNeeded(for input: NewMessageAreaSummaryInput) async {
        let summaryKey = NewMessageAreaSummaryKey(request: input.key, revision: input.revision)
        guard ledger.entriesByKey[input.key] != nil,
              currentRevisionByKey[input.key] == input.revision,
              summaries[summaryKey] == nil else { return }
        if let task = inFlightSummaries[summaryKey] {
            await task.value
            return
        }

        let task = Task { [weak self] in
            let result = await OnDeviceMessageSummarizer.summarize(input.text)
            guard let self else { return }
            defer { self.inFlightSummaries[summaryKey] = nil }
            guard !Task.isCancelled,
                  self.ledger.entriesByKey[input.key] != nil,
                  self.currentRevisionByKey[input.key] == input.revision,
                  let result else { return }
            self.summaries[summaryKey] = result
        }
        inFlightSummaries[summaryKey] = task
        await task.value
    }

    private func cancelSummaries(for key: RequestKey) {
        let matchingKeys = inFlightSummaries.keys.filter { $0.request == key }
        for summaryKey in matchingKeys {
            cancelSummary(summaryKey)
            summaries.removeValue(forKey: summaryKey)
        }
    }

    private func cancelSummary(_ key: NewMessageAreaSummaryKey) {
        inFlightSummaries[key]?.cancel()
        inFlightSummaries.removeValue(forKey: key)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

private enum OnDeviceMessageSummarizer {
    static func summarize(_ text: String) async -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            let session = LanguageModelSession(instructions: "Summarize the message in no more than two short lines. Keep its main request and important facts. Do not invent details.")
            do {
                let response = try await session.respond(to: text)
                let result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return result.isEmpty ? nil : result
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }
}
