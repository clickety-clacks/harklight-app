import AttentionDomain
import Foundation

public enum RelayWireError: Error, Equatable {
    case invalidFrame
    case wrongVersion
    case wrongActor
    case unsupportedEvent
}

public enum RelayWireUpdate: Equatable, Sendable {
    case event(RelayEvent)
    /// The relay supplied a sequenced update this build does not understand.
    case ignored(sequence: UInt64)
    /// An unsequenced notice that the account's current inbox view changed.
    case viewChanged(ExactText)
    /// An unsequenced optional notice that cannot be used as a revision hint.
    case ignoredUnsequenced
}

/// Decode the server's authenticated projection without re-encoding sender JSON.
/// The trusted profile, never a wire field, supplies the person/account scope.
public struct RelayWire: Sendable {
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

    /// Decodes ordinary relay updates without stopping replay on a future event
    /// type or lifecycle state. A usable sequence is required to advance safely.
    public func decodeUpdate(_ bytes: Data) throws -> RelayWireUpdate {
        let value = try parseFrame(bytes)
        let eventType = try text(value, "type")
        if eventType == "view_changed" {
            guard let revision = value.uniqueValue(named: "view_rev")?.stringValue,
                  !revision.rawValue.isEmpty else { return .ignoredUnsequenced }
            return .viewChanged(revision)
        }
        let seq = try sequence(value)
        guard seq > 0 else { throw RelayWireError.invalidFrame }
        switch eventType {
        case "delivery":
            return .event(try decodeKnownEvent(value))
        case "attention_tier":
            return .ignored(sequence: seq)
        case "lifecycle":
            let state = try text(value, "state")
            guard TerminalState(rawValue: state) != nil else { return .ignored(sequence: seq) }
            return .event(try decodeKnownEvent(value))
        case "ok", "resynced", "error":
            throw RelayWireError.unsupportedEvent
        default:
            return .ignored(sequence: seq)
        }
    }

    public func decodeEvent(_ bytes: Data) throws -> RelayEvent {
        try decodeKnownEvent(parseFrame(bytes))
    }

    private func decodeKnownEvent(_ value: JSONValue) throws -> RelayEvent {
        let seq = try sequence(value)
        let key = try requestKey(value)
        let origin = try text(value, "origin")
        let isOrigin = origin == profile.identity.deviceID.rawValue
        let conversation = try ConversationWire(profile: profile).ordinaryMetadata(value)
        let eventType = try text(value, "type")
        let accountAnswerOutcome = eventType == "lifecycle"
            ? decodeAccountAnswerOutcome(value.uniqueValue(named: "answer_outcome"))
            : nil
        switch eventType {
        case "delivery":
            if isOrigin {
                guard value.uniqueValue(named: "message") == nil,
                      value.uniqueValue(named: "as") == nil else { throw RelayWireError.invalidFrame }
                return RelayEvent(sequence: seq, body: .originReference(key), conversation: conversation,
                                  origin: ExactText(origin))
            }
            guard let payload = value.uniqueValue(named: "message"),
                  case .object = payload,
                  let classification = RemoteDeliveryClassification(rawValue: try text(value, "as")) else {
                throw RelayWireError.invalidFrame
            }
            return RelayEvent(sequence: seq,
                              body: .delivery(StoredRequest(key: key, originalPayload: payload), classification),
                              conversation: conversation, origin: ExactText(origin))
        case "lifecycle":
            guard let wireState = TerminalState(rawValue: try text(value, "state")) else {
                throw RelayWireError.invalidFrame
            }
            let terminalKind = value.uniqueValue(named: "terminal_kind")?.stringValue?.rawValue
            let state = terminalKind == "no_comment" || accountAnswerOutcome == .noComment
                ? TerminalState.noComment
                : wireState
            guard
                  (isOrigin || value.uniqueValue(named: "answer") == nil),
                  (state != .noComment || value.uniqueValue(named: "answer") == nil) else {
                throw RelayWireError.invalidFrame
            }
            // A present JSON null is distinct from an absent answer in the wire.
            return RelayEvent(sequence: seq,
                              body: .terminal(key, state, value.uniqueValue(named: "answer")),
                              conversation: conversation,
                              accountAnswerOutcome: accountAnswerOutcome)
        case "attention_tier":
            guard seq > 0 else { throw RelayWireError.invalidFrame }
            return RelayEvent(sequence: seq, body: .attentionTierChange(key),
                              origin: ExactText(origin))
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

    /// A stale answer is definite only when the server identifies the rejected
    /// request_revision field and supplies the latest positive revision.
    public func decodeStaleAnswerRevision(_ bytes: Data,
                                          operationID: UUID) throws -> OriginalOperationResult? {
        let value = try parseFrame(bytes)
        guard try text(value, "type") == "error",
              value.uniqueValue(named: "reason")?.stringValue?.rawValue == "stale_revision" else {
            return nil
        }
        guard value.uniqueValue(named: "field")?.stringValue?.rawValue == "request_revision",
              case let .number(revision)? = value.uniqueValue(named: "current_revision"),
              let currentRevision = UInt64(revision.lexeme), currentRevision > 0 else {
            throw RelayWireError.invalidFrame
        }
        return .staleRevision(operationID: operationID, currentRevision: currentRevision)
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

    private func decodeAccountAnswerOutcome(_ raw: JSONValue?) -> AccountAnswerOutcome? {
        guard let raw,
              case .object = raw,
              let kind = raw.uniqueValue(named: "kind")?.stringValue?.rawValue else { return nil }
        switch kind {
        case "seen":
            return .seen
        case "reply":
            guard let text = raw.uniqueValue(named: "text")?.stringValue else { return nil }
            return .reply(text)
        case "no_comment":
            return .noComment
        case "default":
            return .defaultAnswer(value: raw.uniqueValue(named: "value"),
                                  text: raw.uniqueValue(named: "text")?.stringValue)
        default:
            // This optional projection must not prevent the lifecycle event
            // from applying. Unknown values fall back to generic Answered.
            return nil
        }
    }
}
