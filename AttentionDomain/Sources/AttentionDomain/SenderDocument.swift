import Foundation
import CoreGraphics

public enum UnsupportedInterfaceReason: Equatable, Sendable {
    case missing
    case unfamiliar
}

public enum RequestInterface: Equatable, Sendable {
    case sender(SenderDocument)
    case compatibility(AnswerForm)
    case unsupported(UnsupportedInterfaceReason)

    public static func recognize(_ description: JSONValue?,
                                 deliveredFileNames: Set<ExactText> = []) -> RequestInterface {
        guard let description else {
            // A plain Harklight message has no sender-authored interface.
            // Give it one app-owned deliberate text reply whose answer is the
            // exact JSON string the sender can read from its origin receipt.
            return .compatibility(AnswerForm(actions: [
                AnswerAction(id: ExactText("reply"),
                             label: ExactText("Reply"),
                             kind: .text,
                             value: nil)
            ]))
        }
        guard description.hasUniqueObjectKeys,
              let schema = description.uniqueValue(named: "schema")?.stringValue else {
            return .unsupported(.unfamiliar)
        }

        switch schema.rawValue {
        case "attention-client.ui/1":
            guard let document = try? SenderDocument.parse(description,
                                                            deliveredFileNames: deliveredFileNames) else {
                return .unsupported(.unfamiliar)
            }
            return .sender(document)
        case "attention-client.actions/1":
            guard let form = AnswerForm.recognize(description) else {
                return .unsupported(.unfamiliar)
            }
            return .compatibility(form)
        default:
            return .unsupported(.unfamiliar)
        }
    }
}

public enum SenderInputKind: Equatable, Sendable {
    case response([SenderAction])
    case text
    case point(illustrationID: ExactText)
}

public struct SenderInput: Equatable, Identifiable, Sendable {
    public let id: ExactText
    public let label: ExactText
    public let kind: SenderInputKind
}

public enum SenderActionKind: Equatable, Sendable {
    case value(JSONValue)
    case text
}

public struct SenderAction: Equatable, Identifiable, Sendable {
    public let id: ExactText
    public let label: ExactText
    public let kind: SenderActionKind
    public let illustrationID: ExactText?
}

public struct SenderIllustration: Equatable, Identifiable, Sendable {
    public let id: ExactText
    public let label: ExactText
    public let width: Int
    public let height: Int
    public let primitives: [GraphicPrimitive]
}

public enum GraphicPrimitive: Equatable, Sendable {
    case rect(x: Int, y: Int, width: Int, height: Int, fill: ExactText)
    case circle(cx: Int, cy: Int, radius: Int, fill: ExactText)
    case line(x1: Int, y1: Int, x2: Int, y2: Int, stroke: ExactText, strokeWidth: Int)
    case text(x: Int, y: Int, text: ExactText, fill: ExactText, fontSize: Int, align: GraphicTextAlignment)
    case image(x: Int, y: Int, width: Int, height: Int, file: ExactText)
}

public enum GraphicTextAlignment: String, Equatable, Sendable {
    case start
    case middle
    case end
}

public enum SceneAxis: Equatable, Sendable {
    case vertical
    case horizontal
}

public enum SceneTextStyle: String, Equatable, Sendable {
    case title
    case body
    case caption
}

public enum InputLayout: String, Equatable, Sendable {
    case cards
    case list
    case editor
    case diagram
}

public enum ScenePathComponent: Equatable, Sendable {
    case key(ExactText)
    case index(Int)
}

public enum SceneKind: Equatable, Sendable {
    case stack(SceneAxis, [SceneNode])
    case grid(columns: Int, [SceneNode])
    case text(ExactText, SceneTextStyle)
    case illustration(ExactText)
    case input(ExactText, InputLayout)
    case resultPoint(illustrationID: ExactText, label: ExactText, path: [ScenePathComponent])
}

public struct SceneNode: Equatable, Identifiable, Sendable {
    // Nodes live in an immutable accepted descriptor; the structural path remains stable while it reflows.
    public let id: String
    public let kind: SceneKind
}

