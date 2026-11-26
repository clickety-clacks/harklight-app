import CryptoKit
import Foundation
import Security

public struct NativeSessionProof: Codable, Equatable, Sendable {
    struct SignInFields: Codable, Equatable, Sendable {
        let publicKey: String
        let sessionHash: String
        let signature: String

        enum CodingKeys: String, CodingKey {
            case publicKey = "public_key"
            case sessionHash = "session_hash"
            case signature
        }
    }

    enum Failure: Error {
        case randomBytes(OSStatus)
    }

    private let privateKeyBytes: Data
    public let bearer: String

    public init() throws {
        privateKeyBytes = P256.Signing.PrivateKey().rawRepresentation
        bearer = try Self.randomSecret()
    }

    static func randomSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw Failure.randomBytes(status) }
        return base64URL(Data(bytes))
    }

    static func commitment(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func signIn(reference: String) throws -> SignInFields {
        let key = try P256.Signing.PrivateKey(rawRepresentation: privateKeyBytes)
        let hash = Self.commitment(bearer)
        let signature = try key.signature(for: Data("harklight-v2:sign-in\n\(reference)\n\(hash)".utf8))
        return SignInFields(publicKey: Self.base64URL(key.publicKey.derRepresentation),
                            sessionHash: hash, signature: Self.base64URL(signature.derRepresentation))
    }

    public func activationSignature() throws -> String {
        let key = try P256.Signing.PrivateKey(rawRepresentation: privateKeyBytes)
        let signature = try key.signature(for: Data("harklight-v2:migration-complete\n\(Self.commitment(bearer))".utf8))
        return Self.base64URL(signature.derRepresentation)
    }

    private static func base64URL(_ bytes: Data) -> String {
        bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Persist the encoded request and proof together before sending redemption.
public struct NativeSessionRedemption: Codable, Equatable, Sendable {
    public enum Credential {
        case transaction(reference: String, verifier: String)
        case migration(token: String)
    }

    public let proof: NativeSessionProof
    private let body: Data

    public init(credential: Credential, label: String, proof: NativeSessionProof) throws {
        self.proof = proof
        var fields = ["label": label]
        let reference: String
        switch credential {
        case let .transaction(transaction, verifier):
            reference = transaction
            fields["transaction"] = transaction
            fields["verifier"] = verifier
        case let .migration(token):
            reference = token
            fields["token"] = token
        }
        let signature = try proof.signIn(reference: reference)
        fields["public_key"] = signature.publicKey
        fields["session_hash"] = signature.sessionHash
        fields["signature"] = signature.signature
        body = try JSONEncoder().encode(fields)
    }

    public var request: APIRequest {
        APIRequest(method: .post, path: "/v2/auth/sign-in", body: body)
    }
}
