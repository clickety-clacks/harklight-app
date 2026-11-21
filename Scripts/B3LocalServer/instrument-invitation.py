"""Instrument the app's parser in the disposable proof build only."""

from pathlib import Path
import sys

source = Path(sys.argv[1]) / "Sources/NativeJoinInvitation.swift"
text = source.read_text()
begin = text.index("    static func decode(_ url: URL)")
end = text.index("    func sameAccount(", begin)
text = text[:begin] + r'''    static func decode(_ url: URL) throws -> NativeJoinInvitation {
        let parsed = URLComponents(url: url, resolvingAgainstBaseURL: false)
        recordProofHandoff(parsed)
        guard let components = parsed else { throw proofRejected("url_components") }
        try proofRequire(components.scheme?.lowercased() == "harklight", "url_scheme")
        try proofRequire(components.host == "join", "url_host")
        try proofRequire(components.path.isEmpty || components.path == "/", "url_path")
        try proofRequire(components.user == nil, "url_user")
        try proofRequire(components.password == nil, "url_password")
        try proofRequire(components.port == nil, "url_port")
        try proofRequire(components.query == nil, "url_query")
        guard let encoded = components.fragment, !encoded.isEmpty else {
            throw proofRejected("url_fragment_missing")
        }
        try proofRequire(encoded.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) ||
                (97...122).contains($0) || $0 == 45 || $0 == 95
        }, "url_fragment_alphabet")
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else {
            throw proofRejected("url_fragment_base64")
        }
        return try decodePayload(data)
    }

    static func decodePayload(_ data: Data) throws -> NativeJoinInvitation {
        try proofRequire(!data.isEmpty, "payload_empty")
        let result: NativeJoinInvitation
        do {
            result = try JSONDecoder().decode(Self.self, from: data)
        } catch let error as DecodingError {
            let field: String?
            switch error {
            case let .keyNotFound(key, _): field = key.stringValue
            case let .typeMismatch(_, context), let .valueNotFound(_, context),
                 let .dataCorrupted(context): field = context.codingPath.first?.stringValue
            @unknown default: field = nil
            }
            let known = ["v", "person_id", "server_name", "enrollment_url", "relay_url",
                         "ca_pem", "ca_sha256", "invite_token", "expires_at", "person_label", "inviter_label"]
            throw proofRejected(field.flatMap { known.contains($0) ? "payload_" + $0 : nil } ?? "payload_json")
        } catch {
            throw proofRejected("payload_json")
        }
        try result.validate()
        return result
    }

    func validate(now _: Date? = nil) throws {
        try Self.proofRequire(v == 1, "v")
        try Self.proofRequire(!personID.isEmpty, "person_id")
        try Self.proofRequire(!serverName.isEmpty && serverName.utf8.count <= 253, "server_name")
        try Self.proofRequire(Self.endpoint(enrollmentURL, scheme: "https", path: "/enroll"), "enrollment_url")
        try Self.proofRequire(Self.endpoint(relayURL, scheme: "wss", path: "/relay"), "relay_url")
        try Self.proofRequire(enrollmentURL.host?.lowercased() == serverName.lowercased(), "enrollment_url_name")
        try Self.proofRequire(relayURL.host?.lowercased() == serverName.lowercased(), "relay_url_name")
        try Self.proofRequire(Self.hexSecret(inviteToken), "invite_token")
        try Self.proofRequire(Self.hexSecret(caSHA256), "ca_sha256")
        try Self.proofRequire(expiresAt.map({ $0 > 0 }) ?? true, "expires_at")
        try Self.proofRequire(caPEM.components(separatedBy: "-----BEGIN CERTIFICATE-----").count == 2, "ca_pem_begin")
        try Self.proofRequire(caPEM.components(separatedBy: "-----END CERTIFICATE-----").count == 2, "ca_pem_end")
        guard let root = NativeEnrollmentSettings.certificateDER(from: caPEM) else {
            throw Self.proofRejected("ca_pem_base64")
        }
        try Self.proofRequire(SecCertificateCreateWithData(nil, root as CFData) != nil, "ca_pem_certificate")
        try Self.proofRequire(
            SHA256.hash(data: root).map({ String(format: "%02x", $0) }).joined() == caSHA256, "ca_sha256_pin"
        )
    }

    private static func recordProofHandoff(_ components: URLComponents?) {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let file = root.appendingPathComponent("b3-invitation-handoff.json")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }

        let shape: [String: Any] = [
            "is_native_scheme": components?.scheme?.lowercased() == "harklight",
            "is_join_host": components?.host == "join",
            "has_query": components?.query != nil,
            "encoded": proofFragmentFingerprint(components?.percentEncodedFragment),
            "decoded": proofFragmentFingerprint(components?.fragment)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: shape) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private static func proofFragmentFingerprint(_ fragment: String?) -> [String: Any] {
        guard let fragment else { return ["bytes": 0] }
        let bytes = Data(fragment.utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return ["bytes": bytes.count, "sha256": digest]
    }

    private static func proofRequire(_ condition: Bool, _ field: String) throws {
        guard condition else { throw proofRejected(field) }
    }

    private static func proofRejected(_ field: String) -> NativeJoinInvitationError {
        if let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? Data(field.utf8).write(to: root.appendingPathComponent("b3-invitation-reject-field.txt"), options: .atomic)
        }
        return .invalid
    }

''' + text[end:]
source.write_text(text)