public enum ResultConstructor: Equatable, Sendable {
    case literal(JSONValue)
    case input(ExactText)
    case array([ResultConstructor])
    case object([ResultMember])
}

public struct ResultMember: Equatable, Sendable {
    public let name: ExactText
    public let value: ResultConstructor
}

public enum TerminalState: String, CaseIterable, Equatable, Codable, Sendable {
    case answered
    case noComment = "no_comment"
    case cleared
    case expired
    case superseded
}

public struct PointValue: Equatable, Codable, Sendable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    public var jsonValue: JSONValue {
        .object([
            JSONMember("x", .number(JSONNumber(lexeme: String(x)))),
            JSONMember("y", .number(JSONNumber(lexeme: String(y))))
        ])
    }
}

public struct InputDraft: Equatable, Codable, Sendable {
    public var selectedActionID: ExactText?
    public var textByActionID: [ExactText: ExactText]
    public var text: ExactText?
    public var point: PointValue?
    public var horizontalText: ExactText?
    public var verticalText: ExactText?

    public init(selectedActionID: ExactText? = nil,
                textByActionID: [ExactText: ExactText] = [:],
                text: ExactText? = nil,
                point: PointValue? = nil,
                horizontalText: ExactText? = nil,
                verticalText: ExactText? = nil) {
        self.selectedActionID = selectedActionID
        self.textByActionID = textByActionID
        self.text = text
        self.point = point
        self.horizontalText = horizontalText
        self.verticalText = verticalText
    }

    public var hasInitializedPoint: Bool { point != nil }

    public static func initial(for input: SenderInput) -> InputDraft {
        switch input.kind {
        case .response:
            return InputDraft(selectedActionID: nil)
        case .text:
            return InputDraft(selectedActionID: nil, text: ExactText(""))
        case .point:
            return InputDraft(selectedActionID: nil)
        }
    }

    public var effectivePoint: PointValue? {
        guard let horizontalText, let verticalText else { return point }
        guard let x = Self.coordinate(horizontalText),
              let y = Self.coordinate(verticalText) else { return nil }
        return PointValue(x: x, y: y)
    }

    public var hasInvalidCoordinateEntry: Bool {
        guard horizontalText != nil || verticalText != nil else { return false }
        return effectivePoint == nil
    }

    public static func coordinate(_ text: ExactText) -> Int? {
        let bytes = Array(text.rawValue.utf8)
        guard !bytes.isEmpty, bytes.allSatisfy({ (0x30...0x39).contains($0) }),
              let value = Int(text.rawValue), (0...1000).contains(value) else {
            return nil
        }
        return value
    }
}

public struct SenderDocument: Equatable, Sendable {
    public let illustrations: [SenderIllustration]
    public let inputs: [SenderInput]
    public let open: SceneNode
    public let resolved: SceneNode
    public let resolvedByState: [TerminalState: SceneNode]
    public let answeredWithResult: SceneNode?
    public let submissionLabel: ExactText
    public let result: ResultConstructor

    public static func parse(_ root: JSONValue,
                             deliveredFileNames: Set<ExactText> = []) throws -> SenderDocument {
        var parser = SenderDocumentParser()
        return try parser.parse(root, deliveredFileNames: deliveredFileNames)
    }

    public func input(withID id: ExactText) -> SenderInput? {
        inputs.first(where: { $0.id == id })
    }

    public func illustration(withID id: ExactText) -> SenderIllustration? {
        illustrations.first(where: { $0.id == id })
    }

