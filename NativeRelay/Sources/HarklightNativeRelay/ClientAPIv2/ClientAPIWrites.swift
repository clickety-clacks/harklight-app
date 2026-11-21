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
    public static func seen(itemID: ExactText) -> ClientAPIWrite {
        write(itemID, "mark_seen", .post, "seen", body: .object([]))
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

    /// `POST /v2/items/{item_id}/answer` for an answer the person submitted.
    /// `answerUI` is the request's `answer_ui` for the submission's revision.
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
    public static func answer(_ submission: Submission, answerUI: JSONValue?) throws -> ClientAPIWrite {
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
        let senderScreen = answerUI?.uniqueValue(named: "schema")?.stringValue?.rawValue == "attention-client.ui/1"
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
