import Foundation
import XCTest
@testable import Harklight

final class DevelopmentAPNsAddressStoreTests: XCTestCase {
    func testProtectedAddressStoreRejectsEmptyAndClearsStaleAddress() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DevelopmentAPNsAddressStore(directory: directory)

        XCTAssertThrowsError(try store.store(Data()))
        XCTAssertNil(try store.load())

        let token = Data([0x00, 0x7f, 0xff] + Array(repeating: UInt8(0x12), count: 29))
        let encoded = "007fff" + String(repeating: "12", count: 29)
        try store.store(token)
        XCTAssertEqual(try store.load(), encoded)

        XCTAssertThrowsError(try store.store(Data()))
        XCTAssertNil(try store.load(),
                     "An empty registration callback must revoke any earlier address.")

        try store.store(Data([0x12, 0x34]))
        try store.clear()
        XCTAssertNil(try store.load())
    }

    func testCorruptStoredAddressCannotBeRegistered() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DevelopmentAPNsAddressStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("device-token.hex")
        try Data("zz".utf8).write(to: file)

        XCTAssertThrowsError(try store.load())
        XCTAssertNil(try store.load())
    }
}
