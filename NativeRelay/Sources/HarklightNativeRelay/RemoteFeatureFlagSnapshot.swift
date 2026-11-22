import AttentionDomain

/// Server values are a replaceable cache. Missing entries always use the
/// caller's built-in default; invalid entries do not discard valid siblings.
public struct RemoteFeatureFlagSnapshot: Equatable, Sendable {
    public let values: [String: Bool]
    public let hasMalformedValues: Bool
    /// Read-only diagnostics; these never change the decoded effective values.
    public let hasMalformedObject: Bool
    public let malformedNames: Set<String>

    public init(field: JSONValue?) {
        guard let field, field != .null else {
            values = [:]
            hasMalformedValues = false
            hasMalformedObject = false
            malformedNames = []
            return
        }
        guard case let .object(members) = field else {
            values = [:]
            hasMalformedValues = true
            hasMalformedObject = true
            malformedNames = []
            return
        }
        var decoded: [String: Bool] = [:]
        var malformed = false
        var malformedNames: Set<String> = []
        for member in members {
            if case let .bool(value) = member.value {
                decoded[member.key.rawValue] = value
            } else {
                malformed = true
                malformedNames.insert(member.key.rawValue)
            }
        }
        values = decoded
        hasMalformedValues = malformed
        hasMalformedObject = false
        self.malformedNames = malformedNames
    }
}

/// Decode the server's authenticated projection without re-encoding sender JSON.
/// The trusted profile, never a wire field, supplies the person/account scope.
