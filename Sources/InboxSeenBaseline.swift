import AttentionDomain
import Foundation

/// Captures exactly which requests were already saved when this build first
/// opened the inbox. Placement is local display state; it does not create a
/// Seen receipt or change the saved request.
struct InboxSeenBaseline {
    private let existingAcceptanceOrders: Set<UInt64>

    /// Deterministic UI fixture only. It exercises the same row projection as
    /// a first-run snapshot without persisting or altering fixture requests.
    static func fixture(existingAcceptanceOrders: [UInt64]) -> InboxSeenBaseline {
        InboxSeenBaseline(existingAcceptanceOrders: Set(existingAcceptanceOrders))
    }

    static func capture(identity: ProfileIdentity,
                        acceptanceOrders: [UInt64],
                        defaults: UserDefaults = .standard) -> InboxSeenBaseline {
        let key = storageKey(for: identity)
        if defaults.object(forKey: key) != nil {
            let stored = defaults.stringArray(forKey: key) ?? []
            return InboxSeenBaseline(existingAcceptanceOrders: Set(stored.compactMap(UInt64.init)))
        }

        let existingAcceptanceOrders = Set(acceptanceOrders)
        defaults.set(existingAcceptanceOrders.sorted().map(String.init), forKey: key)
        return InboxSeenBaseline(existingAcceptanceOrders: existingAcceptanceOrders)
    }

    func selects(acceptanceOrder: UInt64) -> Bool {
        existingAcceptanceOrders.contains(acceptanceOrder)
    }

    private init(existingAcceptanceOrders: Set<UInt64>) {
        self.existingAcceptanceOrders = existingAcceptanceOrders
    }

    private static func storageKey(for identity: ProfileIdentity) -> String {
        ["harklight.inbox.seen-baseline.v2",
         identity.trustedRelayAuthority.rawValue,
         identity.personID.rawValue,
         identity.deviceID.rawValue].joined(separator: "\u{1f}")
    }
}