    public func compose(drafts: [ExactText: InputDraft], maximumBytes: Int) -> JSONValue? {
        let expectedIDs = Set(inputs.map(\.id))
        guard drafts.count == inputs.count, Set(drafts.keys) == expectedIDs else { return nil }

        for input in inputs {
            guard let draft = drafts[input.id] else { return nil }
            switch input.kind {
            case let .response(actions):
                guard draft.text == nil, draft.point == nil,
                      draft.horizontalText == nil, draft.verticalText == nil,
                      draft.textByActionID.keys.allSatisfy({ actionID in
                          actions.contains(where: { action in
                              guard action.id == actionID else { return false }
                              if case .text = action.kind { return true }
                              return false
                          })
                      }) else { return nil }
            case .text:
                guard draft.text != nil, draft.selectedActionID == nil, draft.point == nil,
                      draft.horizontalText == nil, draft.verticalText == nil,
                      draft.textByActionID.isEmpty else { return nil }
            case .point:
                guard draft.effectivePoint != nil, draft.selectedActionID == nil, draft.text == nil,
                      draft.horizontalText != nil, draft.verticalText != nil,
                      draft.textByActionID.isEmpty else { return nil }
            }
        }

        guard let answer = evaluate(result, drafts: drafts),
              answer.jsonString.utf8.count <= maximumBytes else { return nil }
        return answer
    }

    public func terminalScene(state: TerminalState, authorizedAnswer: JSONValue?) -> SceneNode {
        if state == .answered,
           let authorizedAnswer,
           let answeredWithResult,
           Self.resultPoints(in: answeredWithResult).allSatisfy({ resultPoint(in: $0, answer: authorizedAnswer) != nil }) {
            return answeredWithResult
        }
        return resolvedByState[state] ?? resolved
    }

    public func resultPoint(in node: SceneNode, answer: JSONValue) -> PointValue? {
        guard case let .resultPoint(_, _, path) = node.kind else { return nil }
        var current = answer
        for component in path {
            switch (component, current) {
            case let (.key(key), .object(members)):
                guard members.count == Set(members.map(\.key)).count,
                      let next = members.first(where: { $0.key == key })?.value else { return nil }
                current = next
            case let (.index(index), .array(values)):
                guard values.indices.contains(index) else { return nil }
                current = values[index]
            default:
                return nil
            }
        }
        guard current.hasExactlyKeys(["x", "y"]),
              let x = current.uniqueValue(named: "x")?.integerValue,
              let y = current.uniqueValue(named: "y")?.integerValue,
              (0...1000).contains(x), (0...1000).contains(y) else { return nil }
        return PointValue(x: x, y: y)
    }

    private func evaluate(_ constructor: ResultConstructor, drafts: [ExactText: InputDraft]) -> JSONValue? {
        switch constructor {
        case let .literal(value):
            return value
        case let .input(id):
            guard let input = input(withID: id), let draft = drafts[id] else { return nil }
            switch input.kind {
            case let .response(actions):
                guard let actionID = draft.selectedActionID,
                      let action = actions.first(where: { $0.id == actionID }) else { return nil }
                switch action.kind {
                case let .value(value):
                    guard draft.textByActionID[action.id] == nil else { return nil }
                    return value
                case .text:
                    guard let text = draft.textByActionID[action.id] else { return nil }
                    return .string(text)
                }
            case .text:
                guard let text = draft.text else { return nil }
                return .string(text)
            case .point:
                guard let point = draft.effectivePoint else { return nil }
                return point.jsonValue
            }
        case let .array(values):
            var result: [JSONValue] = []
            for value in values {
                guard let evaluated = evaluate(value, drafts: drafts) else { return nil }
                result.append(evaluated)
            }
            return .array(result)
        case let .object(members):
            var result: [JSONMember] = []
            for member in members {
                guard let evaluated = evaluate(member.value, drafts: drafts) else { return nil }
                result.append(JSONMember(key: member.name, value: evaluated))
            }
            return .object(result)
        }
    }

    private static func resultPoints(in node: SceneNode) -> [SceneNode] {
        switch node.kind {
        case .resultPoint:
            return [node]
        case let .stack(_, children), let .grid(_, children):
            return children.flatMap(resultPoints(in:))
        case .text, .illustration, .input:
            return []
        }
    }
}

private struct SenderDocumentParser {
    private var illustrations: [SenderIllustration] = []
    private var inputs: [SenderInput] = []
    private var illustrationIDs = Set<ExactText>()
    private var inputIDs = Set<ExactText>()
    private var referencedIllustrations = Set<ExactText>()
    private var openInputCounts: [ExactText: Int] = [:]
    private var sceneNodeCount = 0
    private var resultNodeCount = 0
    private var usesResultPoint = false
    private var deliveredFileNames = Set<ExactText>()

