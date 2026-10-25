import AttentionDomain
import CryptoKit
import Foundation
import HarklightNativeRelay
import Security

enum NativeEnrollmentError: Error {
    case invalidSettings
    case invalidIdentity
    case identityStorage
    case invalidServerResponse
    case serverRejected
    case approvalPending
    case approvalExpired
    case noPendingEnrollment
    case wrongApprovedDevice
    case keyPending
    case keyInUse
    case preparedIdentityMismatch
    case endpointMigrationNotAllowed
}

struct NativeEnrollmentSettings {
    let host: String
    let enrollmentPort: Int
    let relayPort: Int
    let trustedRootDER: Data
    let label: String

    init(host: String, enrollmentPort: Int, relayPort: Int, rootPEM: String, label: String) throws {
        guard !host.isEmpty, host.utf8.count <= 253,
              host.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                                           (97...122).contains($0) || $0 == 45 || $0 == 46 }),
              host.split(separator: ".", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") }),
              (1...65_535).contains(enrollmentPort),
              (1...65_535).contains(relayPort),
              !label.isEmpty, label.utf8.count <= 256,
              let root = Self.certificateDER(from: rootPEM),
              SecCertificateCreateWithData(nil, root as CFData) != nil else {
            throw NativeEnrollmentError.invalidSettings
        }
        self.host = host.lowercased()
        self.enrollmentPort = enrollmentPort
        self.relayPort = relayPort
        self.trustedRootDER = root
        self.label = label
    }

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
    let expiresAt: Int64
    let statusExpiresAt: Int64
    var personID: String?
    var pushBinding: NativePushBinding? = nil
    var serverDisplayName: String? = nil
    var accountDisplayName: String? = nil
    var notificationExplanationSeen: Bool? = nil
    var foregroundRelayConfirmed: Bool? = nil
    /// Stable local account/storage authority. Nil on records written before
    /// endpoint migration; those records use their enrollment host.
    var localProfileAuthority: String? = nil
    var notificationProfileGeneration: UUID? = nil
    var notificationBindings: [NativeNotificationBinding]? = nil

    var isApproved: Bool { personID != nil }
    /// The invitation's person label, when it supplied one. Earlier builds saved
    /// the join screen's placeholder when the label was absent; that is not a name.
    var savedAccountName: String? {
        accountDisplayName == NativeJoinInvitation.unnamedAccountPlaceholder ? nil : accountDisplayName
    }
    var profileAuthority: String { localProfileAuthority ?? host }
}

enum NativeEndpointMigrationPolicy {
    static let sourceHost = HarklightDirectEndpointMigration.profileAuthority
    static let gibsonHost = HarklightDirectEndpointMigration.endpointHost
    static let gibsonEnrollmentPort = HarklightDirectEndpointMigration.enrollmentPort
    static let gibsonRelayPort = HarklightDirectEndpointMigration.relayPort
    static let pinnedRootSHA256 = HarklightDirectEndpointMigration.trustedRootSHA256

    static func matchesApprovedRoot(_ rootDER: Data) -> Bool {
        HarklightDirectEndpointMigration.matchesTrustedRoot(rootDER)
    }

    static func rootSHA256(_ rootDER: Data) -> String {
        SHA256.hash(data: rootDER).map { String(format: "%02x", $0) }.joined()
    }

