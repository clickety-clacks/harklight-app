import Foundation

public struct RequestKey: Hashable, Codable, Identifiable, Sendable {
    public let accountScope: ExactText
    public let senderID: ExactText
    public let messageID: ExactText

    public init(accountScope: ExactText, senderID: ExactText, messageID: ExactText) {
        self.accountScope = accountScope
        self.senderID = senderID
        self.messageID = messageID
    }

    public var id: RequestKey { self }
}

public enum ActionKind: Equatable, Sendable {
    case value
    case text
}

public struct AnswerAction: Equatable, Identifiable, Sendable {
    public let id: ExactText
    public let label: ExactText
    public let kind: ActionKind
    public let value: JSONValue?

    public init(id: ExactText, label: ExactText, kind: ActionKind, value: JSONValue?) {
        self.id = id
        self.label = label
        self.kind = kind
        self.value = value
    }
}

public struct AnswerForm: Equatable, Sendable {
    public let actions: [AnswerAction]

    public static func recognize(_ description: JSONValue?) -> AnswerForm? {
        guard let description,
              description.hasExactlyKeys(["schema", "actions"]),
              case let .string(schema)? = description.uniqueValue(named: "schema"),
              schema == ExactText("attention-client.actions/1"),
              let actionValues = description.uniqueValue(named: "actions")?.arrayValues,
              !actionValues.isEmpty else {
            return nil
        }

        var actions: [AnswerAction] = []
        var seenIDs = Set<ExactText>()

        for actionValue in actionValues {
            guard case .object = actionValue,
                  actionValue.hasUniqueObjectKeys,
                  case let .string(id)? = actionValue.uniqueValue(named: "id"),
                  !id.rawValue.isEmpty,
                  seenIDs.insert(id).inserted,
                  case let .string(label)? = actionValue.uniqueValue(named: "label"),
                  !label.rawValue.isEmpty,
                  case let .string(kind)? = actionValue.uniqueValue(named: "kind") else {
                return nil
            }

            switch kind.rawValue {
            case "value":
                guard actionValue.hasExactlyKeys(["id", "label", "kind", "value"]),
                      let value = actionValue.uniqueValue(named: "value") else {
                    return nil
                }
                actions.append(AnswerAction(id: id, label: label, kind: .value, value: value))
            case "text":
                guard actionValue.hasExactlyKeys(["id", "label", "kind"]) else {
                    return nil
                }
                actions.append(AnswerAction(id: id, label: label, kind: .text, value: nil))
            default:
                return nil
            }
        }

        return AnswerForm(actions: actions)
    }

    public func action(withID id: ExactText) -> AnswerAction? {
        actions.first(where: { $0.id == id })
    }
}

public struct FixtureRequest: Equatable, Identifiable, Sendable {
    public let key: RequestKey
    public let title: ExactText
    public let body: ExactText?
    public let stake: JSONValue?
    public let byWhen: JSONValue?
    public let createdAt: JSONValue?
    public let answerDescription: JSONValue?
    public let interface: RequestInterface
    public let originalPayload: JSONValue

    public var id: RequestKey { key }
}

public struct FixtureSet: Equatable, Sendable {
    public let accountScope: ExactText
    public let requests: [FixtureRequest]
    public let legacyValueConformanceVectors: [JSONValue]
    public let legacyTextConformanceVectors: [ExactText]
    public let validSubmissions: [JSONValue]
    public let invalidSubmissions: [JSONValue]
    public let pointVectors: [JSONValue]
    public let terminalContexts: [JSONValue]
    public let additionalCases: [ExactText]

    public init(accountScope: ExactText,
                requests: [FixtureRequest],
                legacyValueConformanceVectors: [JSONValue],
                legacyTextConformanceVectors: [ExactText],
                validSubmissions: [JSONValue],
                invalidSubmissions: [JSONValue],
                pointVectors: [JSONValue],
                terminalContexts: [JSONValue],
                additionalCases: [ExactText]) {
        self.accountScope = accountScope
        self.requests = requests
        self.legacyValueConformanceVectors = legacyValueConformanceVectors
        self.legacyTextConformanceVectors = legacyTextConformanceVectors
        self.validSubmissions = validSubmissions
        self.invalidSubmissions = invalidSubmissions
        self.pointVectors = pointVectors
        self.terminalContexts = terminalContexts
        self.additionalCases = additionalCases
    }

