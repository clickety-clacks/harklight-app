import AttentionDomain
import CryptoKit
import Foundation

public enum DiscussionOperationResult: Equatable, Sendable {
    case accepted(turnID: ExactText)
    case rejected(reason: ExactText)
    case unresolved
}

/// Independent projection on the existing authenticated relay. A conversation
/// sequence is never an ordinary delivery/lifecycle sequence.
public struct ConversationWire: Sendable {
    public let profile: ProfileContext
    public init(profile: ProfileContext) throws {
        guard profile.transportMode == .relay else { throw RelayWireError.wrongActor }
        self.profile = profile
    }
    public func open(since cursor: UInt64) -> Data {
        Data("{\"v\":1,\"type\":\"conversation_open\",\"since\":\(cursor),\"ref\":\"native-conversation-sync\"}\n".utf8)
    }
    public func acknowledge(_ cursor: UInt64) -> Data {
        Data("{\"v\":1,\"type\":\"conversation_ack\",\"conversation_seq\":\(cursor),\"ref\":\"native-conversation-ack\"}\n".utf8)
    }
    /// The caller has already frozen this exact draft operation durably. Upload
    /// references may replace local-copy representations, never original bytes.
    public func discussion(_ draft: ConversationDraft, operationID: UUID,
                           preparedFiles: [ConversationFile], limits: ConversationFileLimits?) throws -> Data {
        guard draft.binding.request.accountScope == profile.identity.personID,
              draft.binding.revision > 0,
              !draft.text.rawValue.isEmpty,
              draft.files.count == preparedFiles.count else { throw RelayWireError.invalidFrame }
        switch draft.disposition {
        case let .submitting(id), let .outcomeUnknown(id), let .acceptedPendingReplay(id, _):
            guard id == operationID else { throw ConversationError.conflict }
        default: throw ConversationError.invalidBinding
        }
        var inlineBytes: UInt64 = 0
        var names = Set<ExactText>()
        var encoded: [JSONValue] = []
        for (original, prepared) in zip(draft.files, preparedFiles) {
            guard original.name == prepared.name, original.byteCount == prepared.byteCount,
                  original.sha256 == prepared.sha256, names.insert(prepared.name).inserted else {
                throw ConversationError.fileMismatch
            }
            var fields = [JSONMember("name", .string(prepared.name))]
            switch prepared.content {
            case let .inline(bytes):
                guard let limits else { throw ConversationError.uploadRequired(prepared.name) }
                guard UInt64(bytes.count) == prepared.byteCount,
                      inlineBytes <= limits.inlineDecodedBytes,
                      prepared.byteCount <= limits.inlineDecodedBytes - inlineBytes,
                      SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == prepared.sha256.rawValue else {
                    throw ConversationError.fileMismatch
                }
                inlineBytes += prepared.byteCount
                fields.append(JSONMember("data_base64", .string(ExactText(bytes.base64EncodedString()))))
            case let .uploaded(id):
                guard UUID(uuidString: id.rawValue) != nil else { throw ConversationError.fileMismatch }
                fields += [JSONMember("upload_id", .string(id)),
                    JSONMember("size", .number(JSONNumber(lexeme: String(prepared.byteCount)))),
                    JSONMember("sha256", .string(prepared.sha256))]
            case .localFile: throw ConversationError.uploadRequired(prepared.name)
            }
            encoded.append(.object(fields))
        }
        let frame = JSONValue.object([
            JSONMember("v", .number(JSONNumber(lexeme: "1"))), JSONMember("type", .string(ExactText("discussion"))),
            JSONMember("ref", .string(ExactText("native-discussion"))),
            JSONMember("op_id", .string(ExactText(operationID.uuidString.lowercased()))),
            JSONMember("sender_id", .string(draft.binding.request.senderID)),
            JSONMember("message_id", .string(draft.binding.request.messageID)),
            JSONMember("request_revision", .number(JSONNumber(lexeme: String(draft.binding.revision)))),
            JSONMember("text", .string(draft.text)), JSONMember("files", .array(encoded))
        ])
        let bytes = Data((frame.jsonString + "\n").utf8)
        guard bytes.count <= 2 * 1024 * 1024 else { throw RelayWireError.invalidFrame }
        return bytes
    }
    public func isOpenAccepted(_ bytes: Data) throws -> Bool {
        let value = try frame(bytes)
        return try text(value, "type") == "ok" && value.uniqueValue(named: "ref")?.stringValue?.rawValue == "native-conversation-sync"
    }
    public func originEndpoint(_ bytes: Data) throws -> URL? {
        guard try isOpenAccepted(bytes) else { throw RelayWireError.invalidFrame }
        let value = try frame(bytes)
        guard value.uniqueValue(named: "origin_https_port") != nil else { return nil }
        let port = try integer(value, "origin_https_port")
        guard port > 0, port <= 65_535 else { throw RelayWireError.invalidFrame }
        var components = URLComponents()
        components.scheme = "https"
        components.host = profile.identity.trustedRelayAuthority.rawValue
        components.port = Int(port)
        components.path = "/origin/v1"
        guard let url = components.url else { throw InstallationTransportError.invalidEndpoint }
        return url
    }
    public func decodeDiscussionResult(_ bytes: Data) throws -> DiscussionOperationResult {
        let value = try frame(bytes)
        guard value.uniqueValue(named: "ref") == .string(ExactText("native-discussion")) else {
            throw RelayWireError.invalidFrame
        }
        switch try text(value, "type") {
        case "ok":
            guard try integer(value, "seq") > 0 else { throw RelayWireError.invalidFrame }
            return .accepted(turnID: ExactText(try text(value, "event_id")))
        case "error": return .rejected(reason: ExactText(try text(value, "reason")))
        default: throw RelayWireError.unsupportedEvent
        }
    }
    public func decodeResynced(_ bytes: Data) throws -> UInt64 {
        let value = try frame(bytes)
        guard try text(value, "type") == "conversation_resynced" else { throw RelayWireError.invalidFrame }
        return try integer(value, "conversation_seq")
    }
    public func decodeEvent(_ bytes: Data) throws -> ConversationEvent {
        let value = try frame(bytes)
        guard try text(value, "type") == "conversation" else { throw RelayWireError.unsupportedEvent }
        let sequence = try integer(value, "conversation_seq"), revision = try integer(value, "request_revision")
        guard sequence > 0, revision > 0 else { throw RelayWireError.invalidFrame }
        let key = RequestKey(accountScope: profile.identity.personID, senderID: ExactText(try text(value, "sender_id")),
            messageID: ExactText(try text(value, "message_id")))
        let binding = ConversationBinding(request: key, revision: revision)
        let origin = try text(value, "origin"), handle = ExactText(try text(value, "session_handle"))
        let kind = try text(value, "kind")
        let fact: ConversationEvent.Fact
        switch kind {
        case "discussion", "reply", "revision", "result":
            guard let author = ConversationAuthor(rawValue: try text(value, "author")),
                  let turnKind = ConversationTurn.Kind(rawValue: kind) else { throw RelayWireError.invalidFrame }
            let redacted = origin == profile.identity.deviceID.rawValue
            if redacted {
                guard value.uniqueValue(named: "text") == nil, value.uniqueValue(named: "message") == nil,
                      value.uniqueValue(named: "files") == nil else { throw RelayWireError.invalidFrame }
            }
            let operation: UUID?
            if let raw = value.uniqueValue(named: "op_id") {
                guard let string = raw.stringValue?.rawValue, let id = UUID(uuidString: string) else { throw RelayWireError.invalidFrame }
                operation = id
            } else { operation = nil }
            let content: ExactText
            if (kind == "discussion" || kind == "reply") && !redacted {
                guard let string = value.uniqueValue(named: "text")?.stringValue else { throw RelayWireError.invalidFrame }
                content = string
            } else { content = ExactText("") }
            let turn = ConversationTurn(id: ExactText(try text(value, "event_id")), binding: binding,
                author: author, sessionHandle: handle, text: content, inReplyTo: try optionalText(value, "in_reply_to"),
                operationID: operation, files: try files(value), contentRedacted: redacted ? true : nil,
                kind: turnKind, resultStatus: kind == "result" ? ExactText(try text(value, "status")) : nil)
            if kind == "revision" {
                if redacted { fact = .redactedRevision(turn) }
                else {
                    guard let payload = value.uniqueValue(named: "message"), case .object = payload else { throw RelayWireError.invalidFrame }
                    fact = .revision(turn, payload: payload)
                }
            } else { fact = .turn(turn) }
        case "receipt":
            guard value.uniqueValue(named: "delivered") == .bool(true) else { throw RelayWireError.invalidFrame }
            fact = .delivered(turn: ExactText(try text(value, "event_id")))
        case "acted": fact = .acted(turn: ExactText(try text(value, "event_id")), by: ExactText(try text(value, "acting_event_id")))
        case "file_transfer":
            let outcome: ConversationFileTransfer
            switch try text(value, "status") {
            case "transferred": outcome = .transferred
            case "not_transferred": outcome = .notTransferred(reason: ExactText(try text(value, "reason")))
            default: throw RelayWireError.invalidFrame
            }
            fact = .fileTransfer(turn: ExactText(try text(value, "event_id")), file: ExactText(try text(value, "file")), outcome)
        case "file_use":
            let outcome: ConversationFileUse
            switch try text(value, "status") {
            case "used": outcome = .used
            case "unusable": outcome = .unusable(reason: try optionalText(value, "reason"))
            default: throw RelayWireError.invalidFrame
            }
            fact = .fileUse(turn: ExactText(try text(value, "event_id")), file: ExactText(try text(value, "file")), outcome)
        case "availability":
            guard value.uniqueValue(named: "event_id") == nil else { throw RelayWireError.invalidFrame }
            fact = .availabilityRecord(sessionHandle: handle, state: try availability(value), support: value.uniqueValue(named: "listening_support"))
        default: throw RelayWireError.unsupportedEvent
        }
        return ConversationEvent(sequence: sequence, binding: binding, fact: fact)
    }
    func ordinaryMetadata(_ value: JSONValue) throws -> RelayConversationMetadata? {
        guard value.uniqueValue(named: "request_revision") != nil else { return nil }
        let revision = try integer(value, "request_revision")
        guard revision > 0 else { throw RelayWireError.invalidFrame }
        let author: ConversationAuthor?
        if let raw = try optionalText(value, "author") {
            guard let parsed = ConversationAuthor(rawValue: raw.rawValue) else { throw RelayWireError.invalidFrame }
            author = parsed
        } else { author = nil }
        return RelayConversationMetadata(revision: revision, sessionHandle: try optionalText(value, "session_handle"),
            eventID: try optionalText(value, "event_id"),
            availability: value.uniqueValue(named: "availability") == nil ? nil : try availability(value),
            listeningSupport: value.uniqueValue(named: "listening_support"), author: author,
            files: value.uniqueValue(named: "files") == nil ? nil : try files(value))
    }
    private func availability(_ value: JSONValue) throws -> ConversationAvailability {
        switch try text(value, "availability") {
        case "listening": return .listening
        case "not_listening": return .notListening(lastDetachedAt: try optionalText(value, "last_detached_at"))
        case "gone": return .gone
        case "unsupported": return .unsupported(reason: try optionalText(value, "unsupported_reason") ?? ExactText("No listening support recorded"))
        default: throw RelayWireError.invalidFrame
        }
    }
    private func files(_ value: JSONValue) throws -> [ConversationFile] {
        guard let raw = value.uniqueValue(named: "files") else { return [] }
        guard let values = raw.arrayValues else { throw RelayWireError.invalidFrame }
        var result: [ConversationFile] = [], names = Set<ExactText>()
        var total: UInt64 = 0
        for item in values {
            let name = ExactText(try text(item, "name"))
            guard names.insert(name).inserted else { throw RelayWireError.invalidFrame }
            let size = try integer(item, "size"), digest = try text(item, "sha256")
            let content: ConversationFile.Content
            switch try text(item, "tier") {
            case "inline":
                guard let encoded = item.uniqueValue(named: "data_base64")?.stringValue?.rawValue,
                      let bytes = Data(base64Encoded: encoded), size == UInt64(bytes.count), size <= 262_144 - total,
                      SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == digest else { throw RelayWireError.invalidFrame }
                total += size
                content = .inline(bytes)
            case "upload":
                let id = try text(item, "upload_id")
                guard UUID(uuidString: id) != nil else { throw RelayWireError.invalidFrame }
                content = .uploaded(ExactText(id))
            default: throw RelayWireError.unsupportedEvent
            }
            result.append(ConversationFile(id: name, name: name, byteCount: size, sha256: ExactText(digest), content: content))
        }
        return result
    }
    private func frame(_ bytes: Data) throws -> JSONValue {
        guard bytes.count <= 2 * (2 * 1024 * 1024) + 16_384,
              let value = try? JSONValue.parse(bytes), case .object = value, value.hasUniqueObjectKeys else { throw RelayWireError.invalidFrame }
        guard value.uniqueValue(named: "v")?.integerValue == 1 else { throw RelayWireError.wrongVersion }
        return value
    }
    private func text(_ value: JSONValue, _ key: String) throws -> String {
        guard let string = value.uniqueValue(named: key)?.stringValue?.rawValue, !string.isEmpty else { throw RelayWireError.invalidFrame }
        return string
    }
    private func optionalText(_ value: JSONValue, _ key: String) throws -> ExactText? {
        guard let field = value.uniqueValue(named: key), field != .null else { return nil }
        if let string = field.stringValue { return string }
        if key == "last_detached_at", case let .number(number) = field { return ExactText(number.lexeme) }
        throw RelayWireError.invalidFrame
    }
    private func integer(_ value: JSONValue, _ key: String) throws -> UInt64 {
        guard case let .number(number)? = value.uniqueValue(named: key), let result = UInt64(number.lexeme) else { throw RelayWireError.invalidFrame }
        return result
    }
}
