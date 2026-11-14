import CryptoKit
import Foundation
import Security
import XCTest
@testable import Harklight

final class NativeJoinInvitationValidationTests: XCTestCase {
    func testInvitationPayloadSizeLocalClockAndEmptyLabelsDoNotRefuseServerInvitation() throws {
        let namespace = "Harklight.invitation-validation-test." + UUID().uuidString
        let identity = try NativeInstallationIdentityStore(namespace: namespace).loadOrCreate()
        defer { deleteIdentity(namespace: namespace, certificateLabel: identity.label) }

        let pem = "-----BEGIN CERTIFICATE-----\n" + String(repeating: " ", count: 70_000) +
            identity.certificateDER.base64EncodedString() + "\n-----END CERTIFICATE-----\n"
        let personID = String(repeating: "p", count: 300)
        let payload: [String: Any] = [
            "v": 1,
            "person_id": personID,
            "server_name": "relay.example.test",
            "enrollment_url": "https://relay.example.test:18444/enroll",
            "relay_url": "wss://relay.example.test:18443/relay",
            "ca_pem": pem,
            "ca_sha256": SHA256.hash(data: identity.certificateDER)
                .map { String(format: "%02x", $0) }.joined(),
            "invite_token": String(repeating: "1", count: 64),
            "expires_at": 1,
            "person_label": String(repeating: "n", count: 300),
            "inviter_label": String(repeating: "o", count: 300)
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertGreaterThan(data.count, 64 * 1024)

        let invitation = try NativeJoinInvitation.decodePayload(data)
        XCTAssertEqual(invitation.personID, personID)
        XCTAssertEqual(invitation.personName?.utf8.count, 300)
        XCTAssertEqual(invitation.inviterName?.utf8.count, 300)
        XCTAssertNoThrow(try invitation.validate(now: .distantFuture))

        var emptyLabels = payload
        emptyLabels["person_label"] = ""
        emptyLabels["inviter_label"] = ""
        let unlabeledInvitation = try NativeJoinInvitation.decodePayload(
            JSONSerialization.data(withJSONObject: emptyLabels))
        XCTAssertEqual(unlabeledInvitation.claimedAccountLabel, NativeJoinInvitation.unnamedAccountPlaceholder)
        XCTAssertEqual(unlabeledInvitation.approvingOwnerLabel, "The server owner")

        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertGreaterThan(encoded.utf8.count, 90_000)
        let url = try XCTUnwrap(URL(string: "harklight://join#" + encoded))
        XCTAssertEqual(try NativeJoinInvitation.decode(url), invitation)
    }

    private func deleteIdentity(namespace: String, certificateLabel: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: namespace] as CFDictionary)
        SecItemDelete([kSecClass as String: kSecClassCertificate,
                       kSecAttrLabel as String: certificateLabel] as CFDictionary)
        let tag = String(certificateLabel.dropLast(".certificate".count))
        SecItemDelete([kSecClass as String: kSecClassKey,
                       kSecAttrApplicationTag as String: Data(tag.utf8)] as CFDictionary)
    }
}
