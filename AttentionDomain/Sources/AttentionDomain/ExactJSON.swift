import Foundation

public struct ExactText: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static func == (lhs: ExactText, rhs: ExactText) -> Bool {
        lhs.rawValue.utf8.elementsEqual(rhs.rawValue.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue.utf8.count)
        for byte in rawValue.utf8 {
            hasher.combine(byte)
        }
    }
}

public struct JSONNumber: Equatable, Codable, Sendable {
    public let lexeme: String

    public init(lexeme: String) {
        self.lexeme = lexeme
    }
}

public struct JSONMember: Equatable, Codable, Sendable {
    public let key: ExactText
    public let value: JSONValue

    public init(_ key: String, _ value: JSONValue) {
        self.key = ExactText(key)
        self.value = value
    }

    public init(key: ExactText, value: JSONValue) {
        self.key = key
        self.value = value
    }
}

public indirect enum JSONValue: Equatable, Codable, Sendable {
    case object([JSONMember])
    case array([JSONValue])
    case string(ExactText)
    case number(JSONNumber)
    case bool(Bool)
    case null

    public var objectMembers: [JSONMember]? {
        guard case let .object(members) = self else { return nil }
        return members
    }

    public var hasUniqueObjectKeys: Bool {
        guard case let .object(members) = self else { return false }
        return Set(members.map(\.key)).count == members.count
    }

    public var arrayValues: [JSONValue]? {
        guard case let .array(values) = self else { return nil }
        return values
    }

    public var stringValue: ExactText? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public func value(named name: String) -> JSONValue? {
        guard case let .object(members) = self else { return nil }
        let key = ExactText(name)
        return members.first(where: { $0.key == key })?.value
    }

    public func uniqueValue(named name: String) -> JSONValue? {
        guard case let .object(members) = self else { return nil }
        let key = ExactText(name)
        let matches = members.filter { $0.key == key }
        guard matches.count == 1 else { return nil }
        return matches[0].value
    }

    public var integerValue: Int? {
        guard case let .number(number) = self,
              !number.lexeme.contains("."),
              !number.lexeme.contains("e"),
              !number.lexeme.contains("E") else {
            return nil
        }
        return Int(number.lexeme)
    }

    public func hasExactlyKeys(_ names: [String]) -> Bool {
        guard case let .object(members) = self, members.count == names.count else {
            return false
        }

        let expected = Set(names.map(ExactText.init))
        let actual = Set(members.map(\.key))
        return actual.count == members.count && actual == expected
    }

    public var jsonString: String {
        switch self {
        case let .object(members):
            let contents = members.map { "\(Self.quote($0.key.rawValue)):\($0.value.jsonString)" }
            return "{\(contents.joined(separator: ","))}"
        case let .array(values):
            return "[\(values.map(\.jsonString).joined(separator: ","))]"
        case let .string(value):
            return Self.quote(value.rawValue)
        case let .number(number):
            return number.lexeme
        case let .bool(value):
            return value ? "true" : "false"
        case .null:
            return "null"
        }
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        // A relay delivery can wrap a server-admitted 2 MiB request in its
        // event envelope. Match the server's bounded response-frame ceiling.
        guard data.count <= 2 * (2 * 1024 * 1024) + 16_384 else {
            throw JSONParseError.documentTooLarge
        }
        var parser = ExactJSONParser(bytes: Array(data))
        return try parser.parseDocument()
    }

    private static func quote(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22:
                result += "\\\""
            case 0x5c:
                result += "\\\\"
            case 0x08:
                result += "\\b"
            case 0x0c:
                result += "\\f"
            case 0x0a:
                result += "\\n"
            case 0x0d:
                result += "\\r"
            case 0x09:
                result += "\\t"
            case 0x00...0x1f:
                result += String(format: "\\u%04x", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case members
        case values
        case string
        case number
        case bool
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "object":
            self = .object(try container.decode([JSONMember].self, forKey: .members))
        case "array":
            self = .array(try container.decode([JSONValue].self, forKey: .values))
        case "string":
            self = .string(try container.decode(ExactText.self, forKey: .string))
        case "number":
            self = .number(try container.decode(JSONNumber.self, forKey: .number))
        case "bool":
            self = .bool(try container.decode(Bool.self, forKey: .bool))
        case "null":
            self = .null
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind,
                                                   in: container,
                                                   debugDescription: "Unknown exact JSON value kind.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .object(members):
            try container.encode("object", forKey: .kind)
            try container.encode(members, forKey: .members)
        case let .array(values):
            try container.encode("array", forKey: .kind)
            try container.encode(values, forKey: .values)
        case let .string(string):
            try container.encode("string", forKey: .kind)
            try container.encode(string, forKey: .string)
        case let .number(number):
            try container.encode("number", forKey: .kind)
            try container.encode(number, forKey: .number)
        case let .bool(value):
            try container.encode("bool", forKey: .kind)
            try container.encode(value, forKey: .bool)
        case .null:
            try container.encode("null", forKey: .kind)
        }
    }
}

