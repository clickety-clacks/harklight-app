import AttentionDomain
import Foundation
import HarklightNativeRelay
import Observation

@MainActor
@Observable
final class InboxOrderPresentation {
    private(set) var view: InboxOrderView?
    private(set) var accountScope: AccountScope?

    func prepare(for identity: ProfileIdentity) {
        let nextScope = AccountScope(relayAuthority: identity.trustedRelayAuthority,
                                     personID: identity.personID)
        guard accountScope != nextScope else { return }
        accountScope = nextScope
        view = nil
    }

    func replace(with view: InboxOrderView?) {
        self.view = view
    }
}

enum InboxOrderPresentationRules {
    static func ordered(_ rows: [InboxRequestRow], by view: InboxOrderView?) -> [InboxRequestRow] {
        guard let view else { return rows }
        let waitingRows = rows.filter { !$0.isResolved }
        let resolvedRows = rows.filter(\.isResolved)
        let waitingByKey = Dictionary(waitingRows.map { ($0.key, $0) },
                                      uniquingKeysWith: { first, _ in first })
        var included = Set<RequestKey>()
        let orderedWaiting = view.entries.compactMap { entry -> InboxRequestRow? in
            guard let row = waitingByKey[entry.key], included.insert(entry.key).inserted else { return nil }
            return row
        }
        let remainingWaiting = waitingRows.filter { !included.contains($0.key) }
        return orderedWaiting + remainingWaiting + resolvedRows
    }

    static func reasons(in view: InboxOrderView?) -> [RequestKey: InboxOrderRowReason] {
        guard let view else { return [:] }
        return Dictionary(view.entries.compactMap { entry in
            if let dueAtMilliseconds = entry.dueAtMilliseconds {
                return (entry.key, .dueAtMilliseconds(dueAtMilliseconds))
            }
            return entry.reason.map { (entry.key, .serverText($0)) }
        }, uniquingKeysWith: { first, _ in first })
    }

    static func duePhrase(dueAtMilliseconds: Int64, now: Date = .now,
                          locale: Locale, calendar: Calendar,
                          timeZone: TimeZone) -> String {
        var calendar = calendar
        calendar.locale = locale
        calendar.timeZone = timeZone

        let dueDate = Date(timeIntervalSince1970: TimeInterval(dueAtMilliseconds) / 1_000)
        let nowDay = calendar.startOfDay(for: now)
        let dueDay = calendar.startOfDay(for: dueDate)
        let dayDistance = calendar.dateComponents([.day], from: nowDay, to: dueDay).day
        let day: String
        switch dayDistance {
        case 0:
            day = String(localized: "today", locale: locale,
                         comment: "Relative day in an inbox due-date phrase.")
        case 1:
            day = String(localized: "tomorrow", locale: locale,
                         comment: "Relative day in an inbox due-date phrase.")
        case -1:
            day = String(localized: "yesterday", locale: locale,
                         comment: "Relative day in an inbox due-date phrase.")
        default:
            var dateStyle = Date.FormatStyle(date: .omitted, time: .omitted,
                                             locale: locale, calendar: calendar,
                                             timeZone: timeZone)
                .month(.abbreviated)
                .day()
            if !calendar.isDate(dueDate, equalTo: now, toGranularity: .year) {
                dateStyle = dateStyle.year()
            }
            day = dueDate.formatted(dateStyle)
        }

        let timeStyle = Date.FormatStyle(date: .omitted, time: .shortened,
                                         locale: locale, calendar: calendar,
                                         timeZone: timeZone)
        let time = dueDate.formatted(timeStyle)
        if dueDate < now {
            return String(localized: "Was due \(day) at \(time)", locale: locale,
                          comment: "A past due date shown beneath an inbox request.")
        }
        return String(localized: "Due \(day) at \(time)", locale: locale,
                      comment: "A due date shown beneath an inbox request.")
    }

    static func showsBasicOrder(in view: InboxOrderView?) -> Bool {
        view?.basis == .fallback
    }
}

enum InboxOrderRowReason: Equatable {
    case serverText(String)
    case dueAtMilliseconds(Int64)
}