    mutating func parse(_ root: JSONValue,
                        deliveredFileNames: Set<ExactText>) throws -> SenderDocument {
        self.deliveredFileNames = deliveredFileNames
        let document = try fields(root,
                                  required: ["schema", "requires", "illustrations", "inputs", "open", "resolved", "submission"],
                                  optional: ["resolvedByState", "answeredWithResult"])
        guard try string(document["schema"], nonempty: true).rawValue == "attention-client.ui/1",
              root.jsonString.utf8.count <= 65_536 else { throw SenderDocumentError.invalid }

        let requiredCapabilities = try stringArray(document["requires"], nonempty: true, maximumCount: 8)
        guard Set(requiredCapabilities).count == requiredCapabilities.count else { throw SenderDocumentError.invalid }

        try parseIllustrations(document["illustrations"])
        try parseInputs(document["inputs"])

        let open = try parseScene(document["open"], path: "open", depth: 1, terminal: false, resultBranch: false)
        let resolved = try parseScene(document["resolved"], path: "resolved", depth: 1, terminal: true, resultBranch: false)

        var resolvedByState: [TerminalState: SceneNode] = [:]
        if let rawStates = document["resolvedByState"] {
            guard let members = rawStates.objectMembers, rawStates.hasUniqueObjectKeys else { throw SenderDocumentError.invalid }
            for member in members {
                guard let state = TerminalState(rawValue: member.key.rawValue) else { throw SenderDocumentError.invalid }
                resolvedByState[state] = try parseScene(member.value,
                                                        path: "resolvedByState.\(state.rawValue)",
                                                        depth: 1,
                                                        terminal: true,
                                                        resultBranch: false)
            }
        }

        let answeredWithResult: SceneNode?
        if let rawKnown = document["answeredWithResult"] {
            answeredWithResult = try parseScene(rawKnown, path: "answeredWithResult", depth: 1, terminal: true, resultBranch: true)
        } else {
            answeredWithResult = nil
        }

        let submission = try fields(document["submission"], required: ["label", "result"])
        let submissionLabel = try string(submission["label"], nonempty: true)
        let result = try parseConstructor(submission["result"], path: "result", depth: 1)

        guard sceneNodeCount <= 128,
              resultNodeCount <= 128,
              Set(inputs.map(\.id)) == Set(openInputCounts.keys),
              inputs.allSatisfy({ openInputCounts[$0.id] == 1 }),
              Set(inputs.map(\.id)).isSubset(of: constructorInputReferences(in: result)),
              Set(illustrations.map(\.id)).isSubset(of: referencedIllustrations) else {
            throw SenderDocumentError.invalid
        }

        let expectedCapabilities = capabilities()
        guard Set(requiredCapabilities) == expectedCapabilities else { throw SenderDocumentError.invalid }

        return SenderDocument(illustrations: illustrations,
                              inputs: inputs,
                              open: open,
                              resolved: resolved,
                              resolvedByState: resolvedByState,
                              answeredWithResult: answeredWithResult,
                              submissionLabel: submissionLabel,
                              result: result)
    }

    private mutating func parseIllustrations(_ raw: JSONValue?) throws {
        guard let values = raw?.arrayValues, values.count <= 64 else { throw SenderDocumentError.invalid }
        for value in values {
            let item = try fields(value, required: ["id", "label", "width", "height", "primitives"])
            let id = try identifier(item["id"])
            guard illustrationIDs.insert(id).inserted else { throw SenderDocumentError.invalid }
            let label = try string(item["label"], nonempty: true)
            let width = try integer(item["width"], range: 1...4096)
            let height = try integer(item["height"], range: 1...4096)
            guard let primitives = item["primitives"]?.arrayValues,
                  primitives.count <= 512 else { throw SenderDocumentError.invalid }
            let parsed = try primitives.map(parsePrimitive)
            illustrations.append(SenderIllustration(id: id, label: label, width: width, height: height, primitives: parsed))
        }
        guard illustrations.reduce(0, { $0 + $1.primitives.count }) <= 512 else { throw SenderDocumentError.invalid }
    }

