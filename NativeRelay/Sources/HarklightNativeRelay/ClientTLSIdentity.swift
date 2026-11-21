import CryptoKit
import Foundation
import Security

/// Security.framework keychain identities are immutable references usable by
/// URLSession's delegate queue. The native enrollment owner retains custody of
/// the private key; only this reference crosses the actor boundary.
public struct TrustedKeychainIdentity: @unchecked Sendable {
    let value: SecIdentity

    public init(_ value: SecIdentity) { self.value = value }
}

/// The server identifies a device by lowercase SHA-256 of its certificate's
/// DER SubjectPublicKeyInfo, not by certificate subject or an app-supplied ID.
public enum DeviceCertificateBinding {
    public static func fingerprint(_ certificate: Data) -> String? {
        guard let key = subjectPublicKeyInfo(certificate) else { return nil }
        return SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
    }

    public static func matches(_ certificate: Data, expectedDeviceID: String) -> Bool {
        guard expectedDeviceID.count == 64,
              expectedDeviceID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let actual = fingerprint(certificate) else { return false }
        return actual == expectedDeviceID
    }

    private static func subjectPublicKeyInfo(_ certificate: Data) -> Data? {
        let bytes = Array(certificate)
        guard let outer = read(bytes, at: 0), outer.tag == 0x30,
              outer.end == bytes.count,
              let tbs = read(bytes, at: outer.content), tbs.tag == 0x30 else { return nil }
        var offset = tbs.content
        if let version = read(bytes, at: offset), version.tag == 0xa0 { offset = version.end }
        for tag: UInt8 in [0x02, 0x30, 0x30, 0x30, 0x30] {
            guard let field = read(bytes, at: offset), field.tag == tag,
                  field.end <= tbs.end else { return nil }
            offset = field.end
        }
        guard let key = read(bytes, at: offset), key.tag == 0x30,
              key.end <= tbs.end else { return nil }
        return Data(bytes[offset..<key.end])
    }

    private static func read(_ bytes: [UInt8], at start: Int) -> (tag: UInt8, content: Int, end: Int)? {
        guard start >= 0, start + 2 <= bytes.count else { return nil }
        let tag = bytes[start]
        let first = bytes[start + 1]
        var length = Int(first)
        var content = start + 2
        if first & 0x80 != 0 {
            let width = Int(first & 0x7f)
            guard width > 0, width <= 4, content + width <= bytes.count else { return nil }
            length = 0
            for byte in bytes[content..<(content + width)] {
                guard length <= (Int.max - Int(byte)) / 256 else { return nil }
                length = length * 256 + Int(byte)
            }
            content += width
        }
        guard length <= bytes.count - content else { return nil }
        return (tag, content, content + length)
    }
}
