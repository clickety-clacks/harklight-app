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
        public let sharedMessages: Bool?
        public fileprivate(set) var accepted: Bool
    }

    public private(set) var registration: Registration?
    public private(set) var removalID: UUID?
    public private(set) var permissionRemovalID: UUID?
    public private(set) var removalAccepted = false
    private var revisionFloor: UInt64 = 0

    public init() {}

    public mutating func prepareRegistration(token: ExactText, environment: APIPushEnvironment,
                                             sharedMessages: Bool = false) throws -> Registration? {
        guard removalID == nil, permissionRemovalID == nil else { return nil }
        if let registration, registration.token == token, registration.environment == environment,
           (registration.sharedMessages == true) == sharedMessages {
            return registration.accepted ? nil : registration
        }
        return try replaceRegistration(token: token, environment: environment, sharedMessages: sharedMessages, after: 0)
    }

    /// Only a definitive 412 followed by authenticated settings permits
    /// changing the revision and idempotency key of this registration.
    public mutating func replaceStaleRegistration(_ refused: Registration,
                                                  serverRevision: UInt64) throws -> Registration? {
        guard removalID == nil, permissionRemovalID == nil, registration == refused, !refused.accepted else { return nil }
        return try replaceRegistration(token: refused.token, environment: refused.environment,
                                       sharedMessages: refused.sharedMessages == true, after: serverRevision)
    }

    public mutating func confirmRegistration(_ completed: Registration) {
        guard removalID == nil, permissionRemovalID == nil, registration == completed else { return }
        registration?.accepted = true
    }

    public mutating func prepareRemoval() -> UUID? {
        guard !removalAccepted else { return nil }
        let id = removalID ?? permissionRemovalID ?? UUID()
        permissionRemovalID = nil
        removalID = id
        return id
    }

    public mutating func preparePermissionRemoval(hasBinding: Bool) -> UUID? {
        guard removalID == nil else { return nil }
        if let permissionRemovalID { return permissionRemovalID }
        // A saved PUT with an unknown outcome may have applied even if its
        // binding never reached the local model.
        guard hasBinding || registration != nil else { return nil }
        let id = UUID()
        permissionRemovalID = id
        registration = nil
        return id
    }

    public mutating func confirmPermissionRemoval(_ completed: UUID, serverRevision: UInt64) {
        guard permissionRemovalID == completed else { return }
        permissionRemovalID = nil
        revisionFloor = max(revisionFloor, serverRevision)
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
                                               sharedMessages: Bool, after serverRevision: UInt64) throws -> Registration {
        let previous = max(revisionFloor, serverRevision)
        guard previous < UInt64(Int64.max) else { throw ClientAPIModelError.invalid("push.revision") }
        let intent = Registration(token: token, environment: environment, revision: previous + 1,
                                  operationID: UUID(), sharedMessages: sharedMessages ? true : nil, accepted: false)
        revisionFloor = intent.revision
        registration = intent
        return intent
    }
}
