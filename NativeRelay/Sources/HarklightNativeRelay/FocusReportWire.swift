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

public struct FocusReportReplyFrame: Equatable, Sendable {
    public let ref: String
    public let result: FocusReportReply

    fileprivate init(ref: String, result: FocusReportReply) {
        self.ref = ref
        self.result = result
    }
}

public enum FocusReportWireError: Error, Equatable {
    case invalidResponse
}

/// Encodes and correlates the app-side focus request on the existing relay socket.
/// Shared contract: Harklight focus and push-a-view r5, SHA-256
/// `1b74d561ca8c1fd748e0ccec9acee319ab1d551f7a65292f0f5a5a0cbdc5c88d`.
public struct FocusReportWire: Sendable {
    public init() {}

    public func request(for report: FocusReport, ref: String) throws -> Data {
        let frame = Request(report: report, ref: ref)
        var bytes = try JSONEncoder().encode(frame)
        bytes.append(0x0A)
        return bytes
    }

    public func reply(_ bytes: Data, matching ref: String) throws -> FocusReportReply {
        let frame = try replyFrame(bytes)
        guard frame.ref == ref else { throw FocusReportWireError.invalidResponse }
        return frame.result
    }

    public func replyFrame(_ bytes: Data) throws -> FocusReportReplyFrame {
        guard let value = try? JSONValue.parse(bytes),
              case .object = value,
              value.hasUniqueObjectKeys,
              value.uniqueValue(named: "v")?.integerValue == 1,
              let ref = value.uniqueValue(named: "ref")?.stringValue?.rawValue,
              let type = value.uniqueValue(named: "type")?.stringValue?.rawValue else {
            throw FocusReportWireError.invalidResponse
        }
        switch type {
        case "ok":
            return FocusReportReplyFrame(ref: ref, result: .accepted)
        case "error":
            let reason = value.uniqueValue(named: "reason")?.stringValue?.rawValue
            return FocusReportReplyFrame(ref: ref,
                                         result: reason == "unknown_type" ? .unsupported : .rejected)
        default:
            throw FocusReportWireError.invalidResponse
        }
    }

    private struct Request: Encodable {
        let v = 1
        let type = "focus_report"
        let ref: String
        let screen: String
        let senderID: String?
        let messageID: String?
        let visibleEventID: String?

        enum CodingKeys: String, CodingKey {
            case v
            case type
            case ref
            case screen
            case senderID = "sender_id"
            case messageID = "message_id"
            case visibleEventID = "visible_event_id"
        }

        init(report: FocusReport, ref: String) {
            self.ref = ref
            screen = report.screen.rawValue
            senderID = report.senderID
            messageID = report.messageID
            visibleEventID = report.visibleEventID
        }
    }
}
