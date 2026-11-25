import AttentionDomain
import Foundation
import HarklightNativeRelay
import Security

enum NativeEnrollmentError: Error {
    case invalidIdentity
    case identityStorage
    case emptyAPNsToken
    case invalidServerResponse
    case noPendingEnrollment
    case wrongApprovedDevice
    case keyPending
    case keyInUse
}

struct NativeEnrollmentSettings {
    static func certificateDER(from pem: String) -> Data? {
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .filter { !$0.isWhitespace }
        return Data(base64Encoded: base64)
    }
}

struct NativeEnrollmentRecord: Codable, Equatable {
    var host: String
    var enrollmentPort: Int
    var relayPort: Int
    let trustedRootDER: Data
    let identityLabel: String
    var deviceLabel: String? = nil
    let deviceID: String
    let approvalCode: String
    let statusSecret: String
    /// Nil when the Server gave no deadline (it no longer expires requests).
    let expiresAt: Int64?
    let statusExpiresAt: Int64?
    var personID: String?
    var v2Revoked: Bool? = nil
    var v2PushRegistration: ClientAPIPushRegistrationState? = nil
    var serverDisplayName: String? = nil
    var accountDisplayName: String? = nil
    var notificationExplanationSeen: Bool? = nil
    var foregroundRelayConfirmed: Bool? = nil
    /// Stable local account/storage authority. Nil on records written before
    /// endpoint migration; those records use their enrollment host.
    var localProfileAuthority: String? = nil
    var notificationProfileGeneration: UUID? = nil

    var isApproved: Bool { personID != nil }
    /// The invitation's person label, when it supplied one. Earlier builds saved
    /// the join screen's placeholder when the label was absent; that is not a name.
    var savedAccountName: String? {
        guard let accountDisplayName,
              !accountDisplayName.isEmpty,
              accountDisplayName != NativeJoinInvitation.unnamedAccountPlaceholder else { return nil }
        return accountDisplayName
    }
    var profileAuthority: String { localProfileAuthority ?? host }

    var deviceURL: URL? {
        // The existing record stores the device listener port as relayPort.
        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = host
        origin.port = relayPort
        return origin.url
    }

    func removalArchiveRecord() -> Self {
        Self(host: host, enrollmentPort: enrollmentPort, relayPort: relayPort,
             trustedRootDER: trustedRootDER, identityLabel: identityLabel,
             deviceLabel: deviceLabel, deviceID: deviceID, approvalCode: "", statusSecret: "",
             expiresAt: nil, statusExpiresAt: nil, personID: personID, v2Revoked: v2Revoked,
             serverDisplayName: serverDisplayName, accountDisplayName: accountDisplayName,
             localProfileAuthority: localProfileAuthority)
    }
}

/// Account identifiers are opaque wire bytes, including across Unicode forms.
enum NativeAuthorityBinding {
    static func samePerson(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case let (.some(left), .some(right)): left.utf8.elementsEqual(right.utf8)
        case (.none, .none): true
        default: false
        }
    }
}

struct NativeEnrollmentStore {
    private let service: String
    private static let account = "current-installation"
    private static let v2APNsAccount = "client-api-v2-apns-token"

    init(service: String = "co.clicketyclacks.Harklight.native-enrollment") {
        self.service = service
    }

    func load() throws -> NativeEnrollmentRecord? {
        try loadData(account: Self.account).map { try JSONDecoder().decode(NativeEnrollmentRecord.self, from: $0) }
    }

