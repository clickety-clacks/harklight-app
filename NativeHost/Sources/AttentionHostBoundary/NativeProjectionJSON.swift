import AttentionDomain
import Foundation

/// Serializes only C-admitted visual material. It cannot access a sender
/// result constructor, an authorized answer, or the relay event stream.
enum NativeProjectionJSON {
    static func encode(_ projection: AdmittedRequestProjection) -> JSONValue {
        switch projection {
        case let .sender(sender):
            return .object([
                JSONMember("kind", string("sender")),
                JSONMember("scene", scene(sender.scene)),
                JSONMember("inputs", .array(sender.inputs.map(input))),
                JSONMember("illustrations", .array(sender.illustrations.map(illustration))),
                JSONMember("submissionLabel", .string(sender.submissionLabel))
            ])
        case let .compatibility(actions):
            return .object([
                JSONMember("kind", string("compatibility")),
                JSONMember("actions", .array(actions.map(action)))
            ])
        case let .unsupported(reason):
            let label = reason == .missing ? "missing" : "unfamiliar"
            return .object([
                JSONMember("kind", string("unsupported")),
                JSONMember("reason", string(label))
            ])
        }
    }

    private static func scene(_ node: ProjectedSceneNode) -> JSONValue {
        var fields = [JSONMember("nodeID", string(node.id))]
        switch node.kind {
        case let .stack(axis, children):
            fields += [JSONMember("kind", string("stack")),
                       JSONMember("axis", string(axis == .vertical ? "vertical" : "horizontal")),
                       JSONMember("children", .array(children.map(scene)))]
        case let .grid(columns, children):
            fields += [JSONMember("kind", string("grid")),
                       JSONMember("columns", number(columns)),
                       JSONMember("children", .array(children.map(scene)))]
        case let .text(value, style):
            fields += [JSONMember("kind", string("text")),
                       JSONMember("text", .string(value)),
                       JSONMember("style", string(style.rawValue))]
        case let .illustration(id):
            fields += [JSONMember("kind", string("illustration")),
                       JSONMember("id", .string(id))]
        case let .input(id, layout):
            fields += [JSONMember("kind", string("input")),
                       JSONMember("id", .string(id)),
                       JSONMember("layout", string(layout.rawValue))]
        case let .resultPoint(id, label, point):
            fields += [JSONMember("kind", string("result-point")),
                       JSONMember("id", .string(id)),
                       JSONMember("label", .string(label)),
                       JSONMember("point", pointJSON(point))]
        }
        return .object(fields)
    }

    private static func input(_ input: ProjectedInput) -> JSONValue {
        var fields = [JSONMember("id", .string(input.id)),
                      JSONMember("label", .string(input.label))]
        switch input.kind {
        case let .response(actions):
            fields += [JSONMember("kind", string("response")),
                       JSONMember("actions", .array(actions.map(action)))]
        case .text:
            fields.append(JSONMember("kind", string("text")))
        case let .point(id):
            fields += [JSONMember("kind", string("point")),
                       JSONMember("illustration", .string(id))]
        }
        return .object(fields)
    }

    private static func action(_ action: ProjectedAction) -> JSONValue {
        var fields = [JSONMember("id", .string(action.id)),
                      JSONMember("label", .string(action.label)),
                      JSONMember("kind", string(action.kind == .value ? "value" : "text"))]
        if let id = action.illustrationID {
            fields.append(JSONMember("illustration", .string(id)))
        }
        return .object(fields)
    }

    private static func illustration(_ resource: SenderIllustration) -> JSONValue {
        .object([
            JSONMember("id", .string(resource.id)),
            JSONMember("label", .string(resource.label)),
            JSONMember("width", number(resource.width)),
            JSONMember("height", number(resource.height)),
            JSONMember("primitives", .array(resource.primitives.map(primitive)))
        ])
    }

    private static func primitive(_ primitive: GraphicPrimitive) -> JSONValue {
        switch primitive {
        case let .rect(x, y, width, height, fill):
            return .object([JSONMember("kind", string("rect")),
                            JSONMember("x", number(x)), JSONMember("y", number(y)),
                            JSONMember("width", number(width)), JSONMember("height", number(height)),
                            JSONMember("fill", .string(fill))])
        case let .circle(cx, cy, radius, fill):
            return .object([JSONMember("kind", string("circle")),
                            JSONMember("cx", number(cx)), JSONMember("cy", number(cy)),
                            JSONMember("r", number(radius)), JSONMember("fill", .string(fill))])
        case let .line(x1, y1, x2, y2, stroke, strokeWidth):
            return .object([JSONMember("kind", string("line")),
                            JSONMember("x1", number(x1)), JSONMember("y1", number(y1)),
                            JSONMember("x2", number(x2)), JSONMember("y2", number(y2)),
                            JSONMember("stroke", .string(stroke)),
                            JSONMember("strokeWidth", number(strokeWidth))])
        case let .text(x, y, text, fill, fontSize, align):
            return .object([JSONMember("kind", string("text")),
                            JSONMember("x", number(x)), JSONMember("y", number(y)),
                            JSONMember("text", .string(text)), JSONMember("fill", .string(fill)),
                            JSONMember("fontSize", number(fontSize)),
                            JSONMember("align", string(align.rawValue))])
        case let .image(x, y, width, height, file):
            return .object([JSONMember("kind", string("image")),
                            JSONMember("x", number(x)), JSONMember("y", number(y)),
                            JSONMember("width", number(width)), JSONMember("height", number(height)),
                            JSONMember("file", .string(file))])
        }
    }

    private static func pointJSON(_ point: PointValue) -> JSONValue {
        .object([JSONMember("x", number(point.x)), JSONMember("y", number(point.y))])
    }

    private static func string(_ value: String) -> JSONValue { .string(ExactText(value)) }
    private static func number(_ value: Int) -> JSONValue {
        .number(JSONNumber(lexeme: String(value)))
    }
}
