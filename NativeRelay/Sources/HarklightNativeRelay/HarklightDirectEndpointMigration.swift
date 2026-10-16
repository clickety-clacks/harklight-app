import AttentionDomain
import CryptoKit
import Foundation

/// The one same-identity endpoint alias approved for the existing native app.
/// The stable profile authority remains unchanged; only the TLS hostname moves.
public enum HarklightDirectEndpointMigration {
    public static let profileAuthority = "racter.tail4105e8.ts.net"
    public static let endpointHost = "gibson.tail4105e8.ts.net"
    public static let enrollmentPort = 18_444
    public static let relayPort = 18_443
    public static let trustedRootSHA256 = "a550a50ddc8c5286a403b5f71fd7ff2c74f6c862815def1c0666bea2500cf7ea"

    public static func matchesTrustedRoot(_ trustedRootDER: Data) -> Bool {
        let digest = SHA256.hash(data: trustedRootDER).map { String(format: "%02x", $0) }.joined()
        return digest == trustedRootSHA256
    }

    public static func allows(profile: ProfileIdentity, endpointHost: String,
                              trustedRootDER: Data) -> Bool {
        guard profile.trustedRelayAuthority.rawValue == profileAuthority,
              endpointHost == self.endpointHost else { return false }
        return matchesTrustedRoot(trustedRootDER)
    }
}
