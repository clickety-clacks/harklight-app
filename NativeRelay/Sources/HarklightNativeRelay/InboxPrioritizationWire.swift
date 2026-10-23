import AttentionDomain
import Foundation

public enum InboxOrderAlgorithm: String, Equatable, Sendable {
    case baseline
    case jevSet = "jev-set"
}

public enum InboxOrderBasis: String, Equatable, Sendable {
    case selected
    case fallback
}

public struct InboxOrderEntry: Equatable, Sendable {
    public let key: RequestKey
    public let reason: String?
    public let dueAtMilliseconds: Int64?

    public init(key: RequestKey, reason: String? = nil, dueAtMilliseconds: Int64? = nil) {
        self.key = key
        self.reason = reason
        self.dueAtMilliseconds = dueAtMilliseconds
    }
}

public struct InboxOrderView: Equatable, Sendable {
    public let revision: String
    public let algorithm: InboxOrderAlgorithm
    public let basis: InboxOrderBasis
    public let entries: [InboxOrderEntry]

    public init(revision: String, algorithm: InboxOrderAlgorithm, basis: InboxOrderBasis,
                entries: [InboxOrderEntry]) {
        self.revision = revision
        self.algorithm = algorithm
        self.basis = basis
        self.entries = entries
    }
}

public enum InboxOrderReply: Equatable, Sendable {
    case view(InboxOrderView)
    case unchanged(revision: String)
    case unsupported
}

public enum InboxPrioritizationWireError: Error, Equatable, Sendable {
    case invalidFrame
    case serverRefused(String)
}

/// The read-only view exchange for the server-owned order of waiting inbox rows.
public struct InboxPrioritizationWire: Sendable {
    private let accountScope: ExactText

    public init(profile: ProfileContext) throws {
        guard profile.transportMode == .relay else { throw InboxPrioritizationWireError.invalidFrame }
        accountScope = profile.identity.personID
    }

    public func viewGet(knownRevision: String?, ref: String) -> Data {
        var fields: [(String, JSONValue)] = [
            ("v", .number(JSONNumber(lexeme: "1"))),
            ("type", .string(ExactText("view_get"))),
            ("ref", .string(ExactText(ref)))
        ]
        if let knownRevision {
            fields.append(("known_view_rev", .string(ExactText(knownRevision))))
        }
        return frame(fields)
    }

    public func decodeViewGetReply(_ bytes: Data, ref: String,
                                   knownRevision: String?) throws -> InboxOrderReply {
        guard let value = try? JSONValue.parse(bytes),
              case .object = value,
              value.hasUniqueObjectKeys,
              value.uniqueValue(named: "v")?.integerValue == 1,
              let type = value.uniqueValue(named: "type")?.stringValue?.rawValue,
              let responseRef = value.uniqueValue(named: "ref")?.stringValue?.rawValue,
              responseRef == ref else {
            throw InboxPrioritizationWireError.invalidFrame
        }
        if type == "error" {
            guard let reason = value.uniqueValue(named: "reason")?.stringValue?.rawValue else {
                throw InboxPrioritizationWireError.invalidFrame
            }
            if reason == "unknown_type" { return .unsupported }
            throw InboxPrioritizationWireError.serverRefused(reason)
        }
        guard type == "ok",
              let revision = value.uniqueValue(named: "view_rev")?.stringValue?.rawValue,
              !revision.isEmpty else {
            throw InboxPrioritizationWireError.invalidFrame
        }
        if value.uniqueValue(named: "unchanged") == .bool(true) {
            guard let knownRevision, revision == knownRevision else {
                throw InboxPrioritizationWireError.invalidFrame
            }
            return .unchanged(revision: revision)
        }
        guard let algorithmText = value.uniqueValue(named: "algorithm")?.stringValue?.rawValue,
              let algorithm = InboxOrderAlgorithm(rawValue: algorithmText),
              let basisText = value.uniqueValue(named: "basis")?.stringValue?.rawValue,
              let basis = InboxOrderBasis(rawValue: basisText),
              let rawEntries = value.uniqueValue(named: "entries")?.arrayValues else {
            throw InboxPrioritizationWireError.invalidFrame
        }
        var entries: [InboxOrderEntry] = []
        var seen = Set<RequestKey>()
        for rawEntry in rawEntries {
            guard case .object = rawEntry,
                  rawEntry.hasUniqueObjectKeys,
                  let senderID = rawEntry.uniqueValue(named: "sender_id")?.stringValue,
                  !senderID.rawValue.isEmpty,
                  let messageID = rawEntry.uniqueValue(named: "message_id")?.stringValue,
                  !messageID.rawValue.isEmpty else {
                throw InboxPrioritizationWireError.invalidFrame
            }
            let reason: String?
            if let rawReason = rawEntry.uniqueValue(named: "reason") {
                guard let text = rawReason.stringValue?.rawValue,
                      (1...200).contains(text.count),
                      !text.contains(where: { $0.isNewline }) else {
                    throw InboxPrioritizationWireError.invalidFrame
                }
                reason = text
            } else {
                reason = nil
            }
            let dueAtMilliseconds: Int64?
            if let rawDueAt = rawEntry.uniqueValue(named: "due_at") {
                guard let milliseconds = rawDueAt.integerValue else {
                    throw InboxPrioritizationWireError.invalidFrame
                }
                dueAtMilliseconds = Int64(milliseconds)
            } else {
                dueAtMilliseconds = nil
            }
            let key = RequestKey(accountScope: accountScope, senderID: senderID, messageID: messageID)
            guard seen.insert(key).inserted else { throw InboxPrioritizationWireError.invalidFrame }
            entries.append(InboxOrderEntry(key: key, reason: reason,
                                           dueAtMilliseconds: dueAtMilliseconds))
        }
        return .view(InboxOrderView(revision: revision, algorithm: algorithm,
                                    basis: basis, entries: entries))
    }

    public func changedRevision(_ bytes: Data) -> String? {
        guard let value = try? JSONValue.parse(bytes),
              case .object = value,
              value.hasUniqueObjectKeys,
              value.uniqueValue(named: "v")?.integerValue == 1,
              value.uniqueValue(named: "type")?.stringValue?.rawValue == "view_changed",
              let revision = value.uniqueValue(named: "view_rev")?.stringValue?.rawValue,
              !revision.isEmpty else {
            return nil
        }
        return revision
    }

    private func frame(_ fields: [(String, JSONValue)]) -> Data {
        let members = fields.map { JSONMember($0.0, $0.1) }
        return Data((JSONValue.object(members).jsonString + "\n").utf8)
    }
}
