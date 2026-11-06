import AttentionDomain
import Foundation

enum InboxDuePhrase {
    struct Presentation: Equatable {
        let dayLine: String
        let timeLine: String
        let accessibilityLabel: String
    }

    static func presentation(for milliseconds: Int,
                             now: Date = .now,
                             calendar: Calendar = .current,
                             locale: Locale = .current) -> Presentation {
        let dueAt = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        let today = calendar.startOfDay(for: now)
        let dueDay = calendar.startOfDay(for: dueAt)
        let dayOffset = calendar.dateComponents([.day], from: today, to: dueDay).day
        let timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.calendar = calendar
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.timeStyle = .short
        let time = timeFormatter.string(from: dueAt)
        let pastPrefix = dueAt < now ? "Was due" : "Due"
        let timeLine = String(localized: "at \(time)")

        switch dayOffset {
        case 0:
            return Presentation(
                dayLine: String(localized: "\(pastPrefix) today"),
                timeLine: timeLine,
                accessibilityLabel: String(localized: "\(pastPrefix) today at \(time)"))
        case 1:
            return Presentation(dayLine: String(localized: "Due tomorrow"),
                                timeLine: timeLine,
                                accessibilityLabel: String(localized: "Due tomorrow at \(time)"))
        case -1:
            return Presentation(dayLine: String(localized: "Was due yesterday"),
                                timeLine: timeLine,
                                accessibilityLabel: String(localized: "Was due yesterday at \(time)"))
        default:
            let dateFormatter = DateFormatter()
            dateFormatter.locale = locale
            dateFormatter.calendar = calendar
            dateFormatter.timeZone = calendar.timeZone
            let sameYear = calendar.component(.year, from: dueAt) == calendar.component(.year, from: now)
            dateFormatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
            let date = dateFormatter.string(from: dueAt)
            return Presentation(dayLine: String(localized: "\(pastPrefix) \(date)"),
                                timeLine: timeLine,
                                accessibilityLabel: String(localized: "\(pastPrefix) \(date) at \(time)"))
        }
    }

    static func label(for milliseconds: Int,
                      now: Date = .now,
                      calendar: Calendar = .current,
                      locale: Locale = .current) -> String {
        presentation(for: milliseconds, now: now, calendar: calendar, locale: locale)
            .accessibilityLabel
    }
}

/// An identity-bound row from an ordinary domain projection, with optional local
/// visual metadata. Both sources use the same inbox navigation and card surface.
enum InboxItem: Identifiable {
    case request(InboxRequestRow)
    case example(SampleMessage, SampleResponse)

    var id: InboxSelection {
        switch self {
        case let .request(row): .request(row.key)
        case let .example(message, _): .sample(message.id)
        }
    }

    var resolvedMessageType: HarklightMessageType {
        switch self {
        case let .request(row): row.resolvedMessageType
        case let .example(message, _): message.kind.designMessageType
        }
    }

    func matchesSearch(_ query: String) -> Bool {
        switch self {
        case let .request(row):
            row.title.localizedCaseInsensitiveContains(query) ||
            row.sender.localizedCaseInsensitiveContains(query) ||
            (row.bodyText ?? "").localizedCaseInsensitiveContains(query)
        case let .example(message, _):
            message.title.localizedCaseInsensitiveContains(query) ||
            message.sender.localizedCaseInsensitiveContains(query) ||
            message.body.localizedCaseInsensitiveContains(query)
        }
    }

    @MainActor var belongsToReplied: Bool {
        switch self {
        case let .request(row): row.belongsToReplied
        case let .example(_, response): response.inboxRow?.belongsToReplied ?? response.finished
        }
    }

    @MainActor var canMarkSeen: Bool {
        switch self {
        case let .request(row): row.canMarkSeen
        case let .example(_, response): response.canMarkSeenLocally
        }
    }

