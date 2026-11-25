import AttentionDomain
import HarklightNativeRelay

/// Maps the workspace's selected item to the identifiers permitted by the
/// focus-report contract. List screens and local samples carry no item IDs.
enum NativeFocusSelection {
    static func report(for selection: InboxSelection?,
                       path: [RelatedMessageTarget] = [], isReadOnly: Bool = false) -> FocusReport? {
        guard !isReadOnly else { return nil }
        switch path.last {
        case let .fyi(key)?, let .supersedes(key)?, let .replacement(key)?:
            return messageReport(for: key)
        case nil:
            switch selection {
            case let .request(key)?: return messageReport(for: key)
            case .fyis?: return .fyi
            default: return .inbox
            }
        }
    }

    @MainActor
    static func canReportFYIItem(in store: LivePresentationStore?,
                                 relay: NativeRelayLifecycle = .shared) -> Bool {
        guard let store, !store.isReadOnly else { return false }
        let context = store.notificationContext
        return context.transportMode == .relay && relay.isActive(for: context)
    }

    static func messageReport(for key: RequestKey) -> FocusReport {
        .message(senderID: key.senderID.rawValue, messageID: key.messageID.rawValue)
    }
}