    private func parsePrimitive(_ raw: JSONValue) throws -> GraphicPrimitive {
        guard let kind = raw.uniqueValue(named: "kind")?.stringValue?.rawValue else { throw SenderDocumentError.invalid }
        switch kind {
        case "rect":
            let item = try fields(raw, required: ["kind", "x", "y", "width", "height", "fill"])
            return .rect(x: try integer(item["x"], range: 0...4096),
                         y: try integer(item["y"], range: 0...4096),
                         width: try integer(item["width"], range: 1...4096),
                         height: try integer(item["height"], range: 1...4096),
                         fill: try color(item["fill"]))
        case "circle":
            let item = try fields(raw, required: ["kind", "cx", "cy", "r", "fill"])
            return .circle(cx: try integer(item["cx"], range: 0...4096),
                           cy: try integer(item["cy"], range: 0...4096),
                           radius: try integer(item["r"], range: 1...4096),
                           fill: try color(item["fill"]))
        case "line":
            let item = try fields(raw, required: ["kind", "x1", "y1", "x2", "y2", "stroke", "strokeWidth"])
            return .line(x1: try integer(item["x1"], range: 0...4096),
                         y1: try integer(item["y1"], range: 0...4096),
                         x2: try integer(item["x2"], range: 0...4096),
                         y2: try integer(item["y2"], range: 0...4096),
                         stroke: try color(item["stroke"]),
                         strokeWidth: try integer(item["strokeWidth"], range: 1...64))
        case "text":
            let item = try fields(raw, required: ["kind", "x", "y", "text", "fill", "fontSize", "align"])
            let alignment = try string(item["align"], nonempty: true)
            guard let align = GraphicTextAlignment(rawValue: alignment.rawValue) else { throw SenderDocumentError.invalid }
            return .text(x: try integer(item["x"], range: 0...4096),
                         y: try integer(item["y"], range: 0...4096),
                         text: try string(item["text"]),
                         fill: try color(item["fill"]),
                         fontSize: try integer(item["fontSize"], range: 1...256),
                         align: align)
        case "image":
            let item = try fields(raw, required: ["kind", "x", "y", "width", "height", "file"])
            let file = try string(item["file"], nonempty: true)
            guard deliveredFileNames.contains(file) else { throw SenderDocumentError.invalid }
            return .image(x: try integer(item["x"], range: 0...4096),
                          y: try integer(item["y"], range: 0...4096),
                          width: try integer(item["width"], range: 1...4096),
                          height: try integer(item["height"], range: 1...4096),
                          file: file)
        default:
            throw SenderDocumentError.invalid
        }
    }

    private mutating func parseInputs(_ raw: JSONValue?) throws {
        guard let values = raw?.arrayValues, values.count <= 16 else { throw SenderDocumentError.invalid }
        for value in values {
            guard let kind = value.uniqueValue(named: "kind")?.stringValue?.rawValue else { throw SenderDocumentError.invalid }
            let input: SenderInput
            switch kind {
            case "response":
                let item = try fields(value, required: ["kind", "id", "label", "actions"])
                let id = try identifier(item["id"])
                let label = try string(item["label"], nonempty: true)
                guard let rawActions = item["actions"]?.arrayValues,
                      !rawActions.isEmpty, rawActions.count <= 64 else { throw SenderDocumentError.invalid }
                var seen = Set<ExactText>()
                var actions: [SenderAction] = []
                for rawAction in rawActions {
                    actions.append(try parseAction(rawAction, seen: &seen))
                }
                input = SenderInput(id: id, label: label, kind: .response(actions))
            case "text":
                let item = try fields(value, required: ["kind", "id", "label"])
                input = SenderInput(id: try identifier(item["id"]),
                                    label: try string(item["label"], nonempty: true),
                                    kind: .text)
            case "point":
                let item = try fields(value, required: ["kind", "id", "label", "illustration"])
                let illustrationID = try identifier(item["illustration"])
                try requireIllustration(illustrationID)
                input = SenderInput(id: try identifier(item["id"]),
                                    label: try string(item["label"], nonempty: true),
                                    kind: .point(illustrationID: illustrationID))
            default:
                throw SenderDocumentError.invalid
            }
            guard inputIDs.insert(input.id).inserted else { throw SenderDocumentError.invalid }
            inputs.append(input)
        }
    }

