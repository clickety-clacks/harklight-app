import AttentionDomain
import Foundation

public enum InboxPagingWireError: Error, Equatable {
    case invalidFrame
    case serverRefused(String)
}

public struct InboxPageResponse: Equatable, Sendable {
    public let snapshotID: String
    public let highWater: UInt64
    public let items: [InboxSnapshotItem]
    public let nextCursor: String?
    public let receiptCursor: String?

    public init(snapshotID: String, highWater: UInt64, items: [InboxSnapshotItem],
                nextCursor: String?, receiptCursor: String?) {
        self.snapshotID = snapshotID
        self.highWater = highWater
        self.items = items
        self.nextCursor = nextCursor
        self.receiptCursor = receiptCursor
    }
}

public struct InboxReceiptPageResponse: Equatable, Sendable {
    public let highWater: UInt64
    public let events: [RelayEvent]
    public let nextCursor: String?

    public init(highWater: UInt64, events: [RelayEvent], nextCursor: String?) {
        self.highWater = highWater
        self.events = events
        self.nextCursor = nextCursor
    }
}

/// Exact FORMAT17 paging and receipt protocol on the enrolled-device relay.
/// It only constructs read/reconciliation/checkpoint requests; it never sends an answer.
public struct InboxPagingWire: Sendable {
    private let relay: RelayWire
    private let profile: ProfileContext

    public init(profile: ProfileContext) throws {
        guard profile.transportMode == .relay else { throw RelayWireError.wrongActor }
        self.profile = profile
        self.relay = try RelayWire(profile: profile)
    }

    public func inboxStart(startupID: String, since: UInt64, ref: String) -> Data {
        frame([("v", .number(JSONNumber(lexeme: "1"))),
               ("type", .string(ExactText("inbox_start"))),
               ("paging_version", .number(JSONNumber(lexeme: "1"))),
               ("startup_id", .string(ExactText(startupID))),
               ("since", .number(JSONNumber(lexeme: String(since)))),
               ("ref", .string(ExactText(ref)))])
    }

    public func inboxPage(snapshotID: String, cursor: String, ref: String) -> Data {
        frame([("v", .number(JSONNumber(lexeme: "1"))),
               ("type", .string(ExactText("inbox_page"))),
               ("paging_version", .number(JSONNumber(lexeme: "1"))),
               ("snapshot_id", .string(ExactText(snapshotID))),
               ("cursor", .string(ExactText(cursor))),
               ("ref", .string(ExactText(ref)))])
    }

    public func inboxReconcile(snapshotID: String,
                               batchID: String,
                               operations: [JSONValue],
                               ref: String) -> Data {
        frame([("v", .number(JSONNumber(lexeme: "1"))),
               ("type", .string(ExactText("inbox_reconcile"))),
               ("paging_version", .number(JSONNumber(lexeme: "1"))),
               ("snapshot_id", .string(ExactText(snapshotID))),
               ("batch_id", .string(ExactText(batchID))),
               ("operations", .array(operations)),
               ("ref", .string(ExactText(ref)))])
    }

    public func inboxReceipts(snapshotID: String, cursor: String, ref: String) -> Data {
        frame([("v", .number(JSONNumber(lexeme: "1"))),
               ("type", .string(ExactText("inbox_receipts"))),
               ("paging_version", .number(JSONNumber(lexeme: "1"))),
               ("snapshot_id", .string(ExactText(snapshotID))),
               ("cursor", .string(ExactText(cursor))),
               ("ref", .string(ExactText(ref)))])
    }

    public func inboxCheckpointAck(snapshotID: String,
                                   highWater: UInt64,
                                   batchIDs: [String],
                                   ref: String) -> Data {
        frame([("v", .number(JSONNumber(lexeme: "1"))),
               ("type", .string(ExactText("inbox_checkpoint_ack"))),
               ("paging_version", .number(JSONNumber(lexeme: "1"))),
               ("snapshot_id", .string(ExactText(snapshotID))),
               ("high_water", .number(JSONNumber(lexeme: String(highWater)))),
               ("reconciled_batches", .array(batchIDs.map { .string(ExactText($0)) })),
               ("pending_manifest_complete", .bool(true)),
               ("ref", .string(ExactText(ref)))])
    }