    private func loadData(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NativeEnrollmentError.identityStorage
        }
        return data
    }

    func v2APNsAddress() throws -> String? {
        try loadData(account: Self.v2APNsAccount)?.map { String(format: "%02x", $0) }.joined()
    }

    func storeV2APNsToken(_ token: Data) throws {
        guard !token.isEmpty else {
            try clearV2APNsToken()
            throw NativeEnrollmentError.emptyAPNsToken
        }
        try saveData(token, account: Self.v2APNsAccount)
    }

    func clearV2APNsToken() throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: Self.v2APNsAccount] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NativeEnrollmentError.identityStorage
        }
    }

    /// Reads only durable enrollment material so launch can distinguish an
    /// upgrade from a fresh install before it writes any release-note marker.
    func hasSavedInstallationState() throws -> Bool {
        try load() != nil
    }

    func material(from record: NativeEnrollmentRecord) throws -> NativeInstallationMaterial {
        guard let personID = record.personID,
              !personID.isEmpty,
              let deviceURL = record.deviceURL else {
            throw NativeEnrollmentError.invalidIdentity
        }
        let clientIdentity: SecIdentity
        if let namespace = guidedIdentityNamespace(for: record.identityLabel) {
            let installation = try NativeInstallationIdentityStore(namespace: namespace).loadExisting()
            guard installation.label == record.identityLabel,
                  installation.deviceID == record.deviceID else {
                throw NativeEnrollmentError.invalidIdentity
            }
            clientIdentity = installation.value
        } else if let retained = identity(label: record.identityLabel) {
            clientIdentity = retained
        } else {
            throw NativeEnrollmentError.invalidIdentity
        }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(clientIdentity, &certificate) == errSecSuccess,
              let certificate,
              DeviceCertificateBinding.matches(SecCertificateCopyData(certificate) as Data,
                                               expectedDeviceID: record.deviceID) else {
            throw NativeEnrollmentError.invalidIdentity
        }
        let profile = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText(record.profileAuthority),
                                                               personID: ExactText(personID),
                                                               deviceID: ExactText(record.deviceID)),
                                     transportMode: .relay)
        return NativeInstallationMaterial(context: profile,
                                          deviceURL: deviceURL,
                                          keychainIdentity: clientIdentity,
                                          trustedRootDER: record.trustedRootDER)
    }

    private func guidedIdentityNamespace(for label: String) -> String? {
        let certificateSuffix = ".certificate"
        guard label.hasPrefix(service + ".key."), label.hasSuffix(certificateSuffix) else { return nil }
        return String(label.dropLast(certificateSuffix.count))
    }

    func retainApprovedGuided(_ record: NativeEnrollmentRecord,
                              expectedPersonID: String,
                              expectedDeviceID: String,
                              replacingUnconfirmedAccount: NativeEnrollmentRecord? = nil) throws {
        guard NativeAuthorityBinding.samePerson(record.personID, expectedPersonID),
              record.deviceID == expectedDeviceID, record.isApproved else {
            throw NativeEnrollmentError.wrongApprovedDevice
        }
        _ = try material(from: record)
        if let current = try load(), current.isApproved {
            let isSameEnrollment = current.deviceID == record.deviceID &&
                NativeAuthorityBinding.samePerson(current.personID, record.personID) &&
                current.host == record.host && current.enrollmentPort == record.enrollmentPort &&
                current.relayPort == record.relayPort && current.trustedRootDER == record.trustedRootDER &&
                current.profileAuthority == record.profileAuthority
            guard isSameEnrollment || current == replacingUnconfirmedAccount else {
                throw NativeJoinError.existingAccount
            }
            guard isSameEnrollment else {
                // The prior enrollment remains durably attached to its
                // unconfirmed standalone departure. A newly approved
                // invitation receives its own identity and replaces only the
                // active-enrollment pointer; the prior profile data is intact.
                try save(record)
                return
            }
            // A repeated approved status is not a new installation. Keep the
            // existing durable APNs operation/revision and enrollment record.
            return
        }
        try save(record)
    }

    func markNotificationExplanationSeen(for deviceID: String) throws {
        guard var record = try load(), record.isApproved, record.deviceID == deviceID else {
            throw NativeEnrollmentError.wrongApprovedDevice
        }
        record.notificationExplanationSeen = true
        try save(record)
    }

    func markForegroundRelayConfirmed(for deviceID: String) throws {
        guard var record = try load(), record.isApproved, record.deviceID == deviceID else {
            throw NativeEnrollmentError.wrongApprovedDevice
        }
        record.foregroundRelayConfirmed = true
        try save(record)
    }

    func clearAfterConfirmedRemoval(of expected: NativeEnrollmentRecord) throws {
        guard let current = try load() else { return }
        guard current.deviceID == expected.deviceID, NativeAuthorityBinding.samePerson(current.personID, expected.personID),
              current.host == expected.host, current.trustedRootDER == expected.trustedRootDER,
              current.profileAuthority == expected.profileAuthority else {
            throw NativeJoinError.superseded
        }
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: Self.account] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NativeEnrollmentError.identityStorage
        }
    }

    func retireDeviceIdentity(_ record: NativeEnrollmentRecord) throws {
        if let namespace = guidedIdentityNamespace(for: record.identityLabel) {
            try NativeInstallationIdentityStore(namespace: namespace).retire()
            return
        }
        guard identity(label: record.identityLabel) != nil else { return }
        _ = try material(from: record)
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: record.identityLabel
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NativeEnrollmentError.identityStorage
        }
    }

    /// Check and update the protected record in one main-actor operation.
    @MainActor func updateV2PushRegistration<T>(
        for expected: NativeEnrollmentRecord, _ update: (inout ClientAPIPushRegistrationState) throws -> T
    ) throws -> T {
        guard var record = try load(), record.sameNotificationProfile(as: expected) else {
            throw NativeJoinError.superseded
        }
        let prior = record.v2PushRegistration ?? ClientAPIPushRegistrationState()
        var next = prior
        let result = try update(&next)
        if next != prior {
            record.v2PushRegistration = next
            try save(record)
        }
        return result
    }

    @MainActor func markV2Revoked(_ expected: NativeEnrollmentRecord) throws {
        guard var record = try load(), record.sameNotificationProfile(as: expected) else {
            throw NativeJoinError.superseded
        }
        guard record.v2Revoked != true else { return }
        record.v2Revoked = true
        try save(record)
    }

    private func identity(label: String) -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return (result as! SecIdentity)
    }

    private func save(_ record: NativeEnrollmentRecord) throws {
        try saveData(JSONEncoder().encode(record), account: Self.account)
    }

    private func saveData(_ data: Data, account: String) throws {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemUpdate(match as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw NativeEnrollmentError.identityStorage }
        var addition = match
        addition[kSecValueData as String] = data
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else {
            throw NativeEnrollmentError.identityStorage
        }
    }
}

final class EnrollmentTrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let host: String
    let root: SecCertificate?
    let identity: SecIdentity?

    init(host: String, rootDER: Data, identity: SecIdentity? = nil) {
        self.host = host
        self.root = SecCertificateCreateWithData(nil, rootDER as CFData)
        self.identity = identity
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // The status secret in the request body must not follow a redirect to another host.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate,
           challenge.protectionSpace.host == host {
            if let identity {
                completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
            } else {
                // The enrollment listener requests certificates optionally;
                // the first join has none. This ephemeral session has no
                // credential store, so default handling sends no identity.
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == host,
              let trust = challenge.protectionSpace.serverTrust,
              let root,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [root] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
