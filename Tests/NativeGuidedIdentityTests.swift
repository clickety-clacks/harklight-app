import Foundation
import HarklightNativeRelay
import Security
import XCTest
@testable import AttentionClientDuoPrototype

final class NativeGuidedIdentityTests: XCTestCase {
    func testJoinCreatesACertificateForThePrivateKeyRetainedOnThisDevice() throws {
        let namespace = "Harklight.guided-identity-test." + UUID().uuidString
        defer { removeTestIdentity(namespace) }
        let material = try NativeInstallationIdentityStore(namespace: namespace).loadOrCreate()
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, material.certificateDER as CFData))
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

    private func removeTestIdentity(_ namespace: String) {
        SecItemDelete([kSecClass as String: kSecClassCertificate,
                       kSecAttrLabel as String: namespace + ".certificate"] as CFDictionary)
        SecItemDelete([kSecClass as String: kSecClassKey,
                       kSecAttrApplicationTag as String: Data(namespace.utf8)] as CFDictionary)
    }
}
