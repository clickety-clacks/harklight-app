import AttentionDomain
import Foundation

// Focus and held shows over the client API v2 (contract round 11 r4). Only the
// transport changes: the app's focus rules (screen-change reports, the
// one-second in-screen debounce, `not_in_front` on backgrounding) stay in the
// app's focus reporter, which hands each report to `ClientAPIFocusChannel`.

/// A held show for this device: `{show_id, device_id, item_id, target, held_ms}`.
/// `held_ms` is the show's age when the server wrote it.
public struct ClientAPIShow: Equatable, Sendable {
    public let showID: String
    public let deviceID: String
    public let itemID: String
    public let target: ViewShowTarget
    public let heldMilliseconds: UInt64

    public init(showID: String, deviceID: String, itemID: String, target: ViewShowTarget,
                heldMilliseconds: UInt64) {
        self.showID = showID
        self.deviceID = deviceID
        self.itemID = itemID
        self.target = target
        self.heldMilliseconds = heldMilliseconds
    }

    /// Nil for anything malformed, or a target this client does not know.
    public init?(json value: JSONValue) {
        guard case .object = value, value.hasUniqueObjectKeys,
              let showID = value.uniqueValue(named: "show_id")?.stringValue?.rawValue, !showID.isEmpty,
              let deviceID = value.uniqueValue(named: "device_id")?.stringValue?.rawValue, !deviceID.isEmpty,
              let itemID = value.uniqueValue(named: "item_id")?.stringValue?.rawValue, !itemID.isEmpty,
              let target = value.uniqueValue(named: "target")?.stringValue.flatMap({ ViewShowTarget(rawValue: $0.rawValue) }),
              case let .number(held)? = value.uniqueValue(named: "held_ms"),
              let heldMilliseconds = UInt64(held.lexeme) else { return nil }
        self.init(showID: showID, deviceID: deviceID, itemID: itemID, target: target,
                  heldMilliseconds: heldMilliseconds)
    }

    public init?(data: Data) {
        guard let value = try? JSONValue.parse(data) else { return nil }
        self.init(json: value)
    }

    /// When the show was accepted, on this device's clock: receipt minus age.
    public func acceptedAt(receivedAt: Date) -> Date {
        receivedAt.addingTimeInterval(-Double(heldMilliseconds) / 1000)
    }
}

public enum ClientAPIFocusWire {
    public static let path = "/v2/devices/me/focus"

    /// `PUT /v2/devices/me/focus {screen, item_id?, visible_entry_id?, ttl_s}`.
    /// Under v2 a report's message id is the item id and its visible event
    /// is an entry id; the sender is not sent.
    /// `ttl_s` is an integer from 1 to 3600 (focus addendum); 120 is recommended.
    public static let ttlRange = 1...3600

    public static func request(for report: FocusReport, ttlSeconds: Int) -> APIRequest {
        let ttlSeconds = min(max(ttlSeconds, ttlRange.lowerBound), ttlRange.upperBound)
        var members = [JSONMember("screen", .string(ExactText(report.screen.rawValue)))]
        if let itemID = report.messageID { members.append(JSONMember("item_id", .string(ExactText(itemID)))) }
        if let entryID = report.visibleEventID {
            members.append(JSONMember("visible_entry_id", .string(ExactText(entryID))))
        }
        members.append(JSONMember("ttl_s", .number(JSONNumber(lexeme: String(ttlSeconds)))))
        return APIRequest(method: .put, path: path, body: Data(JSONValue.object(members).jsonString.utf8))
    }

    /// The pending show a focus write's response carries, if any. The member
    /// name `show` follows round 11 r4 item 3(a); a response without it, or
    /// with a malformed one, carries none.
    public static func show(inResponse body: Data) -> ClientAPIShow? {
        guard let value = try? JSONValue.parse(body), let show = value.uniqueValue(named: "show") else { return nil }
        return ClientAPIShow(json: show)
    }
}

