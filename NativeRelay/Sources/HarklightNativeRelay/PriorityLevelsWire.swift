import AttentionDomain
import Foundation

public enum PriorityLevelsOperationResult: Equatable, Sendable {
    case confirmed([PriorityLevel])
    case permanentlyRejected(String)
    case unsupported
    case unresolved
}

public struct PriorityLevelsWire: Sendable {
    public static let requestRef = "native-priority-levels"

    public init() {}

    public func getRequest() -> Data {
        Data((JSONValue.object([
            JSONMember("v", .number(JSONNumber(lexeme: "1"))),
            JSONMember("type", .string(ExactText("levels_get"))),
            JSONMember("ref", .string(ExactText(Self.requestRef)))
        ]).jsonString + "\n").utf8)
    }

    public func setRequest(for operation: PendingPriorityLevelsSave) -> Data {
        Data((JSONValue.object([
            JSONMember("v", .number(JSONNumber(lexeme: "1"))),
            JSONMember("type", .string(ExactText("levels_set"))),
            JSONMember("ref", .string(ExactText(Self.requestRef))),
            JSONMember("op_id", .string(ExactText(operation.operationID.uuidString.lowercased()))),
            JSONMember("levels", .array(operation.levels.map(levelValue)))
        ]).jsonString + "\n").utf8)
    }

    public func decodeGetResult(_ frame: Data) -> PriorityLevelsOperationResult {
        guard let value = validEnvelope(frame) else { return .unresolved }
        switch value.uniqueValue(named: "type")?.stringValue?.rawValue {
        case "ok":
            guard value.hasExactlyKeys(["v", "type", "ref", "levels"]),
                  let levels = decodeLevels(value.uniqueValue(named: "levels")) else { return .unresolved }
            return .confirmed(levels)
        case "error":
            return errorResult(value)
        default:
            return .unresolved
        }
    }

    public func decodeSetResult(_ frame: Data,
                                for operation: PendingPriorityLevelsSave) -> PriorityLevelsOperationResult {
        guard let value = validEnvelope(frame) else { return .unresolved }
        switch value.uniqueValue(named: "type")?.stringValue?.rawValue {
        case "ok":
            guard value.hasExactlyKeys(["v", "type", "ref", "op_id", "levels"]),
                  value.uniqueValue(named: "op_id")?.stringValue?.rawValue == operation.operationID.uuidString.lowercased(),
                  let levels = decodeLevels(value.uniqueValue(named: "levels")),
                  levels == operation.levels else { return .unresolved }
            return .confirmed(levels)
        case "error":
            return errorResult(value)
        default:
            return .unresolved
        }
    }

    public static func isChangedHint(_ frame: Data) -> Bool {
        guard let value = try? JSONValue.parse(frame),
              case .object = value, value.hasUniqueObjectKeys,
              value.hasExactlyKeys(["v", "type"]),
              value.uniqueValue(named: "v")?.integerValue == 1,
              value.uniqueValue(named: "type")?.stringValue?.rawValue == "levels_changed" else {
            return false
        }
        return true
    }

    private func validEnvelope(_ frame: Data) -> JSONValue? {
        guard let value = try? JSONValue.parse(frame),
              case .object = value, value.hasUniqueObjectKeys,
              value.uniqueValue(named: "v")?.integerValue == 1,
              value.uniqueValue(named: "ref")?.stringValue?.rawValue == Self.requestRef else { return nil }
        return value
    }

    private func errorResult(_ value: JSONValue) -> PriorityLevelsOperationResult {
        guard value.uniqueValue(named: "type")?.stringValue?.rawValue == "error",
              value.uniqueValue(named: "v")?.integerValue == 1,
              value.uniqueValue(named: "ref")?.stringValue?.rawValue == Self.requestRef else { return .unresolved }
        let hasField = value.uniqueValue(named: "field") != nil
        guard (!hasField && value.hasExactlyKeys(["v", "type", "ref", "reason"])) ||
                (hasField && value.hasExactlyKeys(["v", "type", "ref", "reason", "field"])),
              let reason = value.uniqueValue(named: "reason")?.stringValue?.rawValue.lowercased() else {
            return .unresolved
        }
        switch reason {
        case "unknown_type" where !hasField:
            return .unsupported
        case "invalid_field" where hasField:
            guard let field = value.uniqueValue(named: "field")?.stringValue?.rawValue, !field.isEmpty else {
                return .unresolved
            }
            return .permanentlyRejected(reason)
        case "operation_conflict", "forbidden":
            guard !hasField else { return .unresolved }
            return .permanentlyRejected(reason)
        default:
            return .unresolved
        }
    }

    private func levelValue(_ level: PriorityLevel) -> JSONValue {
        .object([
            JSONMember("name", .string(level.name)),
            JSONMember("lower_bound", .number(JSONNumber(lexeme: String(level.lowerBound)))),
            JSONMember("bounce_after_days", level.bounceAfterDays.map {
                .number(JSONNumber(lexeme: String($0)))
            } ?? .null)
        ])
    }

    private func decodeLevels(_ value: JSONValue?) -> [PriorityLevel]? {
        guard let rows = value?.arrayValues else { return nil }
        var levels: [PriorityLevel] = []
        levels.reserveCapacity(rows.count)
        for row in rows {
            guard case .object = row, row.hasUniqueObjectKeys,
                  row.hasExactlyKeys(["name", "lower_bound", "bounce_after_days"]),
                  let name = row.uniqueValue(named: "name")?.stringValue,
                  let lowerLexeme = row.uniqueValue(named: "lower_bound")?.numberLexeme,
                  let lowerBound = Double(lowerLexeme), lowerBound.isFinite,
                  let bounceValue = row.uniqueValue(named: "bounce_after_days") else { return nil }
            let bounceAfterDays: Double?
            if bounceValue == .null {
                bounceAfterDays = nil
            } else {
                guard let lexeme = bounceValue.numberLexeme,
                      let days = Double(lexeme), days.isFinite, days > 0 else { return nil }
                bounceAfterDays = days
            }
            levels.append(PriorityLevel(name: name, lowerBound: lowerBound, bounceAfterDays: bounceAfterDays))
        }
        if levels.isEmpty { return [] }
        let draftRows = levels.map { level in
            PriorityLevelDraftRow(name: level.name.rawValue,
                                  lowerBound: String(level.lowerBound),
                                  bounceAfterDays: level.bounceAfterDays.map { String($0) } ?? "")
        }
        guard PriorityLevelsTableValidation.levels(from: draftRows) == levels else { return nil }
        return levels
    }
}

private extension JSONValue {
    var numberLexeme: String? {
        guard case let .number(number) = self else { return nil }
        return number.lexeme
    }
}