    private mutating func parseAction(_ raw: JSONValue, seen: inout Set<ExactText>) throws -> SenderAction {
        let base = try fields(raw,
                              required: ["id", "label", "kind"],
                              optional: ["value", "illustration"])
        let id = try identifier(base["id"])
        guard seen.insert(id).inserted else { throw SenderDocumentError.invalid }
        let label = try string(base["label"], nonempty: true)
        let kindText = try string(base["kind"], nonempty: true)
        let value: SenderActionKind
        switch kindText.rawValue {
        case "value":
            guard let literal = base["value"] else { throw SenderDocumentError.invalid }
            value = .value(literal)
        case "text":
            guard base["value"] == nil else { throw SenderDocumentError.invalid }
            value = .text
        default:
            throw SenderDocumentError.invalid
        }
        if case .value = value {
            guard base["value"] != nil else { throw SenderDocumentError.invalid }
        } else if base["value"] != nil {
            throw SenderDocumentError.invalid
        }
        let illustrationID: ExactText?
        if let rawID = base["illustration"] {
            let id = try identifier(rawID)
            try requireIllustration(id)
            illustrationID = id
        } else {
            illustrationID = nil
        }
        return SenderAction(id: id, label: label, kind: value, illustrationID: illustrationID)
    }

    private mutating func parseScene(_ raw: JSONValue?, path: String, depth: Int, terminal: Bool, resultBranch: Bool) throws -> SceneNode {
        guard depth <= 16, let raw,
              let kind = raw.uniqueValue(named: "kind")?.stringValue?.rawValue else { throw SenderDocumentError.invalid }
        sceneNodeCount += 1
        guard sceneNodeCount <= 128 else { throw SenderDocumentError.invalid }

        let node: SceneKind
        switch kind {
        case "stack":
            let item = try fields(raw, required: ["kind", "axis", "children"])
            let axisText = try string(item["axis"], nonempty: true)
            let axis: SceneAxis
            switch axisText.rawValue {
            case "vertical": axis = .vertical
            case "horizontal": axis = .horizontal
            default: throw SenderDocumentError.invalid
            }
            guard let children = item["children"]?.arrayValues, !children.isEmpty else { throw SenderDocumentError.invalid }
            var parsed: [SceneNode] = []
            for (index, child) in children.enumerated() {
                parsed.append(try parseScene(child, path: "\(path).\(index)", depth: depth + 1, terminal: terminal, resultBranch: resultBranch))
            }
            node = .stack(axis, parsed)
        case "grid":
            let item = try fields(raw, required: ["kind", "columns", "children"])
            let columns = try integer(item["columns"], range: 1...4)
            guard let children = item["children"]?.arrayValues, !children.isEmpty else { throw SenderDocumentError.invalid }
            var parsed: [SceneNode] = []
            for (index, child) in children.enumerated() {
                parsed.append(try parseScene(child, path: "\(path).\(index)", depth: depth + 1, terminal: terminal, resultBranch: resultBranch))
            }
            node = .grid(columns: columns, parsed)
        case "text":
            let item = try fields(raw, required: ["kind", "text", "style"])
            let styleText = try string(item["style"], nonempty: true)
            guard let style = SceneTextStyle(rawValue: styleText.rawValue) else { throw SenderDocumentError.invalid }
            node = .text(try string(item["text"]), style)
        case "illustration":
            let item = try fields(raw, required: ["kind", "id"])
            let id = try identifier(item["id"])
            try requireIllustration(id)
            node = .illustration(id)
        case "input":
            let item = try fields(raw, required: ["kind", "id", "layout"])
            guard !terminal else { throw SenderDocumentError.invalid }
            let id = try identifier(item["id"])
            guard let input = inputs.first(where: { $0.id == id }) else { throw SenderDocumentError.invalid }
            let layoutText = try string(item["layout"], nonempty: true)
            guard let layout = InputLayout(rawValue: layoutText.rawValue) else { throw SenderDocumentError.invalid }
            switch (input.kind, layout) {
            case (.response, .cards), (.response, .list), (.text, .editor), (.point(_), .diagram): break
            default: throw SenderDocumentError.invalid
            }
            if path == "open" || path.hasPrefix("open.") { openInputCounts[id, default: 0] += 1 }
            node = .input(id, layout)
        case "result-point":
            let item = try fields(raw, required: ["kind", "id", "label", "path"])
            guard terminal, resultBranch else { throw SenderDocumentError.invalid }
            let id = try identifier(item["id"])
            try requireIllustration(id)
            let label = try string(item["label"], nonempty: true)
            guard let pathValues = item["path"]?.arrayValues, pathValues.count <= 16 else { throw SenderDocumentError.invalid }
            var resultPath: [ScenePathComponent] = []
            for value in pathValues {
                if let key = value.stringValue {
                    resultPath.append(.key(key))
                } else if let index = value.integerValue, (0...65_535).contains(index) {
                    resultPath.append(.index(index))
                } else {
                    throw SenderDocumentError.invalid
                }
            }
            usesResultPoint = true
            node = .resultPoint(illustrationID: id, label: label, path: resultPath)
        default:
            throw SenderDocumentError.invalid
        }
        return SceneNode(id: path, kind: node)
    }