/// Sends the app's focus reports as v2 focus writes and renews the latest one
/// while the app is in front, so its `ttl_s` never lapses. A renewal resends
/// unchanged fields, which the server treats as liveness only. Shows from the
/// focus response and from the feed reach `onShow` once each, by `show_id`.
/// Nothing here touches the main thread or disk.
public actor ClientAPIFocusChannel {
    public typealias ShowHandler = @Sendable (ClientAPIShow, _ receivedAt: Date) async -> Void

    private let transport: any ClientAPITransport
    private let errors: any ErrorLogging
    private let ttlSeconds: Int
    private let renewEvery: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date
    private let onShow: ShowHandler
    private var latest: FocusReport?
    private var renewal: Task<Void, Never>?
    private var deliveredShows: [String] = []
    private static let rememberedShows = 64

    public init(transport: any ClientAPITransport, errors: any ErrorLogging,
                ttlSeconds: Int = 120, renewEvery: Duration = .seconds(60),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                now: @escaping @Sendable () -> Date = Date.init,
                onShow: @escaping ShowHandler) {
        self.transport = transport
        self.errors = errors
        self.ttlSeconds = min(max(ttlSeconds, ClientAPIFocusWire.ttlRange.lowerBound),
                              ClientAPIFocusWire.ttlRange.upperBound)
        self.renewEvery = renewEvery
        self.sleep = sleep
        self.now = now
        self.onShow = onShow
    }

    /// Sends one report and, while it is an in-front screen, keeps it renewed.
    /// Focus writes are serialized (focus addendum): one is in flight at a
    /// time, and a report made meanwhile replaces any already waiting, so an
    /// older write never lands after a newer one. A replaced report returns
    /// the reply of the write that superseded it.
    @discardableResult
    public func report(_ report: FocusReport) async -> FocusReportReply {
        latest = report
        renewal?.cancel()
        renewal = nil
        let reply = await write(report)
        if let latest, Self.isInFront(latest), renewal == nil { scheduleRenewal(of: latest) }
        return reply
    }

    /// Queues the latest screen without waiting for the current HTTP write.
    public func enqueue(_ report: FocusReport) {
        latest = report
        renewal?.cancel()
        renewal = nil
        waiting = report
        guard !writing else { return }
        writing = true
        Task { await self.sendQueuedReports() }
    }

    private func sendQueuedReports() async {
        guard let first = waiting else {
            writing = false
            return
        }
        waiting = nil
        _ = await drain(startingWith: first)
        if let latest, Self.isInFront(latest), renewal == nil { scheduleRenewal(of: latest) }
    }

    private var writing = false
    private var waiting: FocusReport?
    private var waiters: [CheckedContinuation<FocusReportReply, Never>] = []

    private func write(_ report: FocusReport) async -> FocusReportReply {
        guard !writing else {
            waiting = report
            return await withCheckedContinuation { waiters.append($0) }
        }
        writing = true
        return await drain(startingWith: report)
    }

    private func drain(startingWith report: FocusReport) async -> FocusReportReply {
        var next: FocusReport? = report
        var reply = FocusReportReply.rejected
        while let current = next {
            reply = await send(current)
            next = waiting
            waiting = nil
        }
        writing = false
        let done = waiters
        waiters = []
        done.forEach { $0.resume(returning: reply) }
        return reply
    }

    /// A show that arrived on the change feed (`event: show`).
    public func received(feedShow data: Data) async {
        guard let show = ClientAPIShow(data: data) else {
            errors.report(ErrorLogReport(concern: .sync, connectionRole: .stream, operation: "show",
                phase: "decode", reason: .app("decode_failed"), initiator: .unknown, retryable: false))
            return
        }
        await deliver(show)
    }

    /// Stops renewing, for sign-out or when the connection is torn down.
    public func stop() {
        latest = nil
        renewal?.cancel()
        renewal = nil
    }

    static func isInFront(_ report: FocusReport) -> Bool {
        report.screen != .notInFront && report.screen != .signedOut
    }

    private func send(_ report: FocusReport) async -> FocusReportReply {
        do {
            let response = try await transport.send(ClientAPIFocusWire.request(for: report, ttlSeconds: ttlSeconds))
            errors.resolve(concern: .actions, operation: "focus")
            if let show = ClientAPIFocusWire.show(inResponse: response.body) { await deliver(show) }
            return .accepted
        } catch {
            errors.report(ErrorLogReport(concern: .actions, connectionRole: .request, operation: "focus",
                phase: "send", reason: .api(error), initiator: .forFailure(error),
                retryable: !((error as? APIError)?.isPermanent ?? false),
                correlation: .request((error as? APIError)?.requestID),
                httpStatus: (error as? APIError)?.status))
            return .rejected
        }
    }

    private func scheduleRenewal(of report: FocusReport) {
        renewal?.cancel()
        let interval = renewEvery
        let sleep = self.sleep
        renewal = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                guard let self, await self.isLatest(report) else { return }
                _ = await self.write(report)
            }
        }
    }

    private func isLatest(_ report: FocusReport) -> Bool { latest == report }

    /// The report waiting behind the write in flight, if any (for tests).
    var waitingReport: FocusReport? { waiting }

    private func deliver(_ show: ClientAPIShow) async {
        guard !deliveredShows.contains(show.showID) else { return }
        deliveredShows.append(show.showID)
        if deliveredShows.count > Self.rememberedShows { deliveredShows.removeFirst() }
        await onShow(show, now())
    }
}
