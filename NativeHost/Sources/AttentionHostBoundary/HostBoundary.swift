import Foundation
import Security

/// This is presentation authority only. The shared native semantic port owns
/// drafts, intents, answers, outbox, and replay; no such state belongs here.
public struct HostAccount: Equatable, Sendable {
    public let scope: String
    public let deviceGeneration: String

    public init(scope: String, deviceGeneration: String) {
        self.scope = scope
        self.deviceGeneration = deviceGeneration
    }
}

public struct HostSession: Equatable, Sendable {
    public let token: String
    public let hostGeneration: String
    public let account: HostAccount
}

public enum HostBoundaryError: Error, Equatable {
    case rejected
    case entropyUnavailable
}

public struct HTTPRequestHead: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: [String]]

    public init(method: String, path: String, headers: [String: [String]]) {
        self.method = method
        self.path = path
        self.headers = headers
    }

    public func soleHeader(_ name: String) -> String? {
        let values = headers.filter { $0.key.caseInsensitiveCompare(name) == .orderedSame }
            .flatMap(\.value)
        return values.count == 1 ? values[0] : nil
    }
}

/// Exact same-origin validation before any account-scoped port call. The
/// listener must itself bind literal 127.0.0.1 and supply its chosen port.
public struct HostHTTPBoundary: Sendable {
    public let port: UInt16

    public init(port: UInt16) { self.port = port }

    public var origin: String { "http://127.0.0.1:\(port)" }
    public var host: String { "127.0.0.1:\(port)" }

    public func validateAPI(_ request: HTTPRequestHead) throws {
        guard request.method == "POST",
              request.path.hasPrefix("/api/"),
              !request.path.contains("?"), !request.path.contains("#"),
              request.soleHeader("Host") == host,
              request.soleHeader("Origin") == origin,
              request.soleHeader("Content-Type") == "application/json" else {
            throw HostBoundaryError.rejected
        }
    }

    public func validateStatic(_ request: HTTPRequestHead) throws {
        guard request.method == "GET", request.soleHeader("Host") == host,
              ["/", "/index.html", "/app.js", "/app.css", "/sender.js"].contains(request.path) else {
            throw HostBoundaryError.rejected
        }
    }

    public func bearerToken(_ request: HTTPRequestHead) throws -> String {
        guard let header = request.soleHeader("Authorization"),
              header.hasPrefix("Bearer "), header.count > 7,
              !header.dropFirst(7).contains(" ") else {
            throw HostBoundaryError.rejected
        }
        return String(header.dropFirst(7))
    }
}

public final class HostSessionGate: @unchecked Sendable {
    private struct Pairing {
        let secret: String
        let account: HostAccount
    }

    private struct Access {
        let account: HostAccount
        let hostGeneration: String
    }

    private let lock = NSLock()
    private let random: @Sendable (Int) throws -> Data
    private var activeAccount: HostAccount?
    private var hostGeneration: String
    private var pairing: Pairing?
    private var sessions: [String: Access] = [:]

    public convenience init() throws {
        try self.init(random: Self.secureRandom)
    }

    public init(random: @escaping @Sendable (Int) throws -> Data) throws {
        self.random = random
        self.hostGeneration = try Self.encode(random(16), expectedBytes: 16)
    }

    public func activate(_ account: HostAccount?) throws {
        lock.lock(); defer { lock.unlock() }
        if activeAccount != account {
            activeAccount = account
            try invalidateLocked()
        }
    }

    public func restart() throws {
        lock.lock(); defer { lock.unlock() }
        try invalidateLocked()
    }

    public func removeAccess() throws {
        lock.lock(); defer { lock.unlock() }
        activeAccount = nil
        try invalidateLocked()
    }

    /// Called only by trusted foreground host UI/terminal, never from HTTP.
    public func issuePairSecret(for account: HostAccount) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard activeAccount == account else { throw HostBoundaryError.rejected }
        let secret = try Self.encode(random(16), expectedBytes: 16)
        pairing = Pairing(secret: secret, account: account)
        return secret
    }

    public func pair(secret: String, account: HostAccount) throws -> HostSession {
        lock.lock(); defer { lock.unlock() }
        guard let pending = pairing, activeAccount == account, pending.account == account,
              secret == pending.secret else { throw HostBoundaryError.rejected }
        pairing = nil
        let token = try Self.encode(random(32), expectedBytes: 32)
        sessions[token] = Access(account: account, hostGeneration: hostGeneration)
        return HostSession(token: token, hostGeneration: hostGeneration, account: account)
    }

    public func authorize(token: String, account: HostAccount, hostGeneration: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let access = sessions[token], let activeAccount else { return false }
        return activeAccount == account && access.account == account &&
            access.hostGeneration == hostGeneration && self.hostGeneration == hostGeneration
    }

    public func logout(token: String) {
        lock.lock(); defer { lock.unlock() }
        sessions.removeValue(forKey: token)
    }

    private func invalidateLocked() throws {
        pairing = nil
        sessions.removeAll()
        hostGeneration = try Self.encode(random(16), expectedBytes: 16)
    }

    private static func encode(_ bytes: Data, expectedBytes: Int) throws -> String {
        guard bytes.count == expectedBytes else { throw HostBoundaryError.entropyUnavailable }
        return bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func secureRandom(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw HostBoundaryError.entropyUnavailable
        }
        return Data(bytes)
    }

}
