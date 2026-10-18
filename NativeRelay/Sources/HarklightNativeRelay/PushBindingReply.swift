import AttentionDomain
import Foundation

/// Only authenticated, request-correlated replies supply routing associations.
public enum PushBindingReply {
    public static func registration(_ value: JSONValue, revision: UInt64) throws -> String {
        guard value.uniqueValue(named: "v")?.integerValue == 1,
              value.uniqueValue(named: "type")?.stringValue?.rawValue == "ok",
              value.uniqueValue(named: "ref")?.stringValue?.rawValue == "native-push",
              case let .number(number)? = value.uniqueValue(named: "revision"),
              UInt64(number.lexeme) == revision,
              let id = bindingID(value) else { throw InstallationTransportError.unexpectedServerFrame }
        return id
    }

    public static func status(_ value: JSONValue, revision: UInt64) throws -> String? {
        guard value.uniqueValue(named: "v")?.integerValue == 1,
              value.uniqueValue(named: "type")?.stringValue?.rawValue == "ok",
              value.uniqueValue(named: "ref")?.stringValue?.rawValue == "native-push-status",
              let push = value.uniqueValue(named: "push"),
              case let .number(number)? = push.uniqueValue(named: "revision"),
              UInt64(number.lexeme) == revision else { throw InstallationTransportError.unexpectedServerFrame }
        guard push.uniqueValue(named: "binding_id") != nil else { return nil }
        guard push.uniqueValue(named: "profile_id")?.stringValue?.rawValue == "harklight-sandbox",
              let id = bindingID(push) else { throw InstallationTransportError.unexpectedServerFrame }
        return id
    }

    private static func bindingID(_ value: JSONValue) -> String? {
        guard let id = value.uniqueValue(named: "binding_id")?.stringValue?.rawValue,
              UUID(uuidString: id) != nil else { return nil }
        return id
    }
}
