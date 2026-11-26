import AttentionDomain
import Foundation

public enum NativeSignInMethod: String, Codable, Sendable, CaseIterable {
    case google
    case apple
    case emailCode = "email_code"
    case ownerCode = "owner_code"
    case passkey
}

public struct NativeSignInAPI: Sendable {
    public struct Transaction: Codable, Sendable {
        public let reference: String
        public let verifier: String

        public func sheetURL(origin: URL, method: NativeSignInMethod) -> URL? {
            guard var url = URLComponents(url: origin, resolvingAgainstBaseURL: false),
                  url.scheme == "https", let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/" else { return nil }
            url.path = "/sign-in"
            url.queryItems = [
                URLQueryItem(name: "return", value: "app"),
                URLQueryItem(name: "transaction", value: reference),
                URLQueryItem(name: "method", value: method.rawValue)
            ]
            url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            return url.url
        }

        public func matchesCallback(_ callback: URL) -> Bool {
            guard let url = URLComponents(url: callback, resolvingAgainstBaseURL: false),
                  url.scheme == "harklight", url.host == "sign-in",
                  url.user == nil, url.password == nil, url.port == nil,
                  url.path.isEmpty, url.fragment == nil else { return false }
            return url.queryItems == [URLQueryItem(name: "transaction", value: reference)]
        }
    }

    public struct Result: Decodable, Sendable {
        public enum OldDevice: String, Decodable, Sendable {
            case attached
            case removed
            case unknown
        }

        public let personID: String
        public let deviceID: String
        let duplicate: Bool
        public let method: NativeSignInMethod?
        public let oldDevice: OldDevice?

        enum CodingKeys: String, CodingKey {
            case personID = "person_id"
            case deviceID = "device_id"
            case duplicate, method
            case oldDevice = "old_device"
        }
    }

    let transport: any ClientAPITransport

    public init(transport: any ClientAPITransport) { self.transport = transport }

    public func methods() async throws -> [NativeSignInMethod] {
        struct Response: Decodable {
            let methods: [String]
        }
        let response = try await transport.send(.get("/v2/auth/methods"))
        return try JSONDecoder().decode(Response.self, from: response.body).methods
            .compactMap(NativeSignInMethod.init(rawValue:))
    }

    public func begin() async throws -> Transaction {
        struct Response: Decodable {
            let transaction: String
        }
        let verifier = try NativeSessionProof.randomSecret()
        let response = try await post("/v2/auth/transactions", [
            "verifier_hash": NativeSessionProof.commitment(verifier)
        ])
        let reference = try JSONDecoder().decode(Response.self, from: response.body).transaction
        return Transaction(reference: reference, verifier: verifier)
    }

    public func verifyOwnerCode(_ code: String, transaction: String) async throws {
        _ = try await post("/sign-in/code", ["transaction": transaction, "code": code])
    }

    public func redeem(_ pending: NativeSessionRedemption) async throws -> Result {
        let response = try await transport.send(pending.request)
        return try JSONDecoder().decode(Result.self, from: response.body)
    }

    public struct MigrationGrant: Decodable, Sendable {
        public let origin: URL
        public let token: String
    }

    public struct Device: Decodable, Identifiable, Sendable {
        public let id: String
        public let label: String
        public let signedInAt: Int64?
        public let current: Bool

        enum CodingKeys: String, CodingKey {
            case id = "device_id"
            case signedInAt = "signed_in_at"
            case label, current
        }
    }

    enum MigrationError: Error {
        case wrongPrincipal
    }

    public func migrationPrincipal() async throws -> APIPushPrincipal? {
        let me = try await readMe()
        guard me.body.uniqueValue(named: "auth_migration") == .bool(true) else { return nil }
        guard let principal = me.pushPrincipal, principal.deviceID != nil else {
            throw MigrationError.wrongPrincipal
        }
        return principal
    }

    public func verifyMigrationPrincipal(_ expected: APIPushPrincipal) async throws {
        let me = try await readMe()
        guard me.pushPrincipal == expected else { throw MigrationError.wrongPrincipal }
    }

    private func readMe() async throws -> APIMe {
        let response = try await transport.send(.get("/v2/me"))
        return try APIMe(json: JSONValue.parse(response.body))
    }

    public func migrationGrant() async throws -> MigrationGrant {
        let response = try await transport.send(APIRequest(method: .post, path: "/v2/auth/migration-grants"))
        return try JSONDecoder().decode(MigrationGrant.self, from: response.body)
    }

    public func completeMigration(signature: String) async throws {
        _ = try await post("/v2/auth/migration-complete", ["signature": signature])
    }

    public func signOut() async throws {
        _ = try await transport.send(APIRequest(method: .post, path: "/v2/auth/sign-out"))
    }

    public func devices() async throws -> [Device] {
        struct Response: Decodable {
            let devices: [Device]
        }
        let response = try await transport.send(.get("/v2/devices"))
        return try JSONDecoder().decode(Response.self, from: response.body).devices
    }

    public func isKnown(deviceID: String) async throws -> Bool {
        struct Response: Decodable {
            let known: Bool
        }
        let response = try await transport.send(.get("/v2/devices/known", query: ["device_id": deviceID]))
        return try JSONDecoder().decode(Response.self, from: response.body).known
    }

    public func removeDevice(_ deviceID: String) async throws {
        let path = "/v2/devices/" + ClientAPIWrites.component(ExactText(deviceID))
        _ = try await transport.send(APIRequest(method: .delete, path: path))
    }

    private func post(_ path: String, _ fields: [String: String]) async throws -> APIResponse {
        try await transport.send(APIRequest(method: .post, path: path, body: JSONEncoder().encode(fields)))
    }
}
