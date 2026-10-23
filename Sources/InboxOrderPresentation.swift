import AttentionDomain
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

    static func reasons(in view: InboxOrderView?) -> [RequestKey: String] {
        guard let view else { return [:] }
        return Dictionary(view.entries.compactMap { entry in
            entry.reason.map { (entry.key, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    static func showsBasicOrder(in view: InboxOrderView?) -> Bool {
        view?.basis == .fallback
    }
}
