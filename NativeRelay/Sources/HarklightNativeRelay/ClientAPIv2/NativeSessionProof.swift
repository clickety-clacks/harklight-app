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
        commitmentBytes(Data(secret.utf8))
    }

    public static func commitmentBytes(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func signIn(reference: String) throws -> SignInFields {
        let key = try P256.Signing.PrivateKey(rawRepresentation: privateKeyBytes)
        let hash = Self.commitment(bearer)
        let signature = try key.signature(for: signInMessage(reference: reference))
        return SignInFields(publicKey: Self.base64URL(key.publicKey.derRepresentation),
                            sessionHash: hash, signature: Self.base64URL(signature.derRepresentation))
    }

    public func signInMessage(reference: String) -> Data {
        Data("harklight-v2:sign-in\n\(reference)\n\(Self.commitment(bearer))".utf8)
    }

    public func activationSignature() throws -> String {
        let key = try P256.Signing.PrivateKey(rawRepresentation: privateKeyBytes)
        let signature = try key.signature(for: Data("harklight-v2:migration-complete\n\(Self.commitment(bearer))".utf8))
        return Self.base64URL(signature.derRepresentation)
    }

    public static func base64URL(_ bytes: Data) -> String {
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

    public struct OldProof: Encodable, Sendable {
        let deviceID: String
        let publicKey: String
        let signature: String

        public init(deviceID: String, publicKey: String, signature: String) {
            self.deviceID = deviceID
            self.publicKey = publicKey
            self.signature = signature
        }

        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id"
            case publicKey = "public_key"
            case signature
        }
    }

    private struct Fields: Encodable {
        let label: String
        var transaction: String?
        var verifier: String?
        var token: String?
        let publicKey: String
        let sessionHash: String
        let signature: String
        let oldProof: OldProof?

        enum CodingKeys: String, CodingKey {
            case label, transaction, verifier, token, signature
            case publicKey = "public_key"
            case sessionHash = "session_hash"
            case oldProof = "old_proof"
        }
    }

    public let proof: NativeSessionProof
    private let body: Data

    public init(credential: Credential, label: String, proof: NativeSessionProof, oldProof: OldProof? = nil) throws {
        self.proof = proof
        let fields: Fields
        switch credential {
        case let .transaction(transaction, verifier):
            let signature = try proof.signIn(reference: transaction)
            fields = Fields(label: label, transaction: transaction, verifier: verifier,
                publicKey: signature.publicKey, sessionHash: signature.sessionHash,
                signature: signature.signature, oldProof: oldProof)
        case let .migration(token):
            let signature = try proof.signIn(reference: token)
            fields = Fields(label: label, token: token, publicKey: signature.publicKey,
                sessionHash: signature.sessionHash, signature: signature.signature, oldProof: nil)
        }
        body = try JSONEncoder().encode(fields)
    }

    public var request: APIRequest {
        APIRequest(method: .post, path: "/v2/auth/sign-in", body: body)
    }
}
