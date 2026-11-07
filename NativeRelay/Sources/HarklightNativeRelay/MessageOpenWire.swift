import AttentionDomain
import Foundation

public enum MessageOpenOperationResult: Equatable, Sendable {
    /// The relay confirmed that this exact view fact is durable account-wide.
    case confirmed
    /// The relay explicitly rejected this operation permanently.
    case permanentlyRejected(reason: String)
    /// The relay does not recognize this additive operation yet.
    case unsupported
    /// No trustworthy conclusion was received; retain the original operation.
    case unresolved
}

public struct MessageOpenWire: Sendable {
    public static let requestRef = "native-message-open"

    public init() {}

    public func request(for operation: PendingMessageOpen) -> Data {
        let value = JSONValue.object([
            JSONMember("v", .number(JSONNumber(lexeme: "1"))),
            JSONMember("type", .string(ExactText("message_open"))),
            JSONMember("ref", .string(ExactText(Self.requestRef))),
            JSONMember("op_id", .string(ExactText(operation.operationID.uuidString.lowercased()))),
            JSONMember("sender_id", .string(operation.requestKey.senderID)),
            JSONMember("message_id", .string(operation.requestKey.messageID)),
            JSONMember("request_revision", .number(JSONNumber(lexeme: String(operation.requestRevision))))
        ])
        return Data((value.jsonString + "\n").utf8)
    }

    public func decodeResult(_ frame: Data, for operation: PendingMessageOpen) -> MessageOpenOperationResult {
        guard let value = try? JSONValue.parse(frame),
              case .object = value,
              value.hasUniqueObjectKeys,
              value.uniqueValue(named: "v")?.integerValue == 1,
              value.uniqueValue(named: "ref")?.stringValue?.rawValue == Self.requestRef,
              let type = value.uniqueValue(named: "type")?.stringValue?.rawValue else {
            return .unresolved
        }

        switch type {
        case "ok":
            guard value.uniqueValue(named: "op_id")?.stringValue?.rawValue == operation.operationID.uuidString.lowercased(),
                  value.uniqueValue(named: "sender_id")?.stringValue == operation.requestKey.senderID,
                  value.uniqueValue(named: "message_id")?.stringValue == operation.requestKey.messageID,
                  case let .number(revisionNumber)? = value.uniqueValue(named: "request_revision"),
                  UInt64(revisionNumber.lexeme) == operation.requestRevision,
                  value.uniqueValue(named: "opened")?.boolValue == true else {
                return .unresolved
            }
            return .confirmed
        case "error":
            if let returnedOperationID = value.uniqueValue(named: "op_id")?.stringValue?.rawValue,
               returnedOperationID != operation.operationID.uuidString.lowercased() {
                return .unresolved
            }
            guard let reason = value.uniqueValue(named: "reason")?.stringValue?.rawValue.lowercased() else {
                return .unresolved
            }
            if reason == "unknown_type" || reason.contains("unsupported") {
                return .unsupported
            }
            if reason == "invalid_field" || reason == "not_found" {
                return .permanentlyRejected(reason: reason)
            }
            return .unresolved
        default:
            return .unresolved
        }
    }
}
