import SwiftUI
import AttentionDomain

/// Isolated app composition used only by the UI-test bundle. The product app
/// has no launch flag or alternate root for synthetic conversation state.
@main
@MainActor
struct HarklightConversationUITestHost: App {
    @State private var samples = SampleLibrary()
    @State private var conversationFixture: SampleFixtureDomain?
    @State private var prototypeFixture: PrototypeStore?
    @State private var testNotificationNavigation: NativeInboxNavigation? = nil
    @State private var testForegroundChatIndicator: NativeForegroundChatIndicator? = nil

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--attention-fixture") || arguments.contains("--reset-attention-fixture") {
            _prototypeFixture = State(initialValue: PrototypeStore.loadFromBundle())
            _conversationFixture = State(initialValue: nil)
        } else {
            do {
                let fixture = try SampleFixtureDomain()
                try fixture.populate()
                _conversationFixture = State(initialValue: fixture)
                _prototypeFixture = State(initialValue: nil)
            } catch {
                preconditionFailure("The isolated conversation test host could not load its local model: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let conversationFixture {
                    LiveContentView(store: conversationFixture.viewModel, samples: samples,
                                    testNotificationNavigation: testNotificationNavigation,
                                    testForegroundChatIndicator: testForegroundChatIndicator,
                                    testOpenForegroundChatIndicator: openTestChatIndicator,
                                    testNotificationChatRouteDidOpen: consumeTestChatRoute)
                } else if let prototypeFixture {
                    if let presentation = prototypeFixture.presentationStore {
                        LiveContentView(store: presentation, samples: samples,
                                        fixtureStore: prototypeFixture,
                                        testNotificationNavigation: testNotificationNavigation,
                                        testForegroundChatIndicator: testForegroundChatIndicator,
                                        testOpenForegroundChatIndicator: openTestChatIndicator,
                                        testNotificationChatRouteDidOpen: consumeTestChatRoute)
                    } else {
                        ContentUnavailableView(
                            prototypeFixture.loadError ?? "The local example could not be opened.",
                            systemImage: "exclamationmark.triangle")
                    }
                } else {
                    ContentUnavailableView("Local test model unavailable", systemImage: "questionmark.folder")
                }
            }
            .task {
                if ProcessInfo.processInfo.arguments.contains("--harklight-samples") { samples.populate() }
                prepareTestChatIndicatorIfRequested()
            }
        }
    }

    private func prepareTestChatIndicatorIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--harklight-test-foreground-chat-indicator"),
              let conversationFixture,
              let message = SampleCatalog.messages.first(where: { $0.id == "sample-information-0" }) else {
            return
        }
        let key = conversationFixture.key(for: message)
        guard conversationFixture.viewModel.conversation(for: key)?.latestAgentReply != nil else {
            preconditionFailure("The local chat fixture has no agent reply for the notification route.")
        }
        let locator: [String: Any] = [
            "v": 1,
            "binding_id": "11111111-2222-3333-4444-555555555555",
            "person_id": key.accountScope.rawValue,
            "device_id": "local-fixture-device",
            "sender_id": key.senderID.rawValue,
            "message_id": key.messageID.rawValue,
            "acceptance_seq": 1,
            "target": "chat"
        ]
        let object: [String: Any] = [
            "attention": ["v": 1, "type": "sync", "locator": locator]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let payload = try? JSONValue.parse(data) else {
            preconditionFailure("The local chat fixture notification could not be encoded.")
        }
        let router = NativeNotificationRouter.shared
        guard router.receiveForegroundNotification(
            payload, title: "Agent reply", body: "A new chat reply is ready."),
              let indicator = router.foregroundChatIndicator else {
            preconditionFailure("The local chat fixture notification was not recognized as a chat target.")
        }
        testForegroundChatIndicator = indicator
    }

    private func openTestChatIndicator() {
        guard let indicator = testForegroundChatIndicator else { return }
        _ = NativeNotificationRouter.shared.consumeForegroundChatIndicator(id: indicator.id)
        let serial = (testNotificationNavigation?.serial ?? 0) &+ 1
        testNotificationNavigation = NativeInboxNavigation(
            serial: serial, request: indicator.request, opensChat: true)
        testForegroundChatIndicator = nil
    }

    private func consumeTestChatRoute(_ serial: UInt64) {
        guard let route = testNotificationNavigation, route.serial == serial,
              route.opensChat, let request = route.request else { return }
        testNotificationNavigation = NativeInboxNavigation(serial: serial, request: request)
    }
}
