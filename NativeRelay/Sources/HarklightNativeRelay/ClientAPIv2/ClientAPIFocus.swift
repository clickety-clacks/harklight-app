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
    private let waitBeforeRetry: @Sendable (Int) async throws -> Void
    private let onShow: ShowHandler
    private var latest: FocusReport?
    private var renewal: Task<Void, Never>?
    private var retryTimer: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var isClosing = false
    private var rejectsFYIFocus = false
    private var backgroundFailures = 0
    private var deliveredShows: [String] = []
    private static let rememberedShows = 64

    public init(transport: any ClientAPITransport, errors: any ErrorLogging,
                ttlSeconds: Int = 120, renewEvery: Duration = .seconds(60),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                now: @escaping @Sendable () -> Date = Date.init,
                waitBeforeRetry: @escaping @Sendable (Int) async throws -> Void = ChangeFeedSync.backoff,
                onShow: @escaping ShowHandler) {
        self.transport = transport
        self.errors = errors
        self.ttlSeconds = min(max(ttlSeconds, ClientAPIFocusWire.ttlRange.lowerBound),
                              ClientAPIFocusWire.ttlRange.upperBound)
        self.renewEvery = renewEvery
        self.sleep = sleep
        self.now = now
        self.waitBeforeRetry = waitBeforeRetry
        self.onShow = onShow
    }

    /// Sends one report and, while it is an in-front screen, keeps it renewed.
    /// Focus writes are serialized (focus addendum): one is in flight at a
    /// time, and a report made meanwhile replaces any already waiting, so an
    /// older write never lands after a newer one. A replaced report returns
    /// the reply of the write that superseded it.
    @discardableResult
    public func report(_ report: FocusReport) async -> FocusReportReply {
        guard !isClosing, pausedForInternalError != report else { return .rejected }
        return await waitForDelivery(of: report)
    }

    private func waitForDelivery(of report: FocusReport) async -> FocusReportReply {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            replaceLatest(with: report)
        }
    }

    /// Best effort before enrollment removal. A held or offline focus write
    /// cannot keep the person waiting on sign-out.
    public func reportSignedOutBeforeClosing(timeout: Duration = .seconds(2)) async {
        guard !isClosing else { return }
        // A report already handed off by the app must not supersede signed_out.
        isClosing = true
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            self.stop()
        }
        defer { timer.cancel() }
        _ = await waitForDelivery(of: .signedOut)
        stop()
    }

    /// Queues the latest screen without waiting for the current HTTP write.
    public func enqueue(_ report: FocusReport) {
        guard !isClosing, pausedForInternalError != report else { return }
        replaceLatest(with: report)
    }

    private func replaceLatest(with report: FocusReport) {
        pausedForInternalError = nil
        latest = report
        renewal?.cancel()
        renewal = nil
        retryTimer?.cancel()
        retryTimer = nil
        backgroundFailures = 0
        queue(report)
    }

    public func retryInternalError() {
        guard let report = pausedForInternalError else { return }
        pausedForInternalError = nil
        enqueue(report)
    }

    private var pausedForInternalError: FocusReport?
    private var waiting: FocusReport?
    private var waiters: [CheckedContinuation<FocusReportReply, Never>] = []

    /// Timers only queue work. The drain owns HTTP and is canceled only by stop.
    private func queue(_ report: FocusReport) {
        waiting = report
        guard drainTask == nil else { return }
        drainTask = Task { await self.drain() }
    }

    private func drain() async {
        var reply = FocusReportReply.rejected
        while !Task.isCancelled, let current = waiting {
            waiting = nil
            reply = await send(current)
            if current.screen == .notInFront, current == latest, waiting == nil, !Task.isCancelled {
                if reply == .rejected, pausedForInternalError != current {
                    scheduleBackgroundRetry(of: current)
                } else {
                    backgroundFailures = 0
                }
            }
        }
        drainTask = nil
        let done = waiters
        waiters = []
        done.forEach { $0.resume(returning: reply) }
        if let latest, latest != pausedForInternalError, Self.isInFront(latest), renewal == nil {
            scheduleRenewal(of: latest)
        }
    }

    private func scheduleBackgroundRetry(of report: FocusReport) {
        backgroundFailures += 1
        let attempt = backgroundFailures
        let wait = waitBeforeRetry
        retryTimer = Task { [weak self] in
            do { try await wait(attempt) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.backgroundRetryReady(report)
        }
    }

    private func backgroundRetryReady(_ report: FocusReport) {
        guard !Task.isCancelled, report == latest else { return }
        retryTimer = nil
        queue(report)
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

    /// Stops queued writes and renewal without interrupting a write already in flight.
    public func pauseReporting() {
        pausedForInternalError = nil
        latest = nil
        waiting = nil
        renewal?.cancel()
        renewal = nil
        retryTimer?.cancel()
        retryTimer = nil
    }

    /// Stops reporting when the connection is torn down.
    public func stop() {
        pauseReporting()
        drainTask?.cancel()
        let abandoned = waiters
        waiters = []
        abandoned.forEach { $0.resume(returning: .rejected) }
    }

    static func isInFront(_ report: FocusReport) -> Bool {
        report.screen != .notInFront && report.screen != .signedOut
    }

    private func send(_ report: FocusReport) async -> FocusReportReply {
        do {
            let response = try await writeFocus(report)
            errors.resolve(concern: .actions, operation: "focus")
            if let show = ClientAPIFocusWire.show(inResponse: response.body) { await deliver(show) }
            return .accepted
        } catch where Task.isCancelled {
            return .rejected
        } catch {
            let api = error as? APIError
            let internalError = api?.token == .internalError
            if internalError, latest == report {
                pausedForInternalError = report
                renewal?.cancel()
                renewal = nil
                if waiting == report { waiting = nil }
            }
            errors.report(ErrorLogReport(concern: .actions, connectionRole: .request, operation: "focus",
                phase: "send", reason: .api(error), initiator: .forFailure(error),
                retryable: !internalError && api?.isPermanent != true,
                correlation: .request((error as? APIError)?.requestID),
                httpStatus: (error as? APIError)?.status))
            return .rejected
        }
    }

    private func writeFocus(_ report: FocusReport) async throws -> APIResponse {
        let compatibleReport = rejectsFYIFocus && report == .fyi ? .inbox : report
        do {
            return try await transport.send(ClientAPIFocusWire.request(for: compatibleReport,
                                                                      ttlSeconds: ttlSeconds))
        } catch let error as APIError where compatibleReport == .fyi && error.token == .invalidField {
            // Older servers accept the rest of focus and Show with the Inbox code.
            rejectsFYIFocus = true
            return try await transport.send(ClientAPIFocusWire.request(for: .inbox, ttlSeconds: ttlSeconds))
        }
    }

    private func scheduleRenewal(of report: FocusReport) {
        renewal?.cancel()
        let interval = renewEvery
        let sleep = self.sleep
        renewal = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                guard !Task.isCancelled, let self, await self.queueRenewal(report) else { return }
            }
        }
    }

    private func queueRenewal(_ report: FocusReport) -> Bool {
        guard !Task.isCancelled, latest == report, pausedForInternalError != report else { return false }
        queue(report)
        return true
    }

    /// The report waiting behind the write in flight, if any (for tests).
    var waitingReport: FocusReport? { waiting }

    private func deliver(_ show: ClientAPIShow) async {
        guard !deliveredShows.contains(show.showID) else { return }
        deliveredShows.append(show.showID)
        if deliveredShows.count > Self.rememberedShows { deliveredShows.removeFirst() }
        await onShow(show, now())
    }
}
