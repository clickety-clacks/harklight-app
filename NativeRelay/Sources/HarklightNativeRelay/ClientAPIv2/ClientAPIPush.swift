import AttentionDomain
import Foundation

/// Device push settings over the authenticated v2 connection. The caller
/// supplies the saved operation key and revision. A 412 requires a fresh
/// settings read and a new registration intent.
public struct ClientAPIPush: Sendable {
    private let transport: any ClientAPITransport
    private let model: ServerModelV2Store?
    private let errors: any ErrorLogging
    private let onSettingsChanged: @Sendable () -> Void

    public init(transport: any ClientAPITransport, model: ServerModelV2Store? = nil,
                errors: any ErrorLogging = NoopErrorLog(),
                onSettingsChanged: @escaping @Sendable () -> Void = {}) {
        self.transport = transport
        self.model = model
        self.errors = errors
        self.onSettingsChanged = onSettingsChanged
    }

    public func status() async throws -> APIPushStatus {
        do {
            let status = try await request(.get("/v2/settings"))
            errors.resolve(concern: .snapshot, operation: "push_registration")
            return status
        } catch where Task.isCancelled || error is CancellationError {
            throw error
        } catch {
            let api = error as? APIError
            errors.report(ErrorLogReport(concern: .snapshot, connectionRole: .request,
                operation: "push_registration", phase: "read", reason: .api(error),
                initiator: .forFailure(error), retryable: api?.retryable ?? true,
                correlation: ErrorLogCorrelation(requestID: api?.requestID, resourceID: "push_registration"),
                httpStatus: api?.status))
            throw error
        }
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

    /// A refusal is definitive. The replacement becomes eligible only after
    /// the authenticated settings read and a successful protected save.
    @MainActor
    public func reconcileRegistration(
        _ saved: ClientAPIPushRegistrationState.Registration,
        replaceStale: @MainActor (UInt64) async throws -> ClientAPIPushRegistrationState.Registration?
    ) async throws -> ClientAPIPushRegistrationState.Registration? {
        func send(_ intent: ClientAPIPushRegistrationState.Registration) async throws {
            _ = try await register(token: intent.token, environment: intent.environment,
                                   revision: intent.revision, idempotencyKey: intent.operationID)
        }
        do {
            try await send(saved)
            return saved
        } catch let error as APIError where error.status == 412 && error.token == .preconditionFailed {
            let current = try await status()
            guard let replacement = try await replaceStale(current.revision) else { return nil }
            try await send(replacement)
            return replacement
        }
    }

    private func request(_ request: APIRequest) async throws -> APIPushStatus {
        try Task.checkCancellation()
        let generation = model?.syncPosition.generation
        let reply: APIResponse
        if let key = request.idempotencyKey {
            let write = FrozenWrite(method: request.method, path: request.path, body: request.body)
            let operation = request.method == .delete ? "remove_push" : "register_push"
            reply = try await ActionOutbox.attemptProtectedWrite(write, key: key, operation: operation,
                                                                 transport: transport, errors: errors)
        } else {
            reply = try await transport.send(request)
        }
        try Task.checkCancellation()
        let response = try APIWriteResult(json: JSONValue.parse(reply.body))
        guard let status = response.settings?.push else { throw ClientAPIModelError.invalid("settings.push") }
        if reply.replayed, request.idempotencyKey != nil {
            // A receipt confirms this operation, but its binding may already
            // have been replaced or removed. Use current settings for routing.
            _ = try await self.status()
            return status
        }
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