    public func inboxCheckpointStatus(snapshotID: String,
                                      since: UInt64,
                                      candidateHighWater: UInt64,
                                      ref: String) -> Data {
        frame([("v", .number(JSONNumber(lexeme: "1"))),
               ("type", .string(ExactText("inbox_attach"))),
               ("paging_version", .number(JSONNumber(lexeme: "1"))),
               ("snapshot_id", .string(ExactText(snapshotID))),
               ("mode", .string(ExactText("checkpoint_status"))),
               ("since", .number(JSONNumber(lexeme: String(since)))),
               ("candidate_high_water", .number(JSONNumber(lexeme: String(candidateHighWater)))),
               ("ref", .string(ExactText(ref)))])
    }

    public func inboxReplayAttach(snapshotID: String, since: UInt64, ref: String) -> Data {
        frame([("v", .number(JSONNumber(lexeme: "1"))),
               ("type", .string(ExactText("inbox_attach"))),
               ("paging_version", .number(JSONNumber(lexeme: "1"))),
               ("snapshot_id", .string(ExactText(snapshotID))),
               ("mode", .string(ExactText("replay"))),
               ("since", .number(JSONNumber(lexeme: String(since)))),
               ("ref", .string(ExactText(ref)))])
    }

    public func decodeStart(_ bytes: Data, ref: String) throws -> InboxPageResponse {
        try decodePage(bytes, ref: ref, expectedSnapshotID: nil, includesReceiptCursor: true)
    }

    public func decodePage(_ bytes: Data, ref: String, snapshotID: String,
                           highWater: UInt64) throws -> InboxPageResponse {
        let page = try decodePage(bytes, ref: ref, expectedSnapshotID: snapshotID, includesReceiptCursor: false)
        guard page.highWater == highWater else { throw InboxPagingWireError.invalidFrame }
        return page
    }

    public func decodeReceipts(_ bytes: Data, ref: String, snapshotID: String,
                               highWater: UInt64) throws -> InboxReceiptPageResponse {
        let value = try success(bytes, ref: ref)
        guard text(value, "snapshot_id") == snapshotID,
              let watermark = uint64(value.uniqueValue(named: "high_water")), watermark == highWater,
              let rawEvents = value.uniqueValue(named: "events")?.arrayValues,
              let next = optionalText(value, "next_cursor") else { throw InboxPagingWireError.invalidFrame }
        var prior: UInt64 = 0
        var events: [RelayEvent] = []
        for raw in rawEvents {
            guard text(raw, "origin") == profile.identity.deviceID.rawValue else {
                throw InboxPagingWireError.invalidFrame
            }
            let event = try relay.decodeEvent(Data((raw.jsonString + "\n").utf8))
            guard event.sequence > prior,
                  case .terminal = event.body else {
                throw InboxPagingWireError.invalidFrame
            }
            prior = event.sequence
            events.append(event)
        }
        return InboxReceiptPageResponse(highWater: highWater, events: events, nextCursor: next)
    }

