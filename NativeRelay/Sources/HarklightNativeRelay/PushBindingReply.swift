import AttentionDomain
import Foundation

public enum PushRegistrationProfile: String, Equatable, Sendable {
    case sandbox = "harklight-sandbox"
    case production = "harklight-production"

    public enum BuildConfiguration: Equatable, Sendable {
        case debug
        case release
    }

    public static func forBuildConfiguration(_ configuration: BuildConfiguration) -> Self {
        switch configuration {
        case .debug: return .sandbox
        case .release: return .production
        }
    }

    public static var current: Self {
        // The development receiver script builds Debug; the app archive action builds Release.
        #if DEBUG
        return forBuildConfiguration(.debug)
        #else
        return forBuildConfiguration(.release)
        #endif
    }
}

public struct PushBindingStatus: Equatable, Sendable {
    public let revision: UInt64
    public let state: String
    public let bindingID: String
    public let profile: PushRegistrationProfile

    public var isBlockedByConfiguration: Bool { state == "blocked_configuration" }
}

/// Only authenticated, request-correlated replies supply routing associations.
public enum PushBindingReply {
    public static func registration(_ value: JSONValue, revision: UInt64,
                                    profile: PushRegistrationProfile = .current) throws -> String {
        guard value.uniqueValue(named: "v")?.integerValue == 1,
              value.uniqueValue(named: "type")?.stringValue?.rawValue == "ok",
              value.uniqueValue(named: "ref")?.stringValue?.rawValue == "native-push",
              case let .number(number)? = value.uniqueValue(named: "revision"),
              UInt64(number.lexeme) == revision,
              value.uniqueValue(named: "profile_id")?.stringValue?.rawValue == profile.rawValue,
              let id = bindingID(value) else { throw InstallationTransportError.unexpectedServerFrame }
        return id
    }

    public static func activeStatus(_ value: JSONValue) throws -> PushBindingStatus? {
        guard value.uniqueValue(named: "v")?.integerValue == 1,
              value.uniqueValue(named: "type")?.stringValue?.rawValue == "ok",
              value.uniqueValue(named: "ref")?.stringValue?.rawValue == "native-push-status",
              let push = value.uniqueValue(named: "push") else {
            throw InstallationTransportError.unexpectedServerFrame
        }
        if case .null = push { return nil }
        guard case let .number(revisionValue)? = push.uniqueValue(named: "revision"),
              let revision = UInt64(revisionValue.lexeme), revision > 0,
              let state = push.uniqueValue(named: "state")?.stringValue?.rawValue,
              let profileID = push.uniqueValue(named: "profile_id")?.stringValue?.rawValue,
              let profile = PushRegistrationProfile(rawValue: profileID),
              let id = bindingID(push) else {
            throw InstallationTransportError.unexpectedServerFrame
        }
        return PushBindingStatus(revision: revision, state: state, bindingID: id, profile: profile)
    }

    public static func status(_ value: JSONValue, revision: UInt64,
                              profile: PushRegistrationProfile = .current) throws -> String? {
        guard value.uniqueValue(named: "v")?.integerValue == 1,
              value.uniqueValue(named: "type")?.stringValue?.rawValue == "ok",
              value.uniqueValue(named: "ref")?.stringValue?.rawValue == "native-push-status",
              let push = value.uniqueValue(named: "push"),
              case let .number(number)? = push.uniqueValue(named: "revision"),
              UInt64(number.lexeme) == revision else { throw InstallationTransportError.unexpectedServerFrame }
        guard push.uniqueValue(named: "binding_id") != nil else { return nil }
        guard push.uniqueValue(named: "profile_id")?.stringValue?.rawValue == profile.rawValue,
              let id = bindingID(push) else { throw InstallationTransportError.unexpectedServerFrame }
        return id
    }

    private static func bindingID(_ value: JSONValue) -> String? {
        guard let id = value.uniqueValue(named: "binding_id")?.stringValue?.rawValue,
              UUID(uuidString: id) != nil else { return nil }
        return id
    }
}
