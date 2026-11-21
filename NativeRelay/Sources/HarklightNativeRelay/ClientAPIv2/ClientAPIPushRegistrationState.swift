import AttentionDomain
import Foundation

/// The enrollment's protected record stores this before dispatching any write.
/// An unknown outcome leaves the operation intact for replay after relaunch.
public struct ClientAPIPushRegistrationState: Codable, Equatable, Sendable {
    public struct Registration: Codable, Equatable, Sendable {
        public let token: ExactText
        public let environment: APIPushEnvironment
        public let revision: UInt64
        public let operationID: UUID
        public fileprivate(set) var accepted: Bool
    }

    public private(set) var registration: Registration?
    public private(set) var removalID: UUID?
    public private(set) var removalAccepted = false
    private var revisionFloor: UInt64 = 0

    public init() {}

    public mutating func prepareRegistration(token: ExactText, environment: APIPushEnvironment) throws -> Registration? {
        guard removalID == nil else { return nil }
        if let registration, registration.token == token, registration.environment == environment {
            return registration.accepted ? nil : registration
        }
        return try replaceRegistration(token: token, environment: environment, after: 0)
    }

    /// Only a definitive 412 followed by authenticated settings permits
    /// changing the revision and idempotency key of this registration.
    public mutating func replaceStaleRegistration(_ refused: Registration,
                                                  serverRevision: UInt64) throws -> Registration? {
        guard removalID == nil, registration == refused, !refused.accepted else { return nil }
        return try replaceRegistration(token: refused.token, environment: refused.environment, after: serverRevision)
    }

    public mutating func confirmRegistration(_ completed: Registration) {
        guard removalID == nil, registration == completed else { return }
        registration?.accepted = true
    }

    public mutating func prepareRemoval() -> UUID? {
        guard !removalAccepted else { return nil }
        let id = removalID ?? UUID()
        removalID = id
        return id
    }

    public mutating func confirmRemoval(_ completed: UUID, serverRevision: UInt64) {
        guard removalID == completed else { return }
        revisionFloor = max(revisionFloor, serverRevision)
        registration = nil
        removalAccepted = true
    }

    /// Keeping this account after a departure attempt is a new registration,
    /// since the previous DELETE may already have reached the server.
    public mutating func keepAccount() {
        guard removalID != nil else { return }
        registration = nil
        removalID = nil
        removalAccepted = false
    }

    private mutating func replaceRegistration(token: ExactText, environment: APIPushEnvironment,
                                               after serverRevision: UInt64) throws -> Registration {
        let previous = max(revisionFloor, serverRevision)
        guard previous < UInt64(Int64.max) else { throw ClientAPIModelError.invalid("push.revision") }
        let intent = Registration(token: token, environment: environment, revision: previous + 1,
                                  operationID: UUID(), accepted: false)
        revisionFloor = intent.revision
        registration = intent
        return intent
    }
}
