import CoreFoundation
import Foundation
import UserNotifications

/// Presentation uses only the delivered notification. Navigation and account state
/// remain with the app's existing notification response handler.
struct ExpandedNotificationPresentation: Equatable {
    static let singleCategory = "harklight.expanded.single.v1"
    static let batchCategory = "harklight.expanded.batch.v1"

    struct Batch: Equatable {
        let titles: [String]
        let totalCount: Int

        var remainingCount: Int { totalCount - titles.count }
    }

    let title: String
    let subtitle: String
    let body: String
    let batch: Batch?

    init(category: String, title: String, subtitle: String, body: String,
         userInfo: [AnyHashable: Any]) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        if category == Self.batchCategory {
            batch = Self.readBatch(userInfo)
        } else {
            batch = nil
        }
    }

    static func categories() -> Set<UNNotificationCategory> {
        // Leave hidden-preview options unset. Expanding does not grant access
        // to content that the system has withheld under its preview policy.
        Set([singleCategory, batchCategory].map {
            UNNotificationCategory(identifier: $0, actions: [], intentIdentifiers: [], options: [])
        })
    }

    private static func readBatch(_ userInfo: [AnyHashable: Any]) -> Batch? {
        guard let attention = userInfo["attention"] as? [String: Any],
              let expanded = attention["expanded"] as? [String: Any],
              integer(expanded["v"]) == 1,
              let titles = expanded["titles"] as? [String],
              let total = integer(expanded["total_count"]), total >= titles.count else {
            return nil
        }
        return Batch(titles: titles, totalCount: total)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              let result = Int(number.stringValue), result >= 0 else { return nil }
        return result
    }
}
