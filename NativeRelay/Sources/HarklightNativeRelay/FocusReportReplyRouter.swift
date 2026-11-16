import Foundation

enum FocusReportReplyRoute: Equatable {
    case unrelated
    case consumed
    case unsupported
}

/// Keeps focus-report replies out of the ordered exchange response queue.
/// The reader consumes a reply only when its ref belongs to a sent report.
struct FocusReportReplyRouter {
    private var refs = Set<String>()
    private(set) var supportsFocusReports: Bool

    /// `supportsFocusReports` is false when this Server already refused focus
    /// reports on an earlier connection, so this connection sends none.
    init(supportsFocusReports: Bool = true) {
        self.supportsFocusReports = supportsFocusReports
    }

    mutating func register(ref: String) -> Bool {
        guard supportsFocusReports else { return false }
        refs.insert(ref)
        return true
    }

    mutating func remove(ref: String) {
        refs.remove(ref)
    }

    mutating func reset() {
        refs.removeAll(keepingCapacity: false)
        supportsFocusReports = true
    }

    mutating func route(_ bytes: Data, using wire: FocusReportWire) -> FocusReportReplyRoute {
        guard let reply = try? wire.replyFrame(bytes),
              refs.remove(reply.ref) != nil else { return .unrelated }
        guard reply.result == .unsupported, supportsFocusReports else { return .consumed }
        supportsFocusReports = false
        return .unsupported
    }
}