    static func candidate(from record: NativeEnrollmentRecord,
                          acceptedRootSHA256: String = pinnedRootSHA256) throws -> NativeEnrollmentRecord {
        let rootHash = rootSHA256(record.trustedRootDER)
        guard record.isApproved,
              record.host == sourceHost,
              record.localProfileAuthority == nil || record.localProfileAuthority == sourceHost,
              record.enrollmentPort == gibsonEnrollmentPort,
              record.relayPort == gibsonRelayPort,
              rootHash == acceptedRootSHA256 else {
            throw NativeEnrollmentError.endpointMigrationNotAllowed
        }
        var migrated = record
        migrated.localProfileAuthority = record.profileAuthority
        migrated.host = gibsonHost
        return migrated
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

struct NativePushBinding: Codable, Equatable {
    let address: String
    let operationID: UUID
    let revision: UInt64
    var accepted: Bool
}

private struct PreparedEnrollment: Codable {
    let host: String
    let enrollmentPort: Int
    let relayPort: Int
    let trustedRootDER: Data
    let label: String
    let identityLabel: String
    let deviceID: String
    let certificateDER: Data

    func matches(settings: NativeEnrollmentSettings,
                 deviceID: String,
                 certificateDER: Data) -> Bool {
        host == settings.host && enrollmentPort == settings.enrollmentPort &&
            relayPort == settings.relayPort && trustedRootDER == settings.trustedRootDER &&
            label == settings.label && self.deviceID == deviceID &&
            self.certificateDER == certificateDER
    }
}

/// The enrollment service receives only the public certificate. The imported
/// password-protected identity is put in this app's Keychain; its private key
/// is never copied into the C store, transport frames or profile metadata.
struct NativeEnrollmentStore {
    private let service: String
    private static let account = "current-installation"
    private static let preparedAccount = "unconfirmed-installation"

    init(service: String = "co.clicketyclacks.Harklight.native-enrollment") {
        self.service = service
    }

    func load() throws -> NativeEnrollmentRecord? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NativeEnrollmentError.identityStorage
        }
        return try JSONDecoder().decode(NativeEnrollmentRecord.self, from: data)
    }

    /// Reads only durable enrollment material so launch can distinguish an
    /// upgrade from a fresh install before it writes any release-note marker.
    func hasSavedInstallationState() throws -> Bool {
        if try load() != nil { return true }
        return try loadPrepared() != nil
    }

    func begin(settings: NativeEnrollmentSettings,
               pkcs12: Data,
               password: String,
               onPreparedCleanupFailure: (@MainActor @Sendable (Error) -> Void)? = nil) async throws -> NativeEnrollmentRecord {
        guard try load() == nil else { throw NativeEnrollmentError.invalidSettings }
        let imported = try importIdentity(pkcs12, password: password)
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(imported, &certificate) == errSecSuccess,
              let certificate else { throw NativeEnrollmentError.invalidIdentity }
        let certificateDER = SecCertificateCopyData(certificate) as Data
        guard let deviceID = DeviceCertificateBinding.fingerprint(certificateDER) else {
            throw NativeEnrollmentError.invalidIdentity
        }
        let attempt: PreparedEnrollment
        if let previous = try loadPrepared() {
            guard previous.matches(settings: settings,
                                   deviceID: deviceID,
                                   certificateDER: certificateDER) else {
                throw NativeEnrollmentError.preparedIdentityMismatch
            }
            attempt = previous
        } else {
            attempt = PreparedEnrollment(host: settings.host,
                                         enrollmentPort: settings.enrollmentPort,
                                         relayPort: settings.relayPort,
                                         trustedRootDER: settings.trustedRootDER,
                                         label: settings.label,
                                         identityLabel: "Harklight device \(deviceID)",
                                         deviceID: deviceID,
                                         certificateDER: certificateDER)
        }
        try retainIdentity(imported, label: attempt.identityLabel, certificateDER: certificateDER)
        // The exact server/key attempt exists before any uncertain network
        // response. Reimporting the same file can retry this same certificate;
        // a different file or authority cannot silently replace it.
        try savePrepared(attempt)
        let record = try await requestEnrollment(attempt)
        try save(record)
        do { try deletePrepared() }
        catch { await onPreparedCleanupFailure?(error) }
        return record
    }

