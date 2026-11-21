import Foundation

/// One Server-Sent Event as dispatched by the WHATWG event-stream rules.
public struct ServerSentEvent: Equatable, Sendable {
    public let id: String?
    public let event: String
    public let data: String
}

/// Incremental `text/event-stream` parser. Feed it lines without their line
/// terminator; a blank line dispatches the pending event. Comment lines
/// (heartbeats) and unknown fields are ignored, and an event with no data
/// is not dispatched.
public struct ServerSentEventParser: Sendable {
    private var dataLines: [String] = []
    private var eventName = ""
    /// The last `id` seen, which a reconnect sends as `Last-Event-ID`.
    public private(set) var lastEventID: String?
    private var sawData = false

    public init() {}

    public mutating func feed(line: String) -> ServerSentEvent? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "data":
            dataLines.append(String(value))
            sawData = true
        case "event":
            eventName = String(value)
        case "id":
            if !value.contains("\u{0}") { lastEventID = String(value) }
        default:
            break
        }
        return nil
    }

    private mutating func dispatch() -> ServerSentEvent? {
        defer {
            dataLines.removeAll()
            eventName = ""
            sawData = false
        }
        guard sawData else { return nil }
        return ServerSentEvent(id: lastEventID, event: eventName.isEmpty ? "message" : eventName,
                               data: dataLines.joined(separator: "\n"))
    }
}

extension FeedEvent {
    /// Maps a feed event: `id` is the change's `rev`, `event` its kind and
    /// `data` its JSON. A change without a numeric `id` is malformed.
    public init(_ event: ServerSentEvent) throws {
        if event.event == "heartbeat" {
            // Liveness only: no id, never a log change, never moves the cursor.
            self = .heartbeat
            return
        }
        if event.event == "closing" {
            let object = (try? JSONSerialization.jsonObject(with: Data(event.data.utf8))) as? [String: Any]
            self = .closing(reason: (object?["reason"] as? String) ?? "other")
            return
        }
        if event.event == "show" {
            self = .show(Data(event.data.utf8))
            return
        }
        guard let id = event.id, let rev = Rev(id) else { throw FeedDecodingError.missingRev }
        self = .change(FeedChange(rev: rev, kind: FeedChange.Kind(event.event), data: Data(event.data.utf8)))
    }
}

public enum FeedDecodingError: Error, Equatable {
    case missingRev
    case outOfOrder
    case invalidBatch
}
