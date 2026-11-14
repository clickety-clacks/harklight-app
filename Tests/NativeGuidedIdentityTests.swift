import Foundation
import HarklightNativeRelay
import Security
import XCTest
@testable import Harklight

final class NativeGuidedIdentityTests: XCTestCase {
    func testJoinCreatesACertificateForThePrivateKeyRetainedOnThisDevice() throws {
        let namespace = "Harklight.guided-identity-test." + UUID().uuidString
        defer { removeTestIdentity(namespace) }
        let material = try NativeInstallationIdentityStore(namespace: namespace).loadOrCreate()
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, material.certificateDER as CFData))
        let expectedNotAfter = Data([0x18, 0x0f]) + Data("99991231235959Z".utf8)
        XCTAssertNotNil(material.certificateDER.range(of: expectedNotAfter))
        XCTAssertEqual(DeviceCertificateBinding.fingerprint(material.certificateDER), material.deviceID)
        var privateKey: SecKey?
        XCTAssertEqual(SecIdentityCopyPrivateKey(material.value, &privateKey), errSecSuccess)
        let key = try XCTUnwrap(privateKey)
        let challenge = Data("Prove this installation owns its enrolled certificate".utf8)
        let signature = try XCTUnwrap(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                                         challenge as CFData, nil))
        let publicKey = try XCTUnwrap(SecCertificateCopyKey(certificate))
        XCTAssertTrue(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                           challenge as CFData, signature, nil))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(false, nil), &trust), errSecSuccess)
        let clientTrust = try XCTUnwrap(trust)
        XCTAssertEqual(SecTrustSetAnchorCertificates(clientTrust, [certificate] as CFArray), errSecSuccess)
        XCTAssertEqual(SecTrustSetAnchorCertificatesOnly(clientTrust, true), errSecSuccess)
        XCTAssertTrue(SecTrustEvaluateWithError(clientTrust, nil))
    }

    func testInterruptedOrExpiredJoinKeepsTheSameDeviceIdentity() throws {
        let namespace = "Harklight.guided-identity-test." + UUID().uuidString
        defer { removeTestIdentity(namespace) }
        let first = try NativeInstallationIdentityStore(namespace: namespace).loadOrCreate()
        let restored = try NativeInstallationIdentityStore(namespace: namespace).loadOrCreate()
        XCTAssertEqual(restored.deviceID, first.deviceID)
        XCTAssertEqual(restored.certificateDER, first.certificateDER)
        var certificate: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(restored.value, &certificate), errSecSuccess)
        XCTAssertEqual(SecCertificateCopyData(try XCTUnwrap(certificate)) as Data, first.certificateDER)
    }

    func testExistingOneYearCertificateIsReissuedForTheSameDeviceKey() throws {
        let namespace = "Harklight.guided-identity-test." + UUID().uuidString
        let keyNamespace = namespace + ".key." + UUID().uuidString
        defer { removeTestIdentity(keyNamespace) }
        let store = NativeInstallationIdentityStore(namespace: keyNamespace)
        let original = try store.loadOrCreate()

        var retainedPrivateKey: SecKey?
        XCTAssertEqual(SecIdentityCopyPrivateKey(original.value, &retainedPrivateKey), errSecSuccess)
        let privateKey = try XCTUnwrap(retainedPrivateKey)
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let publicDER = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let legacyDER = try NativeInstallationIdentityStore.selfSignedCertificate(
            publicKeyDER: publicDER,
            privateKey: privateKey,
            notAfter: Date().addingTimeInterval(365 * 24 * 60 * 60))
        let legacyCertificate = try XCTUnwrap(SecCertificateCreateWithData(nil, legacyDER as CFData))
        let labelQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: original.label
        ]
        XCTAssertEqual(SecItemDelete(labelQuery as CFDictionary), errSecSuccess)
        let legacyAttributes: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: legacyCertificate,
            kSecAttrLabel as String: original.label,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        XCTAssertEqual(SecItemAdd(legacyAttributes as CFDictionary, nil), errSecSuccess)

        let record = NativeEnrollmentRecord(host: "relay.example", enrollmentPort: 18444,
                                            relayPort: 18443, trustedRootDER: Data(),
                                            identityLabel: original.label, deviceID: original.deviceID,
                                            approvalCode: "ABCDEFGH", statusSecret: "secret",
                                            expiresAt: 1, statusExpiresAt: 2, personID: "person")
        let renewed = try NativeEnrollmentStore(service: namespace).material(from: record)
        let expectedNotAfter = Data([0x18, 0x0f]) + Data("99991231235959Z".utf8)
        var renewedCertificate: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(renewed.keychainIdentity, &renewedCertificate), errSecSuccess)
        let renewedDER = SecCertificateCopyData(try XCTUnwrap(renewedCertificate)) as Data
        XCTAssertNotNil(renewedDER.range(of: expectedNotAfter))
        XCTAssertEqual(renewed.context.identity.personID.rawValue, "person")
        XCTAssertEqual(renewed.context.identity.deviceID.rawValue, record.deviceID)
        XCTAssertNotEqual(renewedDER, legacyDER)
        XCTAssertEqual(DeviceCertificateBinding.fingerprint(renewedDER), record.deviceID)
    }

    private func removeTestIdentity(_ namespace: String) {
        SecItemDelete([kSecClass as String: kSecClassCertificate,
                       kSecAttrLabel as String: namespace + ".certificate"] as CFDictionary)
        SecItemDelete([kSecClass as String: kSecClassKey,
                       kSecAttrApplicationTag as String: Data(namespace.utf8)] as CFDictionary)
    }
}

final class NativeEnrollmentResponseTests: XCTestCase {
    func testExpiryIsServerControlledWhileTheStatusWindowOrderIsRequired() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        XCTAssertNoThrow(try NativeEnrollmentStore.validateServerStartResponse(
            approvalCode: "ABCDEF2345",
            statusSecret: String(repeating: "a", count: 64),
            expiresAt: now - 60_000,
            statusExpiresAt: now + 86_400_000))

        XCTAssertThrowsError(try NativeEnrollmentStore.validateServerStartResponse(
            approvalCode: "ABCDEF2345",
            statusSecret: String(repeating: "a", count: 64),
            expiresAt: now,
            statusExpiresAt: now)) { error in
                guard case NativeEnrollmentError.invalidServerResponse = error else {
                    XCTFail("Expected the Server's status-window ordering invariant to remain enforced")
                    return
                }
            }
    }
}