    func retryExpired() async throws -> NativeEnrollmentRecord {
        guard let prior = try load(), !prior.isApproved,
              let retained = identity(label: prior.identityLabel) else {
            throw NativeEnrollmentError.noPendingEnrollment
        }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(retained, &certificate) == errSecSuccess,
              let certificate else { throw NativeEnrollmentError.invalidIdentity }
        let certificateDER = SecCertificateCopyData(certificate) as Data
        guard DeviceCertificateBinding.matches(certificateDER, expectedDeviceID: prior.deviceID) else {
            throw NativeEnrollmentError.wrongApprovedDevice
        }
        let attempt = PreparedEnrollment(host: prior.host,
                                         enrollmentPort: prior.enrollmentPort,
                                         relayPort: prior.relayPort,
                                         trustedRootDER: prior.trustedRootDER,
                                         label: prior.deviceLabel ?? prior.identityLabel,
                                         identityLabel: prior.identityLabel,
                                         deviceID: prior.deviceID,
                                         certificateDER: certificateDER)
        let replacement = try await requestEnrollment(attempt)
        try save(replacement)
        return replacement
    }

    private func requestEnrollment(_ attempt: PreparedEnrollment) async throws -> NativeEnrollmentRecord {
        let pem = "-----BEGIN CERTIFICATE-----\n" +
            attempt.certificateDER.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]) +
            "\n-----END CERTIFICATE-----\n"
        let response: StartResponse = try await post(path: "/enroll",
                                                     body: ["public_certificate": pem, "label": attempt.label],
                                                     host: attempt.host,
                                                     port: attempt.enrollmentPort,
                                                     rootDER: attempt.trustedRootDER)
        guard response.approvalCode.count == 10,
              response.approvalCode.allSatisfy({ "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".contains($0) }),
              response.statusSecret.count == 64,
              response.statusSecret.allSatisfy({ $0.isHexDigit }),
              response.expiresAt > Int64(Date().timeIntervalSince1970 * 1000),
              response.statusExpiresAt > response.expiresAt else {
            throw NativeEnrollmentError.invalidServerResponse
        }
        return NativeEnrollmentRecord(host: attempt.host,
                                            enrollmentPort: attempt.enrollmentPort,
                                            relayPort: attempt.relayPort,
                                            trustedRootDER: attempt.trustedRootDER,
                                            identityLabel: attempt.identityLabel,
                                            deviceLabel: attempt.label,
                                            deviceID: attempt.deviceID,
                                            approvalCode: response.approvalCode,
                                            statusSecret: response.statusSecret,
                                            expiresAt: response.expiresAt,
                                            statusExpiresAt: response.statusExpiresAt,
                                            personID: nil)
    }

    func checkApproval() async throws -> NativeEnrollmentRecord {
        guard var record = try load() else { throw NativeEnrollmentError.noPendingEnrollment }
        if record.isApproved { return record }
        let response: StatusResponse = try await post(path: "/enroll/status",
                                                      body: ["status_secret": record.statusSecret],
                                                      host: record.host,
                                                      port: record.enrollmentPort,
                                                      rootDER: record.trustedRootDER)
        switch response.state {
        case "pending": throw NativeEnrollmentError.approvalPending
        case "expired": throw NativeEnrollmentError.approvalExpired
        case "approved":
            guard let person = response.personID, !person.isEmpty,
                  response.deviceID == record.deviceID else {
                throw NativeEnrollmentError.wrongApprovedDevice
            }
            record.personID = person
            try save(record)
            return record
        default: throw NativeEnrollmentError.invalidServerResponse
        }
    }

    func material(from record: NativeEnrollmentRecord) throws -> NativeInstallationMaterial {
        guard let personID = record.personID,
              !personID.isEmpty,
              let identity = identity(label: record.identityLabel),
              let relayURL = URL(string: "wss://\(record.host):\(record.relayPort)/relay") else {
            throw NativeEnrollmentError.invalidIdentity
        }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
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
                                          relayURL: relayURL,
                                          keychainIdentity: identity,
                                          trustedRootDER: record.trustedRootDER)
    }

    func retainApprovedGuided(_ record: NativeEnrollmentRecord,
                              expectedPersonID: String,
                              expectedDeviceID: String) throws {
        guard NativeAuthorityBinding.samePerson(record.personID, expectedPersonID),
              record.deviceID == expectedDeviceID, record.isApproved else {
            throw NativeEnrollmentError.wrongApprovedDevice
        }
        _ = try material(from: record)
        if let current = try load(), current.isApproved {
            guard current.deviceID == record.deviceID, NativeAuthorityBinding.samePerson(current.personID, record.personID),
                  current.host == record.host, current.enrollmentPort == record.enrollmentPort,
                  current.relayPort == record.relayPort, current.trustedRootDER == record.trustedRootDER,
                  current.profileAuthority == record.profileAuthority else {
                throw NativeJoinError.existingAccount
            }
            // A repeated approved status is not a new installation. Keep the
            // existing durable APNs operation/revision and enrollment record.
            return
        }
        try save(record)
    }

    func commitGibsonEndpointMigration(from expected: NativeEnrollmentRecord,
                                       to replacement: NativeEnrollmentRecord,
                                       acceptedRootSHA256: String = NativeEndpointMigrationPolicy.pinnedRootSHA256) throws {
        guard let current = try load(), current == expected,
              try NativeEndpointMigrationPolicy.candidate(from: expected,
                                                          acceptedRootSHA256: acceptedRootSHA256) == replacement else {
            throw NativeEnrollmentError.endpointMigrationNotAllowed
        }
        try save(replacement)
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

    /// Persist the exact registration operation before sending it. Repeated
    /// refreshes use the same operation ID and revision until the server reply
    /// is confirmed; a changed APNs address advances the revision.
    func pendingPushRegistration(address: String, for deviceID: String) throws -> NativePushBinding? {
        guard address.count == 64,
              address.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              var record = try load(),
              record.isApproved,
              record.deviceID == deviceID else { return nil }
        if let existing = record.pushBinding, existing.address == address {
            return existing.accepted ? nil : existing
        }
        let previous = record.pushBinding?.revision ?? 0
        guard previous < UInt64(Int64.max) - 1 else {
            throw NativeEnrollmentError.invalidServerResponse
        }
        let revision = previous + 1
        let binding = NativePushBinding(address: address,
                                        operationID: UUID(),
                                        revision: revision,
                                        accepted: false)
        record.pushBinding = binding
        try save(record)
        return binding
    }

    /// Opens a new durable registration only when the authenticated server
    /// status still names this accepted Production binding and reports the
    /// existing configuration-blocked state. Older installations persist the
    /// binding ID in `notificationBindings`; records without that association
    /// can still match by their accepted revision and current Production build.
    func pendingBlockedConfigurationRegistration(
        address: String,
        for deviceID: String,
        status: PushBindingStatus,
        profile: PushRegistrationProfile
    ) throws -> NativePushBinding? {
        guard profile == .production,
              status.profile == profile,
              status.isBlockedByConfiguration,
              address.count == 64,
              address.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              var record = try load(),
              record.isApproved,
              record.deviceID == deviceID,
              let existing = record.pushBinding,
              existing.accepted,
              existing.address == address,
              existing.revision == status.revision else { return nil }

        let associations = (record.notificationBindings ?? []).filter {
            $0.operationID == existing.operationID && $0.revision == existing.revision
        }
        guard associations.count <= 1,
              associations.first?.bindingID.rawValue == nil ||
                associations.first?.bindingID.rawValue == status.bindingID else { return nil }
        guard existing.revision < UInt64(Int64.max) - 1 else {
            throw NativeEnrollmentError.invalidServerResponse
        }

        let binding = NativePushBinding(address: existing.address,
                                        operationID: UUID(),
                                        revision: existing.revision + 1,
                                        accepted: false)
        record.pushBinding = binding
        try save(record)
        return binding
    }

    /// Persist routing metadata and acceptance together, guarded by the exact
    /// preexisting trusted enrollment and durable registration operation.
    func markPushAccepted(_ binding: NativePushBinding, bindingID: String,
                          expected: NativeEnrollmentRecord) throws {
        guard var record = try load(), record.sameNotificationProfile(as: expected),
              record.pushBinding == binding, UUID(uuidString: bindingID) != nil else {
            throw NativeJoinError.superseded
        }
        record.notificationProfileGeneration = record.notificationProfileGeneration ?? UUID()
        let association = NativeNotificationBinding(bindingID: ExactText(bindingID),
            operationID: binding.operationID, revision: binding.revision)
        var associations = record.notificationBindings ?? []
        if !associations.contains(association) { associations.append(association) }
        record.notificationBindings = associations
        record.pushBinding?.accepted = true
        try save(record)
    }

    private func importIdentity(_ data: Data, password: String) throws -> SecIdentity {
        var rawItems: CFArray?
        let options = [kSecImportExportPassphrase as String: password]
        guard SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems) == errSecSuccess,
              let item = (rawItems as? [[String: Any]])?.first,
              let rawIdentity = item[kSecImportItemIdentity as String],
              CFGetTypeID(rawIdentity as CFTypeRef) == SecIdentityGetTypeID() else {
            throw NativeEnrollmentError.invalidIdentity
        }
        return rawIdentity as! SecIdentity
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

    private func retainIdentity(_ imported: SecIdentity,
                                label: String,
                                certificateDER: Data) throws {
        if let retained = identity(label: label) {
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(retained, &certificate) == errSecSuccess,
                  let certificate,
                  SecCertificateCopyData(certificate) as Data == certificateDER else {
                throw NativeEnrollmentError.preparedIdentityMismatch
            }
            return
        }
        let addition: [String: Any] = [
            kSecValueRef as String: imported,
            kSecAttrLabel as String: label
        ]
        guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else {
            throw NativeEnrollmentError.identityStorage
        }
    }

    private func loadPrepared() throws -> PreparedEnrollment? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.preparedAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NativeEnrollmentError.identityStorage
        }
        return try JSONDecoder().decode(PreparedEnrollment.self, from: data)
    }

    private func savePrepared(_ attempt: PreparedEnrollment) throws {
        try saveData(JSONEncoder().encode(attempt), account: Self.preparedAccount)
    }

    private func deletePrepared() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.preparedAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NativeEnrollmentError.identityStorage
        }
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

    private func post<Response: Decodable>(path: String,
                                           body: [String: String],
                                           host: String,
                                           port: Int,
                                           rootDER: Data) async throws -> Response {
        guard var components = URLComponents(string: "https://\(host)"),
              !host.isEmpty else { throw NativeEnrollmentError.invalidSettings }
        components.port = port
        components.path = path
        guard let url = components.url else { throw NativeEnrollmentError.invalidSettings }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 10
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration,
                                 delegate: EnrollmentTrustDelegate(host: host, rootDER: rootDER),
                                 delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard data.count <= 64 * 1024,
              let response = response as? HTTPURLResponse else {
            throw NativeEnrollmentError.serverRejected
        }
        if response.statusCode == 409,
           let error = try? JSONDecoder().decode(ServerError.self, from: data) {
            switch error.error {
            case "key_pending": throw NativeEnrollmentError.keyPending
            case "key_in_use": throw NativeEnrollmentError.keyInUse
            default: break
            }
        }
        guard response.statusCode == 200 else { throw NativeEnrollmentError.serverRejected }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private struct ServerError: Decodable {
        let error: String
    }

    private struct StartResponse: Decodable {
        let approvalCode: String
        let statusSecret: String
        let expiresAt: Int64
        let statusExpiresAt: Int64

        enum CodingKeys: String, CodingKey {
            case approvalCode = "approval_code"
            case statusSecret = "status_secret"
            case expiresAt = "expires_at"
            case statusExpiresAt = "status_expires_at"
        }
    }

    private struct StatusResponse: Decodable {
        let state: String
        let personID: String?
        let deviceID: String?

        enum CodingKeys: String, CodingKey {
            case state
            case personID = "person_id"
            case deviceID = "device_id"
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