    public static func loadBundled(from bundle: Bundle = .main) throws -> FixtureSet {
        guard let fixtureURL = bundle.url(forResource: "attention-client-m2-fixtures", withExtension: "json"),
              let compatibilityURL = bundle.url(forResource: "attention-client-m2-r1-compat", withExtension: "json") else {
            throw FixtureLoadError.missingResource
        }
        return try parse(Data(contentsOf: fixtureURL), compatibilityData: Data(contentsOf: compatibilityURL))
    }

    public static func parse(_ data: Data, compatibilityData: Data) throws -> FixtureSet {
        let root = try JSONValue.parse(data)
        guard let accountScope = root.uniqueValue(named: "account")?.stringValue,
              let requestValues = root.uniqueValue(named: "requests")?.arrayValues,
              let requestOrder = root.uniqueValue(named: "requestOrder")?.arrayValues else {
            throw FixtureLoadError.invalidRoot
        }

        let requests = try requestValues.map { value -> FixtureRequest in
            guard case .object = value,
                  value.hasUniqueObjectKeys,
                  let senderID = value.uniqueValue(named: "sender_id")?.stringValue,
                  let messageID = value.uniqueValue(named: "message_id")?.stringValue,
                  let title = value.uniqueValue(named: "title")?.stringValue else {
                throw FixtureLoadError.invalidRequest
            }

            let body: ExactText?
            if let bodyValue = value.uniqueValue(named: "body") {
                guard let string = bodyValue.stringValue else { throw FixtureLoadError.invalidRequest }
                body = string
            } else {
                body = nil
            }

            let descriptorValues = value.objectMembers?.filter { $0.key == ExactText("answer_ui") } ?? []
            let answerDescription = descriptorValues.count == 1 ? descriptorValues[0].value : nil
            let interface: RequestInterface = descriptorValues.count > 1
                ? .unsupported(.unfamiliar)
                : RequestInterface.recognize(answerDescription)

            return FixtureRequest(
                key: RequestKey(accountScope: accountScope, senderID: senderID, messageID: messageID),
                title: title,
                body: body,
                stake: value.uniqueValue(named: "stake"),
                byWhen: value.uniqueValue(named: "by_when"),
                createdAt: value.uniqueValue(named: "created_at"),
                answerDescription: answerDescription,
                interface: interface,
                originalPayload: value
            )
        }

        guard requestOrder.compactMap(\.stringValue).map(\.rawValue) == requests.map({ $0.key.messageID.rawValue }),
              Set(requests.map(\.key)).count == requests.count else {
            throw FixtureLoadError.duplicateRequestKey
        }

        let compatibility = try JSONValue.parse(compatibilityData)
        guard let legacyValues = compatibility.uniqueValue(named: "value_conformance_vectors")?.arrayValues,
              let legacyTexts = compatibility.uniqueValue(named: "text_conformance_vectors")?.arrayValues else {
            throw FixtureLoadError.invalidCompatibilityData
        }
        let textVectors = try legacyTexts.map { value -> ExactText in
            guard let string = value.stringValue else { throw FixtureLoadError.invalidVector }
            return string
        }

        return FixtureSet(
            accountScope: accountScope,
            requests: requests,
            legacyValueConformanceVectors: legacyValues,
            legacyTextConformanceVectors: textVectors,
            validSubmissions: root.uniqueValue(named: "validSubmissions")?.arrayValues ?? [],
            invalidSubmissions: root.uniqueValue(named: "invalidSubmissions")?.arrayValues ?? [],
            pointVectors: root.uniqueValue(named: "pointVectors")?.arrayValues ?? [],
            terminalContexts: root.uniqueValue(named: "terminalContexts")?.arrayValues ?? [],
            additionalCases: root.uniqueValue(named: "additionalCases")?.arrayValues?.compactMap(\.stringValue) ?? []
        )
    }
}

enum FixtureLoadError: Error {
    case missingResource
    case invalidRoot
    case invalidRequest
    case duplicateRequestKey
    case invalidCompatibilityData
    case invalidVector
}

public enum AnswerComposer {
    public static func compose(action: AnswerAction, editedText: ExactText) -> JSONValue? {
        switch action.kind {
        case .value:
            return action.value
        case .text:
            return .string(editedText)
        }
    }
}
