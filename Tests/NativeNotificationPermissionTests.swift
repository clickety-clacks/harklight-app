import UserNotifications
import XCTest
@testable import Harklight

@MainActor
final class NativeNotificationPermissionTests: XCTestCase {
    func testExistingNotificationPermissionRegistersAgainWithoutAnotherPrompt() async throws {
        var registrations = 0
        var permissionRequests = 0
        let access = NativeNotificationPermission(status: { .authorized }, request: {
            permissionRequests += 1
            return true
        }, register: { registrations += 1 })
        await access.resume { true }
        await access.resume { true }
        XCTAssertEqual(registrations, 2, "Each activation obtains the current app-issued notification address")
        XCTAssertEqual(permissionRequests, 0, "Restoring an authorized installation does not ask the person again")
    }

    func testDelayedPermissionReadCannotRegisterForASupersededInstallation() async throws {
        let (read, reading) = AsyncStream<Void>.makeStream()
        let (release, releasing) = AsyncStream<Void>.makeStream()
        var current = true
        var registered = false
        let access = NativeNotificationPermission(status: {
            reading.yield()
            for await _ in release { break }
            return .authorized
        }, request: { XCTFail("A resumed installation never requests permission"); return false },
        register: { registered = true })
        let resume = Task { await access.resume { current } }
        for await _ in read { break }
        current = false
        releasing.yield()
        await resume.value
        XCTAssertFalse(registered)
    }

    func testNotNowLeavesPermissionUnrequestedAndOnlyDeliberateChoiceCanAsk() async throws {
        var requests = 0
        var registrations = 0
        let access = NativeNotificationPermission(status: { .notDetermined }, request: {
            requests += 1
            return true
        }, register: { registrations += 1 })
        await access.resume { true }
        let skipped = try await access.choose(false) { true }
        XCTAssertFalse(skipped)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(registrations, 0)
        let enabled = try await access.choose(true) { true }
        XCTAssertTrue(enabled)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(registrations, 1)
    }
}
