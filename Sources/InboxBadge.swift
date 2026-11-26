import UIKit
import UserNotifications

/// Counts ordinary Inbox messages that still need attention. Server-marked
/// Progress messages never count, including when shown as ordinary rows with
/// the Progress flag off, matching the Server's APNs badge. Retracted messages
/// remain visible but do not count. A Seen answer waiting for confirmation
/// stays in Inbox FYIs and does not require attention. Zero clears the badge.
@MainActor
enum InboxBadge {
    static func count(requests: [InboxRequestRow], samples: SampleLibrary,
                      showsLocalExamples: Bool) -> Int {
        let items = showsLocalExamples ? samples.inboxItems(appendingTo: requests)
            : requests.map(InboxItem.request)
        return items.count { item in
            guard !item.isRetracted else { return false }
            if case let .request(row) = item, (row.sharedUnreadChatCount ?? 0) > 0 { return true }
            return !item.hasProgressMarker && !item.belongsToReplied &&
                !item.isSettledFYI && !item.hasPendingSeenAnswer
        }
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