    private mutating func parseConstructor(_ raw: JSONValue?, path: String, depth: Int) throws -> ResultConstructor {
        guard depth <= 16, let raw,
              let kind = raw.uniqueValue(named: "kind")?.stringValue?.rawValue else { throw SenderDocumentError.invalid }
        resultNodeCount += 1
        guard resultNodeCount <= 128 else { throw SenderDocumentError.invalid }
        switch kind {
        case "literal":
            let item = try fields(raw, required: ["kind", "value"])
            guard let value = item["value"] else { throw SenderDocumentError.invalid }
            return .literal(value)
        case "input":
            let item = try fields(raw, required: ["kind", "id"])
            let id = try identifier(item["id"])
            guard inputIDs.contains(id) else { throw SenderDocumentError.invalid }
            return .input(id)
        case "array":
            let item = try fields(raw, required: ["kind", "items"])
            guard let values = item["items"]?.arrayValues, values.count <= 128 else { throw SenderDocumentError.invalid }
            var constructors: [ResultConstructor] = []
            for (index, value) in values.enumerated() {
                constructors.append(try parseConstructor(value, path: "\(path).\(index)", depth: depth + 1))
            }
            return .array(constructors)
        case "object":
            let item = try fields(raw, required: ["kind", "members"])
            guard let values = item["members"]?.arrayValues, values.count <= 128 else { throw SenderDocumentError.invalid }
            var seen = Set<ExactText>()
            var members: [ResultMember] = []
            for (index, value) in values.enumerated() {
                let member = try fields(value, required: ["name", "value"])
                let name = try string(member["name"])
                guard seen.insert(name).inserted else { throw SenderDocumentError.invalid }
                members.append(ResultMember(name: name,
                                             value: try parseConstructor(member["value"], path: "\(path).\(index)", depth: depth + 1)))
            }
            return .object(members)
        default:
            throw SenderDocumentError.invalid
        }
    }

    private func fields(_ raw: JSONValue?, required: [String], optional: [String] = []) throws -> [String: JSONValue] {
        guard let raw, let members = raw.objectMembers, raw.hasUniqueObjectKeys else { throw SenderDocumentError.invalid }
        let requiredKeys = Set(required.map(ExactText.init))
        let allowedKeys = requiredKeys.union(optional.map(ExactText.init))
        let actualKeys = Set(members.map(\.key))
        guard requiredKeys.isSubset(of: actualKeys), actualKeys.isSubset(of: allowedKeys) else { throw SenderDocumentError.invalid }
        return Dictionary(uniqueKeysWithValues: members.map { ($0.key.rawValue, $0.value) })
    }

