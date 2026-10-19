import AttentionDomain
import Foundation
import HarklightNativeRelay

private final class InboxReplayFrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Data] = []

    func append(_ frame: Data) {
        lock.lock(); defer { lock.unlock() }
        stored.append(frame)
    }

    func frames() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

/// The app test target still uses focused fake relay sessions for unrelated
/// conversation and answer tests. Give those fakes an explicit empty paging
/// snapshot and adapt their legacy event fixture into the same replay contract;
/// this code is test-only and is never available to an installed transport.
extension AuthenticatedInboxPagingSession {
    func inboxRequest(_ request: Data, ref: String) async throws -> Data {
        try await emptyInboxReply(request, ref: ref)
    }

    /// The empty paging reply, available to a fake that answers only some
    /// inbox requests itself.
    func emptyInboxReply(_ request: Data, ref: String) async throws -> Data {
        let value = try JSONValue.parse(request)
        guard let kind = value.uniqueValue(named: "type")?.stringValue?.rawValue else {
            throw InstallationTransportError.unexpectedServerFrame
        }
        let since = Self.uint64(value.uniqueValue(named: "since")) ?? 0
        let snapshotID = Self.snapshotID(value, highWater: since)
        var members: [JSONMember] = [
            JSONMember("v", .number(JSONNumber(lexeme: "1"))),
            JSONMember("type", .string(ExactText("ok"))),
            JSONMember("ref", .string(ExactText(ref))),
            JSONMember("paging_version", .number(JSONNumber(lexeme: "1")))
        ]
        switch kind {
        case "inbox_start":
            guard let startupID = value.uniqueValue(named: "startup_id")?.stringValue?.rawValue else {
                throw InstallationTransportError.unexpectedServerFrame
            }
            members += [
                JSONMember("snapshot_id", .string(ExactText("test-\(startupID)-h\(since)"))),
                JSONMember("high_water", .number(JSONNumber(lexeme: String(since)))),
                JSONMember("items", .array([])),
                JSONMember("next_cursor", .null),
                JSONMember("receipt_cursor", .null)
            ]
        case "inbox_reconcile":
            guard let batchID = value.uniqueValue(named: "batch_id")?.stringValue?.rawValue,
                  let operations = value.uniqueValue(named: "operations")?.arrayValues else {
                throw InstallationTransportError.unexpectedServerFrame
            }
            let results = try operations.map { operation -> JSONValue in
                guard let operationID = operation.uniqueValue(named: "op_id")?.stringValue else {
                    throw InstallationTransportError.unexpectedServerFrame
                }
                return .object([
                    JSONMember("op_id", .string(operationID)),
                    JSONMember("status", .string(ExactText("not_committed_at_snapshot")))
                ])
            }
            members += [
                JSONMember("snapshot_id", .string(ExactText(Self.snapshotID(value, highWater: since)))),
                JSONMember("high_water", .number(JSONNumber(lexeme: String(Self.highWater(value))))),
                JSONMember("batch_id", .string(ExactText(batchID))),
                JSONMember("results", .array(results))
            ]
        case "inbox_receipts":
            members += [
                JSONMember("snapshot_id", .string(ExactText(Self.snapshotID(value, highWater: since)))),
                JSONMember("high_water", .number(JSONNumber(lexeme: String(Self.highWater(value))))),
                JSONMember("events", .array([])),
                JSONMember("next_cursor", .null)
            ]
        case "inbox_checkpoint_ack":
            members += [
                JSONMember("snapshot_id", .string(ExactText(Self.text(value, "snapshot_id")))),
                JSONMember("high_water", .number(JSONNumber(lexeme: String(Self.highWater(value))))),
                JSONMember("checkpoint_accepted", .bool(true))
            ]
        case "inbox_attach":
            guard value.uniqueValue(named: "mode")?.stringValue?.rawValue == "checkpoint_status" else {
                throw InstallationTransportError.unexpectedServerFrame
            }
            members += [
                JSONMember("snapshot_id", .string(ExactText(Self.text(value, "snapshot_id")))),
                JSONMember("high_water", .number(JSONNumber(lexeme: String(Self.highWater(value))))),
                JSONMember("checkpoint_accepted", .bool(false)),
                JSONMember("replay_started", .bool(false))
            ]
        case "inbox_page":
            members += [
                JSONMember("snapshot_id", .string(ExactText(Self.text(value, "snapshot_id")))),
                JSONMember("high_water", .number(JSONNumber(lexeme: String(Self.highWater(value))))),
                JSONMember("items", .array([])),
                JSONMember("next_cursor", .null)
            ]
        default:
            throw InstallationTransportError.unexpectedServerFrame
        }
        return Data((JSONValue.object(members).jsonString + "\n").utf8)
    }

    func attachInboxReplay(_ request: Data, ref: String,
                           consume: @Sendable (Data) async throws -> Void) async throws {
        let value = try JSONValue.parse(request)
        let since = Self.uint64(value.uniqueValue(named: "since")) ?? 0
        let snapshotID = Self.text(value, "snapshot_id")
        let highWater = Self.snapshotHighWater(snapshotID) ?? since
        let legacyRequest = Data("{\"v\":1,\"type\":\"resync\",\"since\":\(since),\"ref\":\"native-sync\"}\n".utf8)
        let collector = InboxReplayFrameCollector()
        try await resync(legacyRequest) { collector.append($0) }
        let frames = collector.frames()
        try await consume(Data((JSONValue.object([
            JSONMember("v", .number(JSONNumber(lexeme: "1"))),
            JSONMember("type", .string(ExactText("ok"))),
            JSONMember("ref", .string(ExactText(ref))),
            JSONMember("paging_version", .number(JSONNumber(lexeme: "1"))),
            JSONMember("snapshot_id", .string(ExactText(snapshotID))),
            JSONMember("high_water", .number(JSONNumber(lexeme: String(highWater)))),
            JSONMember("checkpoint_accepted", .bool(true)),
            JSONMember("replay_started", .bool(true))
        ]).jsonString + "\n").utf8))
        if frames.isEmpty {
            try await consume(Data("{\"v\":1,\"type\":\"resynced\",\"seq\":\(since)}\n".utf8))
            return
        }
        for frame in frames {
            let incoming = try JSONValue.parse(frame)
            switch incoming.uniqueValue(named: "type")?.stringValue?.rawValue {
            case "ok":
                continue
            case "error":
                throw InstallationTransportError.serverRejected
            default:
                try await consume(frame)
            }
        }
    }

    private static func uint64(_ value: JSONValue?) -> UInt64? {
        guard case let .number(number)? = value else { return nil }
        return UInt64(number.lexeme)
    }

    private static func text(_ value: JSONValue, _ key: String) -> String {
        value.uniqueValue(named: key)?.stringValue?.rawValue ?? ""
    }

    private static func snapshotID(_ value: JSONValue, highWater: UInt64) -> String {
        if let snapshot = value.uniqueValue(named: "snapshot_id")?.stringValue?.rawValue {
            return snapshot
        }
        return "test-unknown-h\(highWater)"
    }

    private static func snapshotHighWater(_ snapshotID: String) -> UInt64? {
        guard let marker = snapshotID.range(of: "-h", options: .backwards) else { return nil }
        return UInt64(snapshotID[marker.upperBound...])
    }

    private static func highWater(_ value: JSONValue) -> UInt64 {
        snapshotHighWater(text(value, "snapshot_id")) ?? uint64(value.uniqueValue(named: "high_water")) ?? 0
    }
}
