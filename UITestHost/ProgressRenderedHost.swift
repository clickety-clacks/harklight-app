import AttentionDomain
import SwiftUI

/// Generated local content in the isolated UI-test host, never the product app.
@MainActor
struct ProgressRenderedHost: View {
    @State private var store: LivePresentationStore
    @State private var samples = SampleLibrary()

    init() {
        do {
            let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:progress"),
                personID: ExactText("progress-person"), deviceID: ExactText("progress-device"))
            let context = ProfileContext(identity: identity, transportMode: .fixture)
            let domain = try ClientRepository(context: context, persistence: MemoryPendingActionPersistence())
            let defaults = UserDefaults(suiteName: "progress-ui-\(UUID().uuidString)")!
            let model = try LivePresentationStore(localFixtureStore: domain, context: context,
                                                   newMessageAreaDefaults: defaults)
            var messages: [StoredRequest] = []
            for index in 0..<7 {
                let date = "2026-11-09T10:0\(6-index):00Z"
                let percent = index == 1 ? 100 : 45
                let progress: [String: Any] = [
                    "updated_at": date, "percent": percent, "stage": "packaging",
                    "note": "Preparing the generated studio handoff.",
                    "segments": [
                        ["stage": "spec_writing", "width": 10, "note": "Scope agreed.",
                         "visit_at": "2026-11-09T09:00:00Z", "reported_percent": 10, "delta": 10],
                        ["stage": "coding", "width": percent - 15, "note": "The result is ready.",
                         "visit_at": "2026-11-09T09:30:00Z", "reported_percent": 60, "delta": 50],
                        ["stage": "review", "width": 0, "note": "Review started without more width."],
                        ["stage": "packaging", "width": 5, "note": "Corrected the estimate.",
                         "visit_at": date, "reported_percent": percent, "delta": -15]
                    ]
                ]
                let member = index == 6 ? NSNull() as Any : progress
                messages.append(try Self.message("progress-\(index)", title: index == 0
                    ? "Prepare the studio handoff" : "Generated progress work \(index + 1)",
                    progress: member, context: context))
                messages.append(try Self.message("ordinary-\(index)", title: "Generated New message \(index + 1)",
                                                 progress: nil, context: context))
            }
            try domain.registerFixtureRequests(messages, context: context)
            try model.refreshFromDurableStore()
            _store = State(initialValue: model)
        } catch { preconditionFailure("Progress fixture failed: \(error)") }
    }

    var body: some View {
        LiveContentView(store: store, samples: samples)
    }

    private static func message(_ id: String, title: String, progress: Any?,
                                context: ProfileContext) throws -> StoredRequest {
        var payload: [String: Any] = [
            "title": title, "body": "Generated local content for Progress acceptance.",
            "message_type": "fyi",
            "answer_ui": ["schema": "attention-client.actions/1", "actions": [
                ["id": "seen", "label": "Seen", "kind": "value", "value": ["acknowledgment": "seen"]]]]
        ]
        if let progress { payload["progress"] = progress }
        return StoredRequest(key: RequestKey(accountScope: context.identity.personID,
            senderID: ExactText("studio"), messageID: ExactText(id)),
            originalPayload: try JSONValue.parse(JSONSerialization.data(withJSONObject: payload)))
    }
}
