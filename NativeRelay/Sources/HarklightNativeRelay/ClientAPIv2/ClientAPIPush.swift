import AttentionDomain
import Foundation

/// Device push settings over the authenticated v2 connection. The caller
/// supplies the saved operation key and revision. A 412 requires a fresh
/// settings read and a new registration intent.
public struct ClientAPIPush: Sendable {
    private let transport: any ClientAPITransport
    private let model: ServerModelV2Store?
    private let onSettingsChanged: @Sendable () -> Void

    public init(transport: any ClientAPITransport, model: ServerModelV2Store? = nil,
                onSettingsChanged: @escaping @Sendable () -> Void = {}) {
        self.transport = transport
        self.model = model
        self.onSettingsChanged = onSettingsChanged
    }

    public func status() async throws -> APIPushStatus {
        try await request(.get("/v2/settings"))
    }

    public func register(token: ExactText, environment: APIPushEnvironment,
                         revision: UInt64, idempotencyKey: UUID) async throws -> APIPushStatus {
        guard revision > 0 else { throw ClientAPIModelError.invalid("push.revision") }
        let body = JSONValue.object([
            JSONMember("token", .string(token)),
            JSONMember("environment", .string(ExactText(environment.rawValue))),
            JSONMember("revision", .number(JSONNumber(lexeme: String(revision))))
        ])
        return try await request(APIRequest(method: .put, path: "/v2/devices/me/push",
                                            body: Data(body.jsonString.utf8), idempotencyKey: idempotencyKey))
    }

    public func remove(idempotencyKey: UUID) async throws -> APIPushStatus {
        try await request(APIRequest(method: .delete, path: "/v2/devices/me/push",
                                     idempotencyKey: idempotencyKey))
    }

    private func request(_ request: APIRequest) async throws -> APIPushStatus {
        let generation = model?.syncPosition.generation
        let reply = try await transport.send(request)
        try Task.checkCancellation()
        let response = try APIWriteResult(json: JSONValue.parse(reply.body))
        guard let status = response.settings?.push else { throw ClientAPIModelError.invalid("settings.push") }
        if let model {
            try model.apply(response, generation: generation)
            onSettingsChanged()
        }
        return status
    }
}

/// A push already matched to the saved v2 authority. Its revision is a hint.
public struct ClientAPIPushHint: Equatable, Sendable {
    public let serverID: ExactText
    public let personID: ExactText
    public let deviceID: ExactText
    public let bindingID: ExactText
    public let itemID: ExactText
    public let revision: Rev
    public let target: String?
}
