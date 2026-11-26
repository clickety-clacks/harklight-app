import Foundation
import HarklightNativeRelay
import Security
import XCTest
@testable import Harklight

final class NativeGuidedIdentityTests: XCTestCase {
    func testLateSignInProofUsesTheLegacyDeviceKeyAfterCertificateDeletion() throws {
        let namespace = "Harklight.late-sign-in-test." + UUID().uuidString
        let store = NativeInstallationIdentityStore(namespace: namespace)
        defer { removeTestIdentity(namespace) }
        let legacy = try store.loadOrCreate()
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, legacy.certificateDER as CFData))
        let publicKey = try XCTUnwrap(SecCertificateCopyKey(certificate))
        let deletion = SecItemDelete([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: legacy.label
        ] as CFDictionary)
        XCTAssertEqual(deletion, errSecSuccess)
        let proof = try NativeSessionProof()
        let message = proof.signInMessage(reference: "fixture-transaction")
        let legacyProof = try store.lateSignInProof(deviceID: legacy.deviceID, message: message)
        let body = try JSONEncoder().encode(legacyProof)
        let fields = try JSONDecoder().decode([String: String].self, from: body)
        func decode(_ key: String) throws -> Data {
            let value = try XCTUnwrap(fields[key])
            let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            return try XCTUnwrap(Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)))
        }
        XCTAssertEqual(fields["device_id"], legacy.deviceID)
        XCTAssertEqual(NativeSessionProof.commitmentBytes(try decode("public_key")), legacy.deviceID)
        let signature = try decode("signature")
        XCTAssertTrue(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                           message as CFData, signature as CFData, nil))
        XCTAssertThrowsError(try store.lateSignInProof(deviceID: "another-device", message: message))
    }

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