    public func decodeReconciliation(_ bytes: Data, ref: String, snapshotID: String,
                                     highWater: UInt64, batchID: String,
                                     operationIDs: [UUID]) throws -> [InboxOperationReceipt] {
        let value = try success(bytes, ref: ref)
        guard text(value, "snapshot_id") == snapshotID,
              uint64(value.uniqueValue(named: "high_water")) == highWater,
              text(value, "batch_id") == batchID,
              let rawResults = value.uniqueValue(named: "results")?.arrayValues,
              rawResults.count == operationIDs.count else { throw InboxPagingWireError.invalidFrame }
        var results: [InboxOperationReceipt] = []
        for (raw, expectedID) in zip(rawResults, operationIDs) {
            guard let idText = text(raw, "op_id"),
                  let id = UUID(uuidString: idText), id == expectedID,
                  let statusText = text(raw, "status"),
                  let status = InboxOperationReceiptStatus(rawValue: statusText) else {
                throw InboxPagingWireError.invalidFrame
            }
            let resultValue = raw.uniqueValue(named: "result")
            let terminalValue = raw.uniqueValue(named: "terminal")
            let terminal: RelayEvent?
            if let terminalValue, terminalValue != .null {
                terminal = try relay.decodeEvent(Data((terminalValue.jsonString + "\n").utf8))
                guard case .terminal = terminal?.body else { throw InboxPagingWireError.invalidFrame }
            } else {
                terminal = nil
            }
            switch status {
            case .committed:
                guard let resultValue, case .object = resultValue,
                      resultValue.hasUniqueObjectKeys,
                      text(resultValue, "type") == "ok",
                      resultValue.uniqueValue(named: "v")?.integerValue == 1,
                      resultValue.uniqueValue(named: "duplicate") == .bool(true),
                      uint64(resultValue.uniqueValue(named: "seq")) != nil,
                      let terminal else { throw InboxPagingWireError.invalidFrame }
                results.append(InboxOperationReceipt(operationID: id, status: status,
                    result: resultValue, terminal: terminal))
            case .operationConflict:
                guard resultValue == nil, terminalValue == nil else { throw InboxPagingWireError.invalidFrame }
                results.append(InboxOperationReceipt(operationID: id, status: status))
            case .notCommittedAtSnapshot:
                guard resultValue == nil else { throw InboxPagingWireError.invalidFrame }
                results.append(InboxOperationReceipt(operationID: id, status: status, terminal: terminal))
            }
        }
        return results
    }

    public func decodeCheckpointStatus(_ bytes: Data, ref: String, snapshotID: String,
                                       highWater: UInt64) throws -> Bool {
        let value = try success(bytes, ref: ref)
        guard text(value, "snapshot_id") == snapshotID,
              uint64(value.uniqueValue(named: "high_water")) == highWater,
              value.uniqueValue(named: "replay_started") == .bool(false),
              case let .bool(accepted)? = value.uniqueValue(named: "checkpoint_accepted") else {
            throw InboxPagingWireError.invalidFrame
        }
        return accepted
    }

    public func decodeCheckpointAck(_ bytes: Data, ref: String, snapshotID: String,
                                    highWater: UInt64) throws {
        let value = try success(bytes, ref: ref)
        guard text(value, "snapshot_id") == snapshotID,
              uint64(value.uniqueValue(named: "high_water")) == highWater,
              value.uniqueValue(named: "checkpoint_accepted") == .bool(true) else {
            throw InboxPagingWireError.invalidFrame
        }
    }

    public func isReplayAccepted(_ bytes: Data, ref: String, snapshotID: String,
                                 highWater: UInt64) throws -> Bool {
        let value = try parse(bytes)
        guard text(value, "type") == "ok", text(value, "ref") == ref else { return false }
        guard value.uniqueValue(named: "paging_version")?.integerValue == 1,
              text(value, "snapshot_id") == snapshotID,
              uint64(value.uniqueValue(named: "high_water")) == highWater,
              value.uniqueValue(named: "checkpoint_accepted") == .bool(true),
              value.uniqueValue(named: "replay_started") == .bool(true) else {
            throw InboxPagingWireError.invalidFrame
        }
        return true
    }

