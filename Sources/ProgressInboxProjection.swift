import AttentionDomain
import Foundation

@MainActor
enum ProgressInboxProjection {
    static func rows(_ items: [InboxItem], search: String,
                     enabled: Bool = true) -> [InboxRequestRow] {
        guard enabled else { return [] }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.compactMap { item -> InboxRequestRow? in
            guard case let .request(row) = item, row.progress != nil,
                  !row.isResolved, !row.isRetracted,
                  query.isEmpty || item.matchesSearch(query) else { return nil }
            return row
        }.sorted { lhs, rhs in
            let left = lhs.progress?.snapshot?.updatedAt
            let right = rhs.progress?.snapshot?.updatedAt
            if left != right {
                if let left, let right { return left > right }
                return left != nil
            }
            if lhs.key.senderID != rhs.key.senderID {
                return lhs.key.senderID.rawValue.utf8.lexicographicallyPrecedes(rhs.key.senderID.rawValue.utf8)
            }
            return lhs.key.messageID.rawValue.utf8.lexicographicallyPrecedes(rhs.key.messageID.rawValue.utf8)
        }
    }

    static func shown(_ rows: [InboxRequestRow], expanded: Bool) -> [InboxRequestRow] {
        expanded ? rows : Array(rows.prefix(5))
    }
}
