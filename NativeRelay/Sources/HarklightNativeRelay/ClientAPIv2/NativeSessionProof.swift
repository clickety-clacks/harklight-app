import CryptoKit
import Foundation
import Security

struct NativeSessionProof: Codable, Sendable {
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
    let bearer: String

    init() throws {
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

    func activationSignature() throws -> String {
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