    @MainActor var canNoComment: Bool {
        switch self {
        case let .request(row): row.canNoComment
        case let .example(_, response): response.inboxRow?.canNoComment == true
        }
    }

    @MainActor var isRetracted: Bool {
        switch self {
        case let .request(row): row.isRetracted
        case let .example(_, response): response.inboxRow?.isRetracted == true
        }
    }

    @MainActor var noCommentUnavailable: Bool {
        switch self {
        case let .request(row): row.noCommentUnavailable
        case .example: false
        }
    }

    var accessibilityID: String {
        switch self {
        case let .request(row): "request-row-" + row.key.messageID.rawValue
        case let .example(message, _): message.id
        }
    }
}

enum InboxListEntryID: Hashable {
    case row(InboxSelection)
    case thread(firstMember: InboxSelection)
}

enum InboxListEntry: Identifiable {
    case row(InboxItem)
    case thread(thread: ExactText, members: [InboxItem])

    var id: InboxListEntryID {
        switch self {
        case let .row(item): .row(item.id)
        case let .thread(_, members): .thread(firstMember: members[0].id)
        }
    }

    var members: [InboxItem] {
        switch self {
        case let .row(item): [item]
        case let .thread(_, members): members
        }
    }
}

@MainActor
enum InboxThreadListProjection {
    private struct ThreadKey: Equatable {
        let senderID: ExactText
        let thread: ExactText
    }

    static func grouped(_ rows: [InboxItem]) -> [InboxListEntry] {
        var result: [InboxListEntry] = []
        var index = 0
        while index < rows.count {
            guard let key = threadKey(for: rows[index]) else {
                result.append(.row(rows[index]))
                index += 1
                continue
            }
            var members = [rows[index]]
            var next = index + 1
            while next < rows.count, threadKey(for: rows[next]) == key {
                members.append(rows[next])
                next += 1
            }
            if members.count > 1 {
                result.append(.thread(thread: key.thread, members: members))
            } else {
                result.append(.row(rows[index]))
            }
            index = next
        }
        return result
    }

    private static func threadKey(for item: InboxItem) -> ThreadKey? {
        guard case let .request(row) = item,
              !row.isResolved,
              !row.belongsToReplied,
              row.hasInboxViewEntry,
              let thread = row.thread else { return nil }
        return ThreadKey(senderID: row.key.senderID, thread: thread)
    }
}

struct InboxFreeHeading: Hashable {
    enum Kind: Hashable {
        case history, earlierActivity, earlierMessages, earlierChatReplies, unknownOrder
    }

    let state: InboxFreeSection.State
    let kind: Kind

    var title: String {
        switch kind {
        case .history: String(localized: "History")
        case .earlierActivity: String(localized: "Earlier activity")
        case .earlierMessages: String(localized: "Earlier messages")
        case .earlierChatReplies: String(localized: "Earlier chat replies")
        case .unknownOrder: String(localized: "Arrival order unavailable")
        }
    }

    var explanation: String? {
        switch kind {
        case .earlierActivity:
            String(localized: "Earlier messages and chat replies are grouped separately; their combined arrival order is unavailable.")
        case .unknownOrder:
            String(localized: "These chat replies have no verified arrival order. Their position here does not mean they are older than the replies above.")
        default: nil
        }
    }
}

enum InboxNormalListDisplayEntry: Identifiable {
    case message(InboxListEntry)
    case reply(InboxViewListItem)
    case heading(InboxFreeHeading)

    enum ID: Hashable {
        case message(InboxListEntryID)
        case reply(RequestKey)
        case heading(InboxFreeHeading)
    }

    var id: ID {
        switch self {
        case let .message(entry): .message(entry.id)
        case let .reply(item): .reply(item.key)
        case let .heading(heading): .heading(heading)
        }
    }
}

