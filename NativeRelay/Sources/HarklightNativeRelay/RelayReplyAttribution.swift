import AttentionDomain
import Foundation

/// Names the request a relay error reply answered, for the diagnostics journal.
/// A reply that echoes a `ref` belongs to the request that sent that ref, even
/// when it was sent outside the exchange gate (a focus report). A reply without
/// a ref answers the current gated exchange, which is one request at a time.
struct RelayReplyAttribution {
    struct Request: Equatable {
        let type: NativeDiagnosticRelayRequestType
        let operationID: UUID?
    }

    private var currentExchange: Request?
    private var byRef: [String: Request] = [:]

    /// Records a frame the app sent. `exchange` is false for frames sent
    /// outside the exchange gate, which must not replace the current exchange.
    mutating func noteSent(_ frame: Data, exchange: Bool) {
        let value = try? JSONValue.parse(frame)
        let request = Request(
            type: NativeDiagnosticRelayRequestType(wireType: value?.uniqueValue(named: "type")?.stringValue?.rawValue),
            operationID: value?.uniqueValue(named: "op_id")?.stringValue.flatMap { UUID(uuidString: $0.rawValue) })
        if let ref = value?.uniqueValue(named: "ref")?.stringValue?.rawValue { byRef[ref] = request }
        if exchange { currentExchange = request }
    }

    struct ErrorReply: Equatable {
        let reason: String?
        /// The request it answered, when the app sent one this can match.
        let request: Request?
    }

    /// Returns the error reply this frame is, with the request it answered;
    /// nil for any other frame. Any reply that echoes a ref retires that ref.
    mutating func observeReply(_ frame: Data) -> ErrorReply? {
        guard let value = try? JSONValue.parse(frame) else { return nil }
        let ref = value.uniqueValue(named: "ref")?.stringValue?.rawValue
        let matched = ref.flatMap { byRef.removeValue(forKey: $0) }
        guard value.uniqueValue(named: "type")?.stringValue?.rawValue == "error" else { return nil }
        return ErrorReply(reason: value.uniqueValue(named: "reason")?.stringValue?.rawValue,
                          request: ref == nil ? currentExchange : matched)
    }

    /// Only frames that can be a reply need parsing: an error, or a frame
    /// echoing a ref. Replay entries carry neither, so catch-up skips this.
    static func mayBeReply(_ text: String) -> Bool {
        text.contains("\"error\"") || text.contains("\"ref\"")
    }

    mutating func reset() {
        currentExchange = nil
        byRef.removeAll(keepingCapacity: false)
    }
}

/// Refusal evidence belongs only to the sole active operation exchange, and
/// only if no out-of-gate request could have caused the uncorrelated error.
struct RelayOperationRefusal {
    private var operationID: UUID?
    private var receivedBadFrame = false

    mutating func begin(_ operationID: UUID) {
        self.operationID = operationID
        receivedBadFrame = false
    }

    mutating func end() {
        operationID = nil
        receivedBadFrame = false
    }

    static func isUncorrelatedBadFrame(_ bytes: Data) -> Bool {
        guard let value = try? JSONValue.parse(bytes) else { return false }
        return value.hasUniqueObjectKeys && value.uniqueValue(named: "v")?.integerValue == 1 &&
            value.uniqueValue(named: "type")?.stringValue?.rawValue == "error" &&
            value.uniqueValue(named: "reason")?.stringValue?.rawValue == "bad_frame" &&
            value.uniqueValue(named: "ref") == nil
    }

    mutating func observe(_ frame: Data, hasOtherPendingRequests: Bool) {
        if operationID != nil, !hasOtherPendingRequests, Self.isUncorrelatedBadFrame(frame) {
            receivedBadFrame = true
        }
    }

    mutating func take(for operationID: UUID) -> Bool {
        guard self.operationID == operationID, receivedBadFrame else { return false }
        receivedBadFrame = false
        return true
    }
}
