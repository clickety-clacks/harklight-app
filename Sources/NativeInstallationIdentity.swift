import Foundation
import HarklightNativeRelay
import Security

private enum InstallationIdentityFailure: Error {
    case keychain(operation: String, status: OSStatus)
    case keyCreation(code: Int)
}

/// Only the public certificate leaves this installation. The private key is
/// retained in the app's Keychain before an enrollment request can be sent.
struct NativeInstallationIdentity {
    let value: SecIdentity
    let certificateDER: Data
    let deviceID: String
    let label: String
}

struct NativeInstallationIdentityStore {
    let namespace: String

    init(namespace: String = "co.clicketyclacks.Harklight.guided-installation") {
        self.namespace = namespace
    }

    func loadOrCreate() throws -> NativeInstallationIdentity {
        let privateKey = try retainedPrivateKey()
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicDER = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw NativeEnrollmentError.invalidIdentity
        }
        let label = namespace + ".certificate"
        let certificate: SecCertificate
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let result,
           CFGetTypeID(result) == SecCertificateGetTypeID() {
            certificate = result as! SecCertificate
        } else if status == errSecItemNotFound {
            let der = try Self.selfSignedCertificate(publicKeyDER: publicDER, privateKey: privateKey)
            guard let created = SecCertificateCreateWithData(nil, der as CFData) else {
                throw NativeEnrollmentError.invalidIdentity
            }
            let attributes: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: created,
                kSecAttrLabel as String: label,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else {
                throw InstallationIdentityFailure.keychain(operation: "retain certificate", status: added)
            }
            certificate = created
        } else {
            throw InstallationIdentityFailure.keychain(operation: "load certificate", status: status)
        }

        guard let certificateKey = SecCertificateCopyKey(certificate),
              let certificatePublicDER = SecKeyCopyExternalRepresentation(certificateKey, nil) as Data?,
              certificatePublicDER == publicDER else {
            throw NativeEnrollmentError.invalidIdentity
        }
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        result = nil
        let foundIdentity = SecItemCopyMatching(identityQuery as CFDictionary, &result)
        guard foundIdentity == errSecSuccess,
              let result, CFGetTypeID(result) == SecIdentityGetTypeID() else {
            throw InstallationIdentityFailure.keychain(operation: "assemble identity", status: foundIdentity)
        }
        let identity = result as! SecIdentity
        var identityKey: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &identityKey) == errSecSuccess,
              let identityKey, let identityPublicKey = SecKeyCopyPublicKey(identityKey),
              let identityPublicDER = SecKeyCopyExternalRepresentation(identityPublicKey, nil) as Data?,
              identityPublicDER == publicDER else {
            throw NativeEnrollmentError.invalidIdentity
        }
        let der = SecCertificateCopyData(certificate) as Data
        guard let deviceID = DeviceCertificateBinding.fingerprint(der) else {
            throw NativeEnrollmentError.invalidIdentity
        }
        return NativeInstallationIdentity(value: identity, certificateDER: der,
                                          deviceID: deviceID, label: label)
    }

    private func retainedPrivateKey() throws -> SecKey {
        let tag = Data(namespace.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let result, CFGetTypeID(result) == SecKeyGetTypeID() {
            return result as! SecKey
        }
        guard status == errSecItemNotFound else {
            throw InstallationIdentityFailure.keychain(operation: "load private key", status: status)
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? Int(errSecInternalComponent)
            throw InstallationIdentityFailure.keyCreation(code: code)
        }
        return key
    }

    private static func selfSignedCertificate(publicKeyDER: Data, privateKey: SecKey) throws -> Data {
        // RSA/SHA-256 and clientAuth match the server's device-certificate path.
        // SecCertificateCreateWithData parses DER; it does not issue a certificate.
        let rsa = DER.sequence(DER.oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 1]), DER.null)
        let signature = DER.sequence(DER.oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 11]), DER.null)
        let name = DER.sequence(DER.value(0x31, DER.sequence(
            DER.oid([0x55, 4, 3]), DER.value(0x0c, Data("Harklight device".utf8)))))
        var serial = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial) == errSecSuccess else {
            throw NativeEnrollmentError.invalidIdentity
        }
        serial[0] |= 1
        let now = Date()
        let validity = DER.sequence(DER.time(now.addingTimeInterval(-300)),
                                    DER.time(now.addingTimeInterval(365 * 24 * 60 * 60)))
        let spki = DER.sequence(rsa, DER.bitString(publicKeyDER))
        let constraints = DER.sequence(DER.oid([0x55, 0x1d, 0x13]), DER.value(1, Data([0xff])),
                                       DER.value(4, DER.sequence()))
        let usage = DER.sequence(DER.oid([0x55, 0x1d, 0x0f]), DER.value(1, Data([0xff])),
                                DER.value(4, DER.value(3, Data([5, 0xa0]))))
        let clientAuth = DER.sequence(DER.oid([0x55, 0x1d, 0x25]), DER.value(4,
            DER.sequence(DER.oid([0x2b, 6, 1, 5, 5, 7, 3, 2]))))
        let tbs = DER.sequence(DER.value(0xa0, DER.value(2, Data([2]))),
                               DER.integer(Data(serial)), signature, name, validity, name, spki,
                               DER.value(0xa3, DER.sequence(constraints, usage, clientAuth)))
        var error: Unmanaged<CFError>?
        guard let signed = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                tbs as CFData, &error) as Data? else {
            throw NativeEnrollmentError.invalidIdentity
        }
        return DER.sequence(tbs, signature, DER.bitString(signed))
    }
}

private enum DER {
    static let null = Data([5, 0])

    static func value(_ tag: UInt8, _ content: Data) -> Data {
        var length = content.count
        var bytes: [UInt8] = []
        if length < 128 {
            bytes = [UInt8(length)]
        } else {
            while length > 0 {
                bytes.insert(UInt8(length & 0xff), at: 0)
                length >>= 8
            }
            bytes.insert(0x80 | UInt8(bytes.count), at: 0)
        }
        return Data([tag] + bytes) + content
    }

    static func sequence(_ items: Data...) -> Data {
        value(0x30, items.reduce(Data(), +))
    }

    static func integer(_ content: Data) -> Data {
        var bytes = Array(content)
        while bytes.count > 1 && bytes[0] == 0 { bytes.removeFirst() }
        if bytes.first.map({ $0 & 0x80 != 0 }) == true { bytes.insert(0, at: 0) }
        return value(2, Data(bytes))
    }

    static func oid(_ bytes: [UInt8]) -> Data { value(6, Data(bytes)) }
    static func bitString(_ data: Data) -> Data { value(3, Data([0]) + data) }

    static func time(_ date: Date) -> Data {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = TimeZone(secondsFromGMT: 0)
        let year = format.calendar.component(.year, from: date)
        format.dateFormat = year < 2050 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return value(year < 2050 ? 0x17 : 0x18, Data(format.string(from: date).utf8))
    }
}
