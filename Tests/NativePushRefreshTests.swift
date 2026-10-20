import Foundation
import XCTest
@testable import Harklight

@MainActor
private final class PushRefreshScenario {
    var addressAvailable = false
    var attempts = 0
    var registrations = 0
}

final class NativePushRefreshTests: XCTestCase {
    @MainActor
    func testAPNsTokenArrivingDuringRelayResyncGetsASecondRegistrationPass() async {
        let (firstStarted, firstStartedSignal) = AsyncStream<Void>.makeStream()
        let (releaseFirst, releaseFirstSignal) = AsyncStream<Void>.makeStream()
        let (callbackStarted, callbackStartedSignal) = AsyncStream<Void>.makeStream()
        let scenario = PushRefreshScenario()

        let flights = RelayRefreshFlights(inactive: false) {
            scenario.attempts += 1
            let addressSeen = scenario.addressAvailable
            if scenario.attempts == 1 {
                // The first authenticated replay read the protected token
                // before the OS supplied an address.
                firstStartedSignal.yield()
                for await _ in releaseFirst { break }
            }
            if addressSeen { scenario.registrations += 1 }
            return true
        }

        let initial = Task { await flights.coalesced() }
        for await _ in firstStarted { break }
        scenario.addressAvailable = true
        let callback = Task {
            callbackStartedSignal.yield()
            return await flights.afterCurrent()
        }
        for await _ in callbackStarted { break }
        releaseFirstSignal.yield()

        let initialReached = await initial.value
        let callbackReached = await callback.value
        XCTAssertTrue(initialReached)
        XCTAssertTrue(callbackReached)
        XCTAssertEqual(scenario.attempts, 2)
        XCTAssertEqual(scenario.registrations, 1,
                       "A stored token must be registered without waiting for another wake.")
    }

    @MainActor
    func testActivationStatusCheckRunsAfterAnExistingRefreshInsteadOfJoiningIt() async {
        let (firstStarted, firstStartedSignal) = AsyncStream<Void>.makeStream()
        let (releaseFirst, releaseFirstSignal) = AsyncStream<Void>.makeStream()
        var refreshes: [String] = []
        let flights = RelayRefreshFlights(inactive: false) {
            refreshes.append("ordinary")
            firstStartedSignal.yield()
            for await _ in releaseFirst { break }
            return false
        }

        let ordinary = Task { await flights.coalesced() }
        for await _ in firstStarted { break }
        let activation = Task {
            await flights.afterCurrent {
                refreshes.append("activation-status")
                return true
            }
        }
        releaseFirstSignal.yield()

        let ordinaryResult = await ordinary.value
        let activationResult = await activation.value
        XCTAssertFalse(ordinaryResult)
        XCTAssertTrue(activationResult)
        XCTAssertEqual(refreshes, ["ordinary", "activation-status"])
    }
}
