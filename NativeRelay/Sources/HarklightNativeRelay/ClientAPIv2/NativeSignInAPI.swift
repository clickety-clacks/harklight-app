import AttentionDomain
import Foundation

public enum NativeSignInMethod: String, Codable, Sendable, CaseIterable {
    case google
    case apple
    case emailCode = "email_code"
    case ownerCode = "owner_code"
    case passkey
}

struct NativeSignInAPI: Sendable {
    struct Transaction: Codable, Sendable {
        let reference: String
        let verifier: String

        func sheetURL(origin: URL, method: NativeSignInMethod) -> URL? {
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

        func matchesCallback(_ callback: URL) -> Bool {
            guard let url = URLComponents(url: callback, resolvingAgainstBaseURL: false),
                  url.scheme == "harklight", url.host == "sign-in",
                  url.user == nil, url.password == nil, url.port == nil,
                  url.path.isEmpty, url.fragment == nil else { return false }
            return url.queryItems == [URLQueryItem(name: "transaction", value: reference)]
        }
    }

    struct Result: Decodable, Sendable {
        enum OldDevice: String, Decodable, Sendable {
            case attached
            case removed
            case unknown
        }

        let personID: String
        let deviceID: String
        let duplicate: Bool
        let method: NativeSignInMethod?
        let oldDevice: OldDevice?

        enum CodingKeys: String, CodingKey {
            case personID = "person_id"
            case deviceID = "device_id"
            case duplicate, method
            case oldDevice = "old_device"
        }
    }

    let transport: any ClientAPITransport

    func methods() async throws -> [NativeSignInMethod] {
        struct Response: Decodable {
            let methods: [String]
        }
        let response = try await transport.send(.get("/v2/auth/methods"))
        return try JSONDecoder().decode(Response.self, from: response.body).methods
            .compactMap(NativeSignInMethod.init(rawValue:))
    }

    func begin() async throws -> Transaction {
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

    func verifyOwnerCode(_ code: String, transaction: String) async throws {
        _ = try await post("/sign-in/code", ["transaction": transaction, "code": code])
    }

    func redeem(_ pending: NativeSessionRedemption) async throws -> Result {
        let response = try await transport.send(pending.request)
        return try JSONDecoder().decode(Result.self, from: response.body)
    }

    struct MigrationGrant: Decodable, Sendable {
        let origin: URL
        let token: String
    }

    struct Device: Decodable, Identifiable, Sendable {
        let id: String
        let label: String
        let signedInAt: Int64?
        let current: Bool

        enum CodingKeys: String, CodingKey {
            case id = "device_id"
            case signedInAt = "signed_in_at"
            case label, current
        }
    }

    func migrationGrant() async throws -> MigrationGrant {
        let response = try await transport.send(APIRequest(method: .post, path: "/v2/auth/migration-grants"))
        return try JSONDecoder().decode(MigrationGrant.self, from: response.body)
    }

    func completeMigration(signature: String) async throws {
        _ = try await post("/v2/auth/migration-complete", ["signature": signature])
    }

    func signOut() async throws {
        _ = try await transport.send(APIRequest(method: .post, path: "/v2/auth/sign-out"))
    }

    func devices() async throws -> [Device] {
        struct Response: Decodable {
            let devices: [Device]
        }
        let response = try await transport.send(.get("/v2/devices"))
        return try JSONDecoder().decode(Response.self, from: response.body).devices
    }

    func isKnown(deviceID: String) async throws -> Bool {
        struct Response: Decodable {
            let known: Bool
        }
        let response = try await transport.send(.get("/v2/devices/known", query: ["device_id": deviceID]))
        return try JSONDecoder().decode(Response.self, from: response.body).known
    }

    func removeDevice(_ deviceID: String) async throws {
        let path = "/v2/devices/" + ClientAPIWrites.component(ExactText(deviceID))
        _ = try await transport.send(APIRequest(method: .delete, path: path))
    }

    private func post(_ path: String, _ fields: [String: String]) async throws -> APIResponse {
        try await transport.send(APIRequest(method: .post, path: path, body: JSONEncoder().encode(fields)))
    }
}