public extension JSONValue {
    func semanticallyEquals(_ other: JSONValue) -> Bool {
        switch (self, other) {
        case let (.object(left), .object(right)):
            guard left.count == right.count else { return false }
            let leftMembers = left.sorted(by: Self.memberOrdering)
            let rightMembers = right.sorted(by: Self.memberOrdering)
            return zip(leftMembers, rightMembers).allSatisfy { lhs, rhs in
                lhs.key == rhs.key && lhs.value.semanticallyEquals(rhs.value)
            }
        case let (.array(left), .array(right)):
            return left.count == right.count && zip(left, right).allSatisfy { $0.semanticallyEquals($1) }
        case let (.string(left), .string(right)):
            return left == right
        case let (.number(left), .number(right)):
            return left.lexeme == right.lexeme
        case let (.bool(left), .bool(right)):
            return left == right
        case (.null, .null):
            return true
        default:
            return false
        }
    }

    var canonicalJSON: String {
        switch self {
        case let .object(members):
            let sorted = members.sorted(by: Self.memberOrdering)
            return "{\(sorted.map { "\($0.key.rawValue.jsonQuoted):\($0.value.canonicalJSON)" }.joined(separator: ","))}"
        case let .array(values):
            return "[\(values.map(\.canonicalJSON).joined(separator: ","))]"
        case let .string(value):
            return value.rawValue.jsonQuoted
        case let .number(number):
            return number.lexeme
        case let .bool(value):
            return value ? "true" : "false"
        case .null:
            return "null"
        }
    }

    private static func memberOrdering(_ left: JSONMember, _ right: JSONMember) -> Bool {
        let leftBytes = Array(left.key.rawValue.utf8)
        let rightBytes = Array(right.key.rawValue.utf8)
        if leftBytes != rightBytes {
            return leftBytes.lexicographicallyPrecedes(rightBytes)
        }
        return left.value.canonicalJSON < right.value.canonicalJSON
    }
}

private extension String {
    var jsonQuoted: String {
        JSONValue.string(ExactText(self)).jsonString
    }
}

private enum JSONParseError: Error {
    case documentTooLarge
    case nestingTooDeep
    case unexpectedEnd
    case unexpectedToken
    case invalidString
    case invalidNumber
    case trailingData
}

private struct ExactJSONParser {
    let bytes: [UInt8]
    var index = 0

    mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        let result = try parseValue(depth: 1)
        skipWhitespace()
        guard index == bytes.count else { throw JSONParseError.trailingData }
        return result
    }

    private mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth <= 128 else { throw JSONParseError.nestingTooDeep }
        guard let byte = peek() else { throw JSONParseError.unexpectedEnd }
        switch byte {
        case 0x7b:
            return try parseObject(depth: depth)
        case 0x5b:
            return try parseArray(depth: depth)
        case 0x22:
            return .string(try parseString())
        case 0x74:
            try consumeLiteral("true")
            return .bool(true)
        case 0x66:
            try consumeLiteral("false")
            return .bool(false)
        case 0x6e:
            try consumeLiteral("null")
            return .null
        case 0x2d, 0x30...0x39:
            return .number(try parseNumber())
        default:
            throw JSONParseError.unexpectedToken
        }
    }

    private mutating func parseObject(depth: Int) throws -> JSONValue {
        _ = consume(0x7b)
        skipWhitespace()
        if consume(0x7d) { return .object([]) }

        var members: [JSONMember] = []
        while true {
            guard peek() == 0x22 else { throw JSONParseError.unexpectedToken }
            let key = try parseString()
            skipWhitespace()
            guard consume(0x3a) else { throw JSONParseError.unexpectedToken }
            skipWhitespace()
            members.append(JSONMember(key: key, value: try parseValue(depth: depth + 1)))
            skipWhitespace()
            if consume(0x7d) { return .object(members) }
            guard consume(0x2c) else { throw JSONParseError.unexpectedToken }
            skipWhitespace()
        }
    }

    private mutating func parseArray(depth: Int) throws -> JSONValue {
        _ = consume(0x5b)
        skipWhitespace()
        if consume(0x5d) { return .array([]) }

        var values: [JSONValue] = []
        while true {
            values.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            if consume(0x5d) { return .array(values) }
            guard consume(0x2c) else { throw JSONParseError.unexpectedToken }
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> ExactText {
        guard peek() == 0x22 else { throw JSONParseError.unexpectedToken }
        let start = index
        index += 1

        while index < bytes.count {
            switch bytes[index] {
            case 0x22:
                index += 1
                let token = Data(bytes[start..<index])
                do {
                    return ExactText(try JSONDecoder().decode(String.self, from: token))
                } catch {
                    throw JSONParseError.invalidString
                }
            case 0x5c:
                index += 1
                guard index < bytes.count else { throw JSONParseError.unexpectedEnd }
                if bytes[index] == 0x75 {
                    index += 1
                    guard index + 4 <= bytes.count else { throw JSONParseError.unexpectedEnd }
                    index += 4
                } else {
                    index += 1
                }
            default:
                index += 1
            }
        }
        throw JSONParseError.unexpectedEnd
    }

    private mutating func parseNumber() throws -> JSONNumber {
        let start = index
        _ = consume(0x2d)

        if consume(0x30) {
            if let byte = peek(), isDigit(byte) { throw JSONParseError.invalidNumber }
        } else {
            guard consumeDigit(nonZero: true) else { throw JSONParseError.invalidNumber }
            while let byte = peek(), isDigit(byte) { index += 1 }
        }

        if consume(0x2e) {
            guard consumeDigit(nonZero: false) else { throw JSONParseError.invalidNumber }
            while let byte = peek(), isDigit(byte) { index += 1 }
        }

        if consume(0x65) || consume(0x45) {
            if !consume(0x2b) { _ = consume(0x2d) }
            guard consumeDigit(nonZero: false) else { throw JSONParseError.invalidNumber }
            while let byte = peek(), isDigit(byte) { index += 1 }
        }

        return JSONNumber(lexeme: String(decoding: bytes[start..<index], as: UTF8.self))
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        for byte in literal.utf8 where !consume(byte) {
            throw JSONParseError.unexpectedToken
        }
    }

    private mutating func consumeDigit(nonZero: Bool) -> Bool {
        guard let byte = peek(), isDigit(byte), !nonZero || byte != 0x30 else { return false }
        index += 1
        return true
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard peek() == byte else { return false }
        index += 1
        return true
    }

    private func peek() -> UInt8? {
        guard index < bytes.count else { return nil }
        return bytes[index]
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }

    private mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d {
            index += 1
        }
    }
}
