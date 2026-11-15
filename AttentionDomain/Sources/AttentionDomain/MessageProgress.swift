import Foundation

/// The current ordinary revision carries the entire bar. No local history is
/// consulted, and malformed marked FYIs remain Progress for routing/counting.
public enum MessageProgress: Equatable, Sendable {
    case unavailable
    case available(ProgressSnapshot)

    public var snapshot: ProgressSnapshot? {
        guard case let .available(value) = self else { return nil }
        return value
    }

    public static func read(from message: JSONValue) -> MessageProgress? {
        guard message.uniqueValue(named: "message_type")?.stringValue == ExactText("fyi"),
              message.objectMembers?.contains(where: { $0.key == ExactText("progress") }) == true else {
            return nil
        }
        guard let raw = message.uniqueValue(named: "progress"),
              let snapshot = ProgressSnapshot(raw) else { return .unavailable }
        return .available(snapshot)
    }
}

public struct ProgressSnapshot: Equatable, Sendable {
    public let updatedAt: Date
    public let percent: Double
    public let stage: String
    public let note: String?
    public let visits: [ProgressVisit]

    public var legend: [String] {
        var seen = Set<ExactText>()
        return visits.map(\.stage).filter { seen.insert(ExactText($0)).inserted }
    }

    fileprivate init?(_ raw: JSONValue) {
        guard progressNoteIsValid(raw.uniqueValue(named: "note")),
              let updatedAt = progressDate(raw.uniqueValue(named: "updated_at")),
              let percent = progressNumber(raw.uniqueValue(named: "percent")),
              (0...100).contains(percent),
              let stage = progressStage(raw.uniqueValue(named: "stage")),
              let entries = raw.uniqueValue(named: "segments")?.arrayValues else { return nil }
        let visits = entries.compactMap(ProgressVisit.init)
        guard visits.count == entries.count else { return nil }
        let total = visits.reduce(0) { $0 + $1.width }
        guard total.isFinite, abs(total - percent) < 0.000001 else { return nil }
        self.percent = percent
        self.stage = stage
        self.note = raw.uniqueValue(named: "note")?.stringValue?.rawValue
        self.visits = visits
        self.updatedAt = updatedAt
    }
}

public struct ProgressVisit: Equatable, Sendable {
    public let stage: String
    public let width: Double
    public let note: String?
    public let visitAt: Date?
    public let reportedPercent: Double?
    public let delta: Double?

    fileprivate init?(_ raw: JSONValue) {
        guard progressNoteIsValid(raw.uniqueValue(named: "note")),
              let stage = progressStage(raw.uniqueValue(named: "stage")),
              let width = progressNumber(raw.uniqueValue(named: "width")),
              (0...100).contains(width) else { return nil }
        self.stage = stage
        self.width = width
        self.note = raw.uniqueValue(named: "note")?.stringValue?.rawValue
        self.visitAt = progressDate(raw.uniqueValue(named: "visit_at"))
        self.reportedPercent = progressNumber(raw.uniqueValue(named: "reported_percent"))
            .flatMap { (0...100).contains($0) ? $0 : nil }
        self.delta = progressNumber(raw.uniqueValue(named: "delta"))
            .flatMap { (-100...100).contains($0) ? $0 : nil }
    }
}

private func progressNumber(_ raw: JSONValue?) -> Double? {
    guard case let .number(number) = raw,
          let value = Double(number.lexeme), value.isFinite else { return nil }
    return value
}

private func progressStage(_ raw: JSONValue?) -> String? {
    guard let stage = raw?.stringValue?.rawValue,
          !stage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return stage
}

private func progressDate(_ raw: JSONValue?) -> Date? {
    guard let text = raw?.stringValue?.rawValue else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
}

private func progressNoteIsValid(_ raw: JSONValue?) -> Bool {
    switch raw {
    case nil, .null, .string: true
    default: false
    }
}
