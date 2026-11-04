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
