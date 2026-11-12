import AttentionDomain
import Foundation
import SwiftUI
import XCTest
@testable import Harklight
import HarklightNativeRelay

private actor FocusReportCollector {
    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var reports: [FocusReport] = []
    private var waiters: [Waiter] = []

    func append(_ report: FocusReport) {
        reports.append(report)
        var remaining: [Waiter] = []
        for waiter in waiters {
            if reports.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    func waitForCount(_ count: Int) async {
        guard reports.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(count: count, continuation: continuation))
        }
    }

    func snapshot() -> [FocusReport] { reports }
}

@MainActor
final class NativeFocusReporterTests: XCTestCase {
    func testFocusTimingAndBackgroundTransitions() async throws {
        let reporter = NativeFocusReporter()
        let collector = FocusReportCollector()
        let transportID = UUID()
        reporter.installReportHandler(for: transportID) { report in
            await collector.append(report)
        }
        reporter.scenePhaseChanged(.active)
        reporter.relaySessionBecameReady(transportID)
        await collector.waitForCount(1)

        reporter.conversationAppeared(senderID: "sender", messageID: "message", visibility: .noTurns)
        await collector.waitForCount(2)
        reporter.conversationVisibleTurnChanged(
            senderID: "sender", messageID: "message", visibility: .eventID("4182"))
        try await Task.sleep(for: .milliseconds(200))
        var reports = await collector.snapshot()
        XCTAssertEqual(reports.count, 2, "A same-screen visible-turn change waits for the one-second hold.")

        await collector.waitForCount(3)
        reporter.conversationVisibleTurnChanged(
            senderID: "sender", messageID: "message", visibility: .eventID("4182"))
        try await Task.sleep(for: .milliseconds(100))

        reporter.scenePhaseChanged(.inactive)
        reporter.scenePhaseChanged(.active)
        await collector.waitForCount(4)
        reports = await collector.snapshot()
        XCTAssertEqual(reports, [
            .inbox,
            .chat(senderID: "sender", messageID: "message", visibility: .noTurns),
            .chat(senderID: "sender", messageID: "message", visibility: .eventID("4182")),
            .chat(senderID: "sender", messageID: "message", visibility: .eventID("4182"))
        ])
        XCTAssertFalse(reports.contains(.notInFront), "An inactive pass does not report background focus.")

        reporter.scenePhaseChanged(.background)
        await collector.waitForCount(5)
        reporter.scenePhaseChanged(.background)
        try await Task.sleep(for: .milliseconds(50))
        reports = await collector.snapshot()
        XCTAssertEqual(reports.count, 5)
        XCTAssertEqual(reports.last, .notInFront, "Entering the background sends one not_in_front report.")
    }
}
