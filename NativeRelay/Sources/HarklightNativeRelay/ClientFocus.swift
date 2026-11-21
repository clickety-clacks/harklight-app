import AttentionDomain
import Foundation

public enum FocusReportScreen: String, Equatable, Sendable {
    case inbox
    case message
    case chat
    case settings
    case signedOut = "signed_out"
    case notInFront = "not_in_front"
}

/// The app's current view, represented only by the identifiers the relay accepts.
public enum FocusReportChatVisibility: Equatable, Sendable {
    case noTurns
    case eventID(String)
}

public struct FocusReport: Equatable, Sendable {
    public let screen: FocusReportScreen
    public let senderID: String?
    public let messageID: String?
    public let visibleEventID: String?

    private init(screen: FocusReportScreen,
                 senderID: String? = nil,
                 messageID: String? = nil,
                 visibleEventID: String? = nil) {
        self.screen = screen
        self.senderID = senderID
        self.messageID = messageID
        self.visibleEventID = visibleEventID
    }

    public static let inbox = Self(screen: .inbox)
    public static let settings = Self(screen: .settings)
    public static let signedOut = Self(screen: .signedOut)
    public static let notInFront = Self(screen: .notInFront)

    public static func message(senderID: String, messageID: String) -> Self {
        Self(screen: .message, senderID: senderID, messageID: messageID)
    }

    public static func chat(senderID: String,
                            messageID: String,
                            visibility: FocusReportChatVisibility) -> Self {
        switch visibility {
        case .noTurns:
            return Self(screen: .chat, senderID: senderID, messageID: messageID)
        case let .eventID(value):
            return Self(screen: .chat, senderID: senderID, messageID: messageID,
                        visibleEventID: value)
        }
    }
}

public enum FocusReportReply: Equatable, Sendable {
    case accepted
    case unsupported
    case rejected
}

public enum ViewShowTarget: String, Equatable, Sendable {
    case message
    case chat
}

public struct ViewShowFrame: Equatable, Sendable {
    public let senderID: String
    public let messageID: String
    public let target: ViewShowTarget
    public let heldMilliseconds: UInt64?
    public let unavailable: Unavailable?

    public enum Unavailable: Equatable, Sendable {
        case notSent
        case notHere
    }

    fileprivate init(senderID: String, messageID: String,
                     target: ViewShowTarget, heldMilliseconds: UInt64?, unavailable: Unavailable? = nil) {
        self.senderID = senderID
        self.messageID = messageID
        self.target = target
        self.heldMilliseconds = heldMilliseconds
        self.unavailable = unavailable
    }
}

extension ViewShowFrame {
    public static func clientAPIUnavailable(_ show: ClientAPIShow, notFound: Bool) -> Self {
        Self(senderID: "", messageID: show.itemID, target: show.target,
             heldMilliseconds: show.heldMilliseconds, unavailable: notFound ? .notSent : .notHere)
    }

    /// A client API v2 show in the shape the pushed-view coordinator already
    /// takes. Under v2 the message id is the item id; the sender is the item's.
    public static func clientAPI(_ show: ClientAPIShow, senderID: String) -> ViewShowFrame {
        ViewShowFrame(senderID: senderID, messageID: show.itemID, target: show.target,
                      heldMilliseconds: show.heldMilliseconds)
    }
}