    private func string(_ raw: JSONValue?, nonempty: Bool = false) throws -> ExactText {
        guard let value = raw?.stringValue,
              !nonempty || !value.rawValue.isEmpty else { throw SenderDocumentError.invalid }
        return value
    }

    private func identifier(_ raw: JSONValue?) throws -> ExactText {
        let value = try string(raw, nonempty: true)
        guard value.rawValue.utf8.count <= 128 else { throw SenderDocumentError.invalid }
        return value
    }

    private func integer(_ raw: JSONValue?, range: ClosedRange<Int>) throws -> Int {
        guard let value = raw?.integerValue, range.contains(value) else { throw SenderDocumentError.invalid }
        return value
    }

    private func color(_ raw: JSONValue?) throws -> ExactText {
        let value = try string(raw, nonempty: true)
        let bytes = Array(value.rawValue.utf8)
        guard bytes.count == 7, bytes[0] == 0x23,
              bytes.dropFirst().allSatisfy({
                  (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0)
              }) else { throw SenderDocumentError.invalid }
        return value
    }

    private func stringArray(_ raw: JSONValue?, nonempty: Bool, maximumCount: Int) throws -> [ExactText] {
        guard let values = raw?.arrayValues,
              (!nonempty || !values.isEmpty), values.count <= maximumCount else { throw SenderDocumentError.invalid }
        return try values.map { try string($0, nonempty: true) }
    }

    private mutating func requireIllustration(_ id: ExactText) throws {
        guard illustrationIDs.contains(id) else { throw SenderDocumentError.invalid }
        referencedIllustrations.insert(id)
    }

    private func constructorInputReferences(in constructor: ResultConstructor) -> Set<ExactText> {
        switch constructor {
        case .literal:
            return []
        case let .input(id):
            return [id]
        case let .array(items):
            return items.reduce(into: Set<ExactText>()) { $0.formUnion(constructorInputReferences(in: $1)) }
        case let .object(members):
            return members.reduce(into: Set<ExactText>()) { $0.formUnion(constructorInputReferences(in: $1.value)) }
        }
    }

    private func capabilities() -> Set<ExactText> {
        var result: Set<ExactText> = [ExactText("scene/1"), ExactText("result/1")]
        if !illustrations.isEmpty { result.insert(ExactText("illustration/1")) }
        if inputs.contains(where: { if case .response = $0.kind { return true }; return false }) { result.insert(ExactText("response/1")) }
        if inputs.contains(where: { if case .text = $0.kind { return true }; return false }) { result.insert(ExactText("text/1")) }
        if inputs.contains(where: { if case .point = $0.kind { return true }; return false }) { result.insert(ExactText("point/1")) }
        if usesResultPoint { result.insert(ExactText("result-point/1")) }
        if illustrations.contains(where: { illustration in
            illustration.primitives.contains(where: { if case .image = $0 { return true }; return false })
        }) { result.insert(ExactText("image/1")) }
        return result
    }
}

private enum SenderDocumentError: Error {
    case invalid
}

public enum PointTransform {
    public static func select(pointerX: Double, pointerY: Double, bounds: CGRect, dragging: Bool) -> PointValue? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let inside = pointerX >= bounds.minX && pointerX <= bounds.maxX && pointerY >= bounds.minY && pointerY <= bounds.maxY
        guard dragging || inside else { return nil }
        let u = min(1, max(0, (pointerX - bounds.minX) / bounds.width))
        let v = min(1, max(0, (pointerY - bounds.minY) / bounds.height))
        return PointValue(x: quantize(u), y: quantize(v))
    }

    public static func quantize(_ normalized: Double) -> Int {
        guard normalized.isFinite else { return 0 }
        let clamped = min(1, max(0, normalized))
        return Int(floor(1000 * clamped + 0.5))
    }
}