@MainActor
enum InboxNormalListProjection {
    /// Uses the server's mixed sequence when present. The old-server path keeps
    /// the existing message projection. Normal-list membership is independent
    /// of local New membership, so an item can retain its server-ranked row
    /// while it also appears in the compact New area.
    static func entries(rows: [InboxItem],
                        serverItems: [InboxViewListItem]?,
                        freeOrderVersion: Int? = nil,
                        in tab: InboxWorkspaceTab,
                        search: String) -> [InboxNormalListDisplayEntry] {
        guard let serverItems else {
            let visibleMessages = InboxListProjection.filteredRows(rows, in: tab, search: search)
            return InboxThreadListProjection.grouped(visibleMessages).map {
                .message($0)
            }
        }

        var rowsByKey: [RequestKey: InboxRequestRow] = [:]
        var localExamples: [InboxItem] = []
        for item in rows {
            switch item {
            case let .request(row): rowsByKey[row.key] = row
            case .example: localExamples.append(item)
            }
        }

        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFree = tab == .inbox && InboxFreeOrder.isSupported(
            version: freeOrderVersion, items: serverItems)
        var result: [InboxNormalListDisplayEntry] = []
        var pendingMessages: [InboxItem] = []
        var currentSection: InboxFreeSection?
        var headings = Set<InboxFreeHeading>()

        func flushMessages() {
            guard !pendingMessages.isEmpty else { return }
            let entries = isFree && currentSection?.state == .history
                ? pendingMessages.map { InboxListEntry.row($0) }
                : InboxThreadListProjection.grouped(pendingMessages)
            result.append(contentsOf: entries.map {
                .message($0)
            })
            pendingMessages.removeAll(keepingCapacity: true)
        }

        func enterSection(_ section: InboxFreeSection?) {
            guard isFree, let section, section != currentSection else { return }
            flushMessages()
            currentSection = section
            func heading(_ kind: InboxFreeHeading.Kind) {
                let heading = InboxFreeHeading(state: section.state, kind: kind)
                if headings.insert(heading).inserted { result.append(.heading(heading)) }
            }
            if section.state == .history { heading(.history) }
            if section.group != .common { heading(.earlierActivity) }
            switch section.group {
            case .common: break
            case .earlierMessages: heading(.earlierMessages)
            case .earlierChatReplies: heading(.earlierChatReplies)
            case .earlierChatRepliesUnknown:
                heading(.earlierChatReplies)
                heading(.unknownOrder)
            }
        }

        for item in serverItems {
            switch item.kind {
            case .message:
                guard let row = rowsByKey[item.key],
                      isFree || row.belongsToReplied == (tab.messageTab == .replied),
                      query.isEmpty || InboxItem.request(row).matchesSearch(query) else {
                    flushMessages()
                    continue
                }
                enterSection(item.freeSection)
                pendingMessages.append(.request(row))
            case .reply:
                flushMessages()
                guard let unseenCount = item.unseenCount,
                      isFree || (unseenCount == 0 ? tab == .replied : tab == .inbox),
                      matchesReplySearch(item, query: query, rowsByKey: rowsByKey) else { continue }
                enterSection(item.freeSection)
                result.append(.reply(item))
            }
        }
        flushMessages()

        // Local sample rows have no server identity or rank, so keep them after
        // the account projection in sample/demo mode.
        if !localExamples.isEmpty {
            let examples = InboxListProjection.visibleEntries(localExamples, in: tab, search: search)
            result.append(contentsOf: examples.map { .message($0) })
        }
        return result
    }

    private static func matchesReplySearch(_ item: InboxViewListItem,
                                           query: String,
                                           rowsByKey: [RequestKey: InboxRequestRow]) -> Bool {
        guard !query.isEmpty else { return true }
        if let row = rowsByKey[item.key] {
            return InboxItem.request(row).matchesSearch(query)
        }
        return item.key.senderID.rawValue.localizedCaseInsensitiveContains(query) ||
            item.key.messageID.rawValue.localizedCaseInsensitiveContains(query)
    }
}
