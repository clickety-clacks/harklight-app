import UIKit
import UserNotifications

/// The icon badge counts the Inbox rows that still need attention: the same
/// rows the Inbox tab lists, judged by the same membership rule, so acting on
/// a message moves the badge exactly when it moves the list. A retracted
/// message stays listed with its Retracted marker but no longer needs an
/// answer, so it does not count. Zero clears the badge.
@MainActor
enum InboxBadge {
    static func count(requests: [InboxRequestRow], samples: SampleLibrary,
                      showsLocalExamples: Bool) -> Int {
        let items = showsLocalExamples ? samples.inboxItems(appendingTo: requests)
            : requests.map(InboxItem.request)
        return items.filter { !$0.belongsToReplied && !$0.isRetracted }.count
    }
}

/// Badge permission arrives with the existing notification authorization;
/// there is no separate badge request, so a refusal here is only recorded.
@MainActor
struct NativeIconBadge {
    let apply: @MainActor (Int) async -> Void

    static var system: Self {
        Self(apply: { count in
            do { try await UNUserNotificationCenter.current().setBadgeCount(count) }
            catch { UIDiagnostics.shared.record("badge.apply \(count) error=\(error)") }
        })
    }
}
