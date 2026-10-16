import CryptoKit
import Foundation
import Security

enum NativeJoinInvitationError: Error {
    case invalid
    case expired
}

/// An owner-provided claim and trust bootstrap. It conveys no owner/sender
/// rights and cannot enroll a device without a separate exact-key approval.
struct NativeJoinInvitation: Codable, Equatable {
    let v: Int
    let personID: String
    let serverName: String
    let enrollmentURL: URL
    let relayURL: URL
    let caPEM: String
    let caSHA256: String
    let inviteToken: String
    let expiresAt: Int64
    let personName: String?
    let inviterName: String?

    enum CodingKeys: String, CodingKey {
        case v
        case personID = "person_id"
        case serverName = "server_name"
        case enrollmentURL = "enrollment_url"
        case relayURL = "relay_url"
        case caPEM = "ca_pem"
        case caSHA256 = "ca_sha256"
        case inviteToken = "invite_token"
        case expiresAt = "expires_at"
        case personName = "person_label"
        case inviterName = "inviter_label"
    }

    var trustedRootDER: Data {
        // Only validated invitations are admitted at the product boundary.
        NativeEnrollmentSettings.certificateDER(from: caPEM) ?? Data()
    }

    var claimedAccountLabel: String { personName ?? "The account in this invitation" }
    var approvingOwnerLabel: String { inviterName ?? "The server owner" }

    static func decode(_ url: URL) throws -> NativeJoinInvitation {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "harklight",
              components.host == "join",
              components.path.isEmpty || components.path == "/",
              components.user == nil, components.password == nil,
              components.port == nil, components.query == nil,
              let encoded = components.fragment, !encoded.isEmpty, encoded.utf8.count <= 90_000,
              encoded.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                                      (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw NativeJoinInvitationError.invalid
        }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { throw NativeJoinInvitationError.invalid }
        return try decodePayload(data)
    }

    static func decodePayload(_ data: Data) throws -> NativeJoinInvitation {
        guard !data.isEmpty, data.count <= 64 * 1024 else { throw NativeJoinInvitationError.invalid }
        let result: NativeJoinInvitation
        do { result = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw NativeJoinInvitationError.invalid }
        try result.validate()
        return result
    }

    func validate(now: Date? = nil) throws {
        guard v == 1,
              !personID.isEmpty, personID.utf8.count <= 256,
              !serverName.isEmpty, serverName.utf8.count <= 253,
              Self.endpoint(enrollmentURL, scheme: "https", path: "/enroll"),
              Self.endpoint(relayURL, scheme: "wss", path: "/relay"),
              enrollmentURL.host?.lowercased() == serverName.lowercased(),
              relayURL.host?.lowercased() == serverName.lowercased(),
              Self.hexSecret(inviteToken), Self.hexSecret(caSHA256),
              expiresAt > 0, caPEM.utf8.count <= 16 * 1024,
              caPEM.components(separatedBy: "-----BEGIN CERTIFICATE-----").count == 2,
              caPEM.components(separatedBy: "-----END CERTIFICATE-----").count == 2,
              let root = NativeEnrollmentSettings.certificateDER(from: caPEM),
              SecCertificateCreateWithData(nil, root as CFData) != nil,
              SHA256.hash(data: root).map({ String(format: "%02x", $0) }).joined() == caSHA256,
              [personName, inviterName].allSatisfy({ $0.map { !$0.isEmpty && $0.utf8.count <= 256 } ?? true }) else {
            throw NativeJoinInvitationError.invalid
        }
        if let now, expiresAt <= Int64(now.timeIntervalSince1970 * 1000) {
            throw NativeJoinInvitationError.expired
        }
    }

    func sameAccount(as other: NativeJoinInvitation) -> Bool {
        NativeAuthorityBinding.samePerson(personID, other.personID) && enrollmentURL == other.enrollmentURL &&
            relayURL == other.relayURL && trustedRootDER == other.trustedRootDER
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.v == rhs.v && NativeAuthorityBinding.samePerson(lhs.personID, rhs.personID) &&
            lhs.serverName == rhs.serverName && lhs.enrollmentURL == rhs.enrollmentURL &&
            lhs.relayURL == rhs.relayURL && lhs.caPEM == rhs.caPEM && lhs.caSHA256 == rhs.caSHA256 &&
            lhs.inviteToken == rhs.inviteToken && lhs.expiresAt == rhs.expiresAt &&
            lhs.personName == rhs.personName && lhs.inviterName == rhs.inviterName
    }

    private static func endpoint(_ url: URL, scheme: String, path: String) -> Bool {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false),
              value.scheme == scheme, let host = value.host, !host.isEmpty,
              value.path == path, value.query == nil, value.fragment == nil,
              value.user == nil, value.password == nil else { return false }
        return value.port.map { (1...65_535).contains($0) } ?? true
    }

    private static func hexSecret(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    }
}
