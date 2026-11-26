import AttentionDomain
import Foundation

/// One client API v2 write, ready for the outbox: the target it is ordered
/// on, the Error Log operation name and the frozen request.
public struct ClientAPIWrite: Equatable, Sendable {
    public let target: String
    public let operation: String
    public let write: FrozenWrite
}

/// Builds the v2 write requests from the local records the app already keeps
/// (`docs/client-api-v2.md` §5). Under the v2 model a request key's message id
/// is the item id.
public enum ClientAPIWrites {
    public enum BuildError: Error, Equatable {
        /// The submission has no v2 answer form (for example an empty or mixed
        /// set of inputs that no answer screen produces).
        case unsupportedAnswer
        case missingRequestRevision
    }

    /// `POST /v2/items/{item_id}/seen`.
    public static func seen(itemID: ExactText, requestRevision: UInt64? = nil) -> ClientAPIWrite {
        let fields = requestRevision.map { [JSONMember("request_revision", .number(JSONNumber(lexeme: String($0))))] } ?? []
        return write(itemID, "mark_seen", .post, "seen", body: .object(fields))
    }

    /// `PUT /v2/items/{item_id}/read-position`.
    public static func readPosition(itemID: ExactText, entryID: ExactText) -> ClientAPIWrite {
        write(itemID, "read_position", .put, "read-position",
              body: .object([JSONMember("entry_id", .string(entryID))]))
    }

    /// `POST /v2/items/{item_id}/replies`: one chat message.
    public static func reply(itemID: ExactText, text: ExactText, fileIDs: [UploadHandle] = []) -> ClientAPIWrite {
        var members = [JSONMember("text", .string(text))]
        if !fileIDs.isEmpty {
            members.append(JSONMember("file_ids", .array(fileIDs.map { .string($0.value) })))
        }
        return write(itemID, "reply", .post, "replies", body: .object(members))
    }

    public static func priorityLevels(_ operation: PendingPriorityLevelsSave) -> ClientAPIWrite? {
        guard let tag = operation.ifMatch, !tag.isEmpty else { return nil }
        let levels: [JSONValue] = operation.levels.map { level in
            .object([
                JSONMember("name", .string(level.name)),
                JSONMember("lower_bound", .number(JSONNumber(lexeme: String(level.lowerBound)))),
                JSONMember("bounce_after_days", level.bounceAfterDays.map {
                    .number(JSONNumber(lexeme: String($0)))
                } ?? .null)
            ])
        }
        let body = JSONValue.object([JSONMember("levels", .array(levels))])
        return ClientAPIWrite(target: "settings", operation: "priority_levels",
            write: FrozenWrite(method: .put, path: "/v2/settings/priority-levels",
                               body: Data(body.jsonString.utf8), ifMatch: tag))
    }

    public static func alerts(_ value: APIAlerts, ifMatch: String) -> ClientAPIWrite {
        let body = JSONValue.object([JSONMember("alerts", .string(ExactText(value.rawValue)))])
        return ClientAPIWrite(target: "settings", operation: "alerts",
            write: FrozenWrite(method: .put, path: "/v2/settings/alerts",
                               body: Data(body.jsonString.utf8), ifMatch: ifMatch))
    }

    /// `POST /v2/items/{item_id}/answer` for an answer the person submitted.
    /// New submissions hold the schema of their bound revision. For older
    /// saves, supply the same revision's `answer_ui` when it is held.
    ///
    /// - No comment sends only `request_revision`.
    /// - A value action, including an FYI's Seen (contract round 10), sends
    ///   `choice` with the action id.
    /// - A text action, and the plain reply an unshowable answer screen
    ///   degrades to, sends `comment`.
    /// - An answer made on an `attention-client.ui/1` screen sends its built
    ///   result as `result`, whatever JSON it is, `null` included, and also
    ///   when the screen has no inputs (round 16). The screen's schema
    ///   decides, never the inputs or the value's shape.
    public static func answer(_ submission: Submission, answerUI: JSONValue? = nil) throws -> ClientAPIWrite {
        guard let revision = submission.requestRevision, revision >= 1 else {
            throw BuildError.missingRequestRevision
        }
        var members = [JSONMember("request_revision", .number(JSONNumber(lexeme: String(revision))))]
        if !submission.isNoComment {
            members.append(try answerMember(submission, answerUI: answerUI))
        }
        return write(submission.requestKey.messageID, "answer", .post, "answer", body: .object(members))
    }

    private static func answerMember(_ submission: Submission, answerUI: JSONValue?) throws -> JSONMember {
        let inputs = submission.typedInputs
        if inputs.count == 1, let only = inputs.first {
            switch only {
            case let .compatibilityValue(action):
                return JSONMember("choice", .string(action))
            case let .compatibilityText(_, text):
                return JSONMember("comment", .string(text))
            default:
                break
            }
        }
        let schema = submission.answerUISchema ?? answerUI?.uniqueValue(named: "schema")?.stringValue
        let senderScreen = schema?.rawValue == "attention-client.ui/1"
        let senderInputs = inputs.allSatisfy {
            switch $0 {
            case .responseValue, .responseText, .text, .point: return true
            case .compatibilityValue, .compatibilityText: return false
            }
        }
        guard senderScreen, senderInputs else { throw BuildError.unsupportedAnswer }
        // Present, so `null` is a structured answer whose value is null.
        return JSONMember("result", submission.answer)
    }

    private static func write(_ itemID: ExactText, _ operation: String, _ method: APIRequest.Method,
                              _ resource: String, body: JSONValue) -> ClientAPIWrite {
        ClientAPIWrite(target: "item:\(itemID.rawValue)", operation: operation,
                       write: FrozenWrite(method: method, path: "/v2/items/\(component(itemID))/\(resource)",
                                          body: Data(body.jsonString.utf8)))
    }

    /// One percent-encoded path segment; the transport does not encode again.
    static func component(_ id: ExactText) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return id.rawValue.addingPercentEncoding(withAllowedCharacters: allowed) ?? id.rawValue
    }
}
