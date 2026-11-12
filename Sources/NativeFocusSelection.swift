import AttentionDomain
import HarklightNativeRelay

/// Maps the workspace's selected item to the identifiers permitted by the
/// focus-report contract. Local samples and empty selections describe the
/// inbox and never contribute identifiers.
enum NativeFocusSelection {
    static func report(for selection: InboxSelection?) -> FocusReport {
        guard case let .request(key)? = selection else { return .inbox }
        return messageReport(for: key)
    }

    static func messageReport(for key: RequestKey) -> FocusReport {
        .message(senderID: key.senderID.rawValue, messageID: key.messageID.rawValue)
    }
}
