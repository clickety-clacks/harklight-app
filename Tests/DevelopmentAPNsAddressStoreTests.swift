import Foundation
import XCTest
@testable import Harklight

final class DevelopmentAPNsAddressStoreTests: XCTestCase {
    @MainActor
    func testV2CallbackDiscardsTheLegacyCopyAndStoresOnlyInKeychain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacy = DevelopmentAPNsAddressStore(directory: directory)
        let enrollment = NativeEnrollmentStore(service: "push-token-test-" + UUID().uuidString)
        defer {
            try? enrollment.clearV2APNsToken()
            try? FileManager.default.removeItem(at: directory)
        }
        let token = Data(repeating: 0x2a, count: 32)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("device-token.hex")
        try Data("old address".utf8).write(to: file)
        try DevelopmentPushRegistration.persistToken(token, legacyStore: legacy, enrollment: enrollment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try enrollment.v2APNsAddress(), String(repeating: "2a", count: 32))
    }


}
