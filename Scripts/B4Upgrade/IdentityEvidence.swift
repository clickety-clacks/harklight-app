import CryptoKit
import Foundation
import HarklightNativeRelay
import Security
import XCTest
@testable import Harklight

/// Run in the app test host on both revisions, on the same simulator.
/// Only synthetic enrollment fingerprints leave the app's process.
@MainActor
final class B4UpgradeIdentityEvidence: XCTestCase {
    func testBeforeUpdate() throws {
        let (record, material) = try restoredEnrollment()
        try emitIdentity(phase: "before", record: record, identity: material.keychainIdentity)
    }

    func testAfterUpdate() async throws {
        let (record, material) = try restoredEnrollment()
        // Both revisions store this field under relayPort. This test file is
        // also compiled by 0.1, whose installation material has a relay URL.
        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = record.host
        origin.port = record.relayPort
        let transport = try HTTPSClientAPITransport(baseURL: XCTUnwrap(origin.url),
            clientIdentity: TrustedKeychainIdentity(material.keychainIdentity),
            trustedRootDER: material.trustedRootDER)
        let response = try await transport.send(.get("/v2/me"))
        XCTAssertEqual(response.status, 200)
        let me = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let principal = try XCTUnwrap(me["principal"] as? [String: Any])
        // Report comparisons as booleans to avoid logging principal ids on failure.
        XCTAssertTrue(principal["device_id"] as? String == record.deviceID)
        XCTAssertTrue(principal["person_id"] as? String == record.personID)
        try emitIdentity(phase: "after", record: record, identity: material.keychainIdentity)
    }

    private func restoredEnrollment() throws -> (NativeEnrollmentRecord, NativeInstallationMaterial) {
        let enrollment = NativeEnrollmentStore()
        let record = try XCTUnwrap(enrollment.load())
        XCTAssertTrue(record.isApproved)
        return (record, try enrollment.material(from: record))
    }

    private func emitIdentity(phase: String, record: NativeEnrollmentRecord, identity: SecIdentity) throws {
        var certificate: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(identity, &certificate), errSecSuccess)
        let der = SecCertificateCopyData(try XCTUnwrap(certificate)) as Data
        let publicKey = try XCTUnwrap(DeviceCertificateBinding.fingerprint(der))
        XCTAssertTrue(publicKey == record.deviceID)
        print("B4-UPGRADE phase=\(phase) certificate=\(digest(der)) " +
              "public_key=\(publicKey) device=\(digest(Data(record.deviceID.utf8)))")
    }

    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
