import Foundation
import XCTest
@testable import Harklight

@MainActor
final class NativeFocusVisibleTurnTests: XCTestCase {
    func testNewestTurnWinsAtBottomAndTallestVisibleTurnWinsAwayFromBottom() {
        let tracker = NativeFocusVisibleTurnTracker()
        tracker.updateVisibleRect(CGRect(x: 0, y: 0, width: 100, height: 100))
        tracker.updateFrame(CGRect(x: 0, y: 0, width: 100, height: 75), for: "older")
        tracker.updateFrame(CGRect(x: 0, y: 75, width: 100, height: 100), for: "newest")

        XCTAssertEqual(tracker.settle(orderedEventIDs: ["older", "newest"],
                                      newestEventID: "newest", isAtNewestTurn: false), "older")
        XCTAssertEqual(tracker.settle(orderedEventIDs: ["older", "newest"],
                                      newestEventID: "newest", isAtNewestTurn: true), "newest")
    }

    func testTurnFramesAreMeasuredOnlyForOneIdleSample() {
        var sampling = NativeFocusScrollSampling()
        XCTAssertTrue(sampling.shouldMeasureTurnFrames, "Initial focus can be measured once.")

        sampling.phaseChanged(isIdle: false)
        XCTAssertFalse(sampling.shouldMeasureTurnFrames)
        sampling.phaseChanged(isIdle: false)
        XCTAssertFalse(sampling.shouldMeasureTurnFrames)

        sampling.phaseChanged(isIdle: true)
        XCTAssertTrue(sampling.shouldMeasureTurnFrames, "Settling enables one final geometry sample.")
        sampling.didMeasureTurnFrames()
        XCTAssertFalse(sampling.shouldMeasureTurnFrames, "Idle layout changes do not resample turn frames.")

        sampling.phaseChanged(isIdle: false)
        sampling.phaseChanged(isIdle: true)
        XCTAssertTrue(sampling.shouldMeasureTurnFrames, "A later scroll gets one new settled sample.")
    }
}
