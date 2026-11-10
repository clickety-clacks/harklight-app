import Foundation

public struct PriorityLevel: Equatable, Codable, Sendable {
    public let name: ExactText
    public let lowerBound: Double
    public let bounceAfterDays: Double?

    public init(name: ExactText, lowerBound: Double, bounceAfterDays: Double?) {
        self.name = name
        self.lowerBound = lowerBound
        self.bounceAfterDays = bounceAfterDays
    }
}

/// Editable values stay textual so an incomplete local draft can survive an
/// offline edit without pretending it is an applied table.
public struct PriorityLevelDraftRow: Equatable, Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var lowerBound: String
    public var bounceAfterDays: String

    public init(id: UUID = UUID(), name: String = "", lowerBound: String = "",
                bounceAfterDays: String = "") {
        self.id = id
        self.name = name
        self.lowerBound = lowerBound
        self.bounceAfterDays = bounceAfterDays
    }

    public init(level: PriorityLevel) {
        id = UUID()
        name = level.name.rawValue
        lowerBound = String(level.lowerBound)
        bounceAfterDays = level.bounceAfterDays.map { String($0) } ?? ""
    }
}

public struct PendingPriorityLevelsSave: Equatable, Codable, Sendable {
    public let operationID: UUID
    public let levels: [PriorityLevel]
    public let sourceDraftRevision: UInt64

    public init(operationID: UUID = UUID(), levels: [PriorityLevel], sourceDraftRevision: UInt64) {
        self.operationID = operationID
        self.levels = levels
        self.sourceDraftRevision = sourceDraftRevision
    }
}

/// Per-account local state. `confirmedLevels == nil` means no server read has
/// succeeded yet; an empty array is the server's explicit unconfigured table.
public struct PriorityLevelsStoreState: Equatable, Codable, Sendable {
    public var confirmedLevels: [PriorityLevel]?
    public var draftRows: [PriorityLevelDraftRow]?
    public var draftRevision: UInt64
    public var pendingSave: PendingPriorityLevelsSave?
    public var editorWasOpened: Bool
    public var failureReason: String?

    public init(confirmedLevels: [PriorityLevel]? = nil,
                draftRows: [PriorityLevelDraftRow]? = nil,
                draftRevision: UInt64 = 0,
                pendingSave: PendingPriorityLevelsSave? = nil,
                editorWasOpened: Bool = false,
                failureReason: String? = nil) {
        self.confirmedLevels = confirmedLevels
        self.draftRows = draftRows
        self.draftRevision = draftRevision
        self.pendingSave = pendingSave
        self.editorWasOpened = editorWasOpened
        self.failureReason = failureReason
    }

    public static let empty = PriorityLevelsStoreState()

    public var displayedRows: [PriorityLevelDraftRow] {
        draftRows ?? []
    }
}

public enum PriorityLevelsTableValidation {
    public static func levels(from rows: [PriorityLevelDraftRow]) -> [PriorityLevel]? {
        guard !rows.isEmpty else { return nil }
        var levels: [PriorityLevel] = []
        levels.reserveCapacity(rows.count)

        for row in rows {
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  let lowerBound = parseNumber(row.lowerBound),
                  lowerBound.isFinite, (0...1).contains(lowerBound) else { return nil }
            let bounceAfterDays: Double?
            if row.bounceAfterDays.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bounceAfterDays = nil
            } else {
                guard let days = parseNumber(row.bounceAfterDays), days.isFinite, days > 0 else { return nil }
                bounceAfterDays = days
            }
            levels.append(PriorityLevel(name: ExactText(row.name),
                                        lowerBound: lowerBound,
                                        bounceAfterDays: bounceAfterDays))
        }

        guard levels.first?.lowerBound == 0 else { return nil }
        for index in 1..<levels.count where levels[index - 1].lowerBound >= levels[index].lowerBound {
            return nil
        }
        return levels
    }

    public static func message(for rows: [PriorityLevelDraftRow]) -> LocalizedStringResource? {
        guard !rows.isEmpty else { return "Add at least one level before saving." }
        if rows.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Give every level a name."
        }
        if rows.contains(where: { parseNumber($0.lowerBound).map { !$0.isFinite || !(0...1).contains($0) } ?? true }) {
            return "Enter a starting priority from 0 to 1 for every level."
        }
        if rows.contains(where: {
            let text = $0.bounceAfterDays.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && (parseNumber(text).map { !$0.isFinite || $0 <= 0 } ?? true)
        }) {
            return "Enter a positive number of days, or leave the interval blank to disable bounce for that level."
        }
        guard let levels = levels(from: rows), levels.first?.lowerBound == 0 else {
            return "Order the levels by starting priority, beginning at 0, with no repeated bounds."
        }
        return nil
    }

    private static func parseNumber(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let number = Double(trimmed) { return number }
        // Decimal keyboards follow the current locale. JSON on the wire always
        // uses a period, but accepting a single comma here keeps the text field
        // usable in comma-decimal locales.
        guard !trimmed.contains("."), trimmed.filter({ $0 == "," }).count == 1 else { return nil }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }
}
