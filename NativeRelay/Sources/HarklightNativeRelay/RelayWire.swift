import AttentionDomain
import Foundation

public enum RelayWireError: Error, Equatable {
    case invalidFrame
    case wrongVersion
    case wrongActor
    case unsupportedEvent
}

/// Decode the server's authenticated projection without re-encoding sender JSON.
/// The trusted profile, never a wire field, supplies the person/account scope.
public struct RelayWire {
    public let profile: ProfileContext

    public init(profile: ProfileContext) throws {
        guard profile.transportMode == .relay else { throw RelayWireError.wrongActor }
        self.profile = profile
    }

    public func resync(since cursor: UInt64) -> Data {
        Data("{\"v\":1,\"type\":\"resync\",\"since\":\(cursor),\"ref\":\"native-sync\"}\n".utf8)
    }

    public func acknowledge(_ cursor: UInt64) -> Data {
        Data("{\"v\":1,\"type\":\"ack\",\"seq\":\(cursor),\"ref\":\"native-ack\"}\n".utf8)
    }

    public func decodeEvent(_ bytes: Data) throws -> RelayEvent {
        let value = try parseFrame(bytes)
        let seq = try sequence(value)
        let key = try requestKey(value)
        let origin = try text(value, "origin")
        let isOrigin = origin == profile.identity.deviceID.rawValue
        let conversation = try ConversationWire(profile: profile).ordinaryMetadata(value)
        switch try text(value, "type") {
        case "delivery":
            if isOrigin {
                guard value.uniqueValue(named: "message") == nil,
                      value.uniqueValue(named: "as") == nil else { throw RelayWireError.invalidFrame }
                return RelayEvent(sequence: seq, body: .originReference(key), conversation: conversation)
            }
            guard let payload = value.uniqueValue(named: "message"),
                  case .object = payload,
                  let classification = RemoteDeliveryClassification(rawValue: try text(value, "as")) else {
                throw RelayWireError.invalidFrame
            }
            return RelayEvent(sequence: seq,
                              body: .delivery(StoredRequest(key: key, originalPayload: payload), classification), conversation: conversation)
        case "lifecycle":
            guard let state = TerminalState(rawValue: try text(value, "state")),
                  (isOrigin || value.uniqueValue(named: "answer") == nil) else {
                throw RelayWireError.invalidFrame
            }
            // A present JSON null is distinct from an absent answer in the wire.
            return RelayEvent(sequence: seq,
                              body: .terminal(key, state, value.uniqueValue(named: "answer")), conversation: conversation)
        default:
            throw RelayWireError.unsupportedEvent
        }
    }

    public func decodeResynced(_ bytes: Data) throws -> UInt64 {
        let value = try parseFrame(bytes)
        guard try text(value, "type") == "resynced" else { throw RelayWireError.invalidFrame }
        return try sequence(value)
    }

    /// Returns a definite answer refusal only when the v1 error includes the
    /// server's matching retracted terminal snapshot.
    public func decodeAnswerRefusal(_ bytes: Data, operationID: UUID) throws -> OriginalOperationResult? {
        let value = try parseFrame(bytes)
        guard try text(value, "type") == "error",
              value.uniqueValue(named: "reason")?.stringValue?.rawValue == "retracted" else {
            return nil
        }
        guard let terminal = value.uniqueValue(named: "terminal"),
              case .object = terminal,
              terminal.hasUniqueObjectKeys,
              terminal.uniqueValue(named: "state")?.stringValue?.rawValue == "retracted",
              case let .number(timestamp)? = terminal.uniqueValue(named: "retracted_at"),
              let retractedAtMilliseconds = UInt64(timestamp.lexeme) else {
            throw RelayWireError.invalidFrame
        }
        return .refusedByRetraction(operationID: operationID,
                                    retractedAtMilliseconds: retractedAtMilliseconds)
    }

    public func isResyncAccepted(_ bytes: Data) throws -> Bool {
        let value = try parseFrame(bytes)
        return try text(value, "type") == "ok" &&
            value.uniqueValue(named: "ref")?.stringValue?.rawValue == "native-sync"
    }

    private func parseFrame(_ bytes: Data) throws -> JSONValue {
        guard bytes.count <= 2 * (2 * 1024 * 1024) + 16_384,
              let value = try? JSONValue.parse(bytes),
              case .object = value,
              value.hasUniqueObjectKeys else { throw RelayWireError.invalidFrame }
        guard value.uniqueValue(named: "v")?.integerValue == 1 else { throw RelayWireError.wrongVersion }
        return value
    }

    private func text(_ value: JSONValue, _ name: String) throws -> String {
        guard let result = value.uniqueValue(named: name)?.stringValue?.rawValue,
              !result.isEmpty else { throw RelayWireError.invalidFrame }
        return result
    }

    private func sequence(_ value: JSONValue) throws -> UInt64 {
        guard let raw = value.uniqueValue(named: "seq"),
              case let .number(number) = raw,
              let seq = UInt64(number.lexeme) else { throw RelayWireError.invalidFrame }
        return seq
    }

    private func requestKey(_ value: JSONValue) throws -> RequestKey {
        RequestKey(accountScope: profile.identity.personID,
                   senderID: ExactText(try text(value, "sender_id")),
                   messageID: ExactText(try text(value, "message_id")))
    }
}
