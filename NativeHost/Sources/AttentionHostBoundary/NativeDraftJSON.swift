import AttentionDomain
import Foundation

/// A view of C's draft, never a second persisted draft store.
enum NativeDraftJSON {
    static func encode(_ draft: RequestDraft) -> JSONValue {
        let inputs = draft.inputs.map { id, value in
            JSONValue.object([
                JSONMember("id", .string(id)),
                JSONMember("selectedAction", optional(value.selectedActionID)),
                JSONMember("textByAction", .array(value.textByActionID.map { action, text in
                    .object([JSONMember("action", .string(action)),
                             JSONMember("text", .string(text))])
                })),
                JSONMember("text", optional(value.text)),
                JSONMember("point", value.point.map { point in
                    .object([JSONMember("x", number(point.x)),
                             JSONMember("y", number(point.y))])
                } ?? .null),
                JSONMember("horizontalText", optional(value.horizontalText)),
                JSONMember("verticalText", optional(value.verticalText))
            ])
        }
        return .object([
            JSONMember("inputs", .array(inputs)),
            JSONMember("compatibility", .object([
                JSONMember("selectedAction", optional(draft.compatibility.selectedActionID)),
                JSONMember("textByAction", .array(draft.compatibility.textByActionID.map { action, text in
                    .object([JSONMember("action", .string(action)),
                             JSONMember("text", .string(text))])
                }))
            ]))
        ])
    }

    private static func optional(_ text: ExactText?) -> JSONValue {
        text.map(JSONValue.string) ?? .null
    }

    private static func number(_ value: Int) -> JSONValue {
        .number(JSONNumber(lexeme: String(value)))
    }
}