    private func decodePage(_ bytes: Data, ref: String, expectedSnapshotID: String?,
                            includesReceiptCursor: Bool) throws -> InboxPageResponse {
        let value = try success(bytes, ref: ref)
        guard let snapshotID = text(value, "snapshot_id"), !snapshotID.isEmpty,
              expectedSnapshotID.map({ $0 == snapshotID }) ?? true,
              let highWater = uint64(value.uniqueValue(named: "high_water")),
              let rawItems = value.uniqueValue(named: "items")?.arrayValues,
              rawItems.count <= 20,
              let next = optionalText(value, "next_cursor") else { throw InboxPagingWireError.invalidFrame }
        let receiptCursor: String?
        if includesReceiptCursor {
            guard let parsed = optionalText(value, "receipt_cursor") else { throw InboxPagingWireError.invalidFrame }
            receiptCursor = parsed
        } else {
            receiptCursor = nil
        }
        var items: [InboxSnapshotItem] = []
        var identities = Set<RequestKey>()
        for raw in rawItems {
            guard let acceptanceValue = raw.uniqueValue(named: "acceptance") else {
                throw InboxPagingWireError.invalidFrame
            }
            let acceptance = try relay.decodeEvent(Data((acceptanceValue.jsonString + "\n").utf8))
            switch acceptance.body {
            case .delivery, .originReference:
                break
            case .terminal:
                throw InboxPagingWireError.invalidFrame
            }
            let terminalValue = raw.uniqueValue(named: "terminal")
            let terminal: RelayEvent?
            if let terminalValue, terminalValue != .null {
                let decoded = try relay.decodeEvent(Data((terminalValue.jsonString + "\n").utf8))
                guard case let .terminal(key, _, _) = decoded.body,
                      key == Self.key(acceptance.body),
                      decoded.sequence > acceptance.sequence,
                      decoded.sequence <= highWater else {
                    throw InboxPagingWireError.invalidFrame
                }
                terminal = decoded
            } else {
                terminal = nil
            }
            let key = Self.key(acceptance.body)
            guard key.accountScope == profile.identity.personID,
                  identities.insert(key).inserted,
                  acceptance.sequence <= highWater else { throw InboxPagingWireError.invalidFrame }
            items.append(InboxSnapshotItem(acceptance: acceptance, terminal: terminal))
        }
        return InboxPageResponse(snapshotID: snapshotID, highWater: highWater, items: items,
                                 nextCursor: next, receiptCursor: receiptCursor)
    }

    private func success(_ bytes: Data, ref: String) throws -> JSONValue {
        let value = try parse(bytes)
        guard text(value, "ref") == ref else { throw InboxPagingWireError.invalidFrame }
        if text(value, "type") == "error" {
            throw InboxPagingWireError.serverRefused(text(value, "reason") ?? "unknown")
        }
        guard text(value, "type") == "ok",
              value.uniqueValue(named: "paging_version")?.integerValue == 1 else {
            throw InboxPagingWireError.invalidFrame
        }
        return value
    }

    private func parse(_ bytes: Data) throws -> JSONValue {
        guard bytes.count <= 2 * (2 * 1024 * 1024) + 16_384,
              let value = try? JSONValue.parse(bytes),
              case .object = value,
              value.hasUniqueObjectKeys,
              value.uniqueValue(named: "v")?.integerValue == 1 else {
            throw InboxPagingWireError.invalidFrame
        }
        return value
    }

    private func frame(_ members: [(String, JSONValue)]) -> Data {
        let value = JSONValue.object(members.map { JSONMember($0.0, $0.1) })
        return Data((value.jsonString + "\n").utf8)
    }

    private func text(_ value: JSONValue, _ key: String) -> String? {
        value.uniqueValue(named: key)?.stringValue?.rawValue
    }

    private func optionalText(_ value: JSONValue, _ key: String) -> String?? {
        guard let member = value.uniqueValue(named: key) else { return nil }
        if member == .null { return .some(nil) }
        guard let string = member.stringValue?.rawValue, !string.isEmpty else { return nil }
        return .some(string)
    }

    private func uint64(_ value: JSONValue?) -> UInt64? {
        guard let value, case let .number(number) = value else { return nil }
        return UInt64(number.lexeme)
    }

    private static func key(_ body: RelayEventBody) -> RequestKey {
        switch body {
        case let .delivery(request, _): request.key
        case let .originReference(key), let .terminal(key, _, _): key
        }
    }

}
