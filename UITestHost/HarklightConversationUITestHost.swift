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
    @State private var didPrepareNotificationFixture = false
    @State private var didInjectReplyWhileChatWasOpen = false

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--harklight-test-inbox-list-column") || arguments.contains("--free-rendered") {
            _prototypeFixture = State(initialValue: nil)
            _conversationFixture = State(initialValue: nil)
        } else if arguments.contains("--attention-fixture") || arguments.contains("--reset-attention-fixture") {
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
                if ProcessInfo.processInfo.arguments.contains("--free-rendered") {
                    FreeRenderedHost()
                } else if ProcessInfo.processInfo.arguments.contains("--harklight-test-inbox-list-column") {
                    InboxListColumnCaptureHost()
                } else if let conversationFixture {
                    LiveContentView(store: conversationFixture.viewModel, samples: samples,
                                    testNotificationNavigation: testNotificationNavigation,
                                    testNotificationRouter: .shared,
                                    testOpenForegroundChatIndicator: openTestChatIndicator,
                                    testConversationSheetDidAppear: testChatSheetDidAppear,
                                    testNotificationChatRouteDidOpen: consumeTestChatRoute)
                } else if let prototypeFixture {
                    if let presentation = prototypeFixture.presentationStore {
                        LiveContentView(store: presentation, samples: samples,
                                        fixtureStore: prototypeFixture,
                                        testNotificationNavigation: testNotificationNavigation,
                                        testNotificationRouter: .shared,
                                        testOpenForegroundChatIndicator: openTestChatIndicator,
                                        testConversationSheetDidAppear: testChatSheetDidAppear,
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
            .preferredColorScheme(testColorScheme)
            .foregroundChatNotificationLayer(includeAppLaunch: false,
                                             testRouter: .shared,
                                             testOpen: openTestChatIndicator)
            .task {
                if ProcessInfo.processInfo.arguments.contains("--harklight-samples") { samples.populate() }
                prepareTestChatIndicatorIfRequested()
            }
        }
    }

    private var testColorScheme: ColorScheme? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--harklight-test-inbox-list-dark") { return .dark }
        if arguments.contains("--harklight-test-inbox-list-light") { return .light }
        if arguments.contains("--harklight-test-chat-status-dark") { return .dark }
        if arguments.contains("--harklight-test-chat-status-light") { return .light }
        return nil
    }

    private func prepareTestChatIndicatorIfRequested() {
        guard !didPrepareNotificationFixture else { return }
        didPrepareNotificationFixture = true

        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--harklight-test-foreground-chat-indicator-over-chat") {
            guard let conversationFixture,
                  let message = SampleCatalog.messages.first(where: { $0.id == "sample-information-2" }) else {
                preconditionFailure("The local fixture has no other chat to keep open while a reply arrives.")
            }
            testNotificationNavigation = NativeInboxNavigation(
                serial: 1, request: conversationFixture.key(for: message), opensChat: true)
            return
        }

        guard arguments.contains("--harklight-test-foreground-chat-indicator") else { return }
        receiveTestChatReply(for: "sample-information-0")
    }

    private func receiveTestChatReply(for messageID: String) {
        guard let conversationFixture,
              let message = SampleCatalog.messages.first(where: { $0.id == messageID }) else {
            preconditionFailure("The local chat notification fixture could not be found.")
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
        guard router.receiveForegroundNotification(payload, title: "Agent reply",
                                                   body: "A new chat reply is ready."),
              router.foregroundChatIndicator != nil else {
            preconditionFailure("The local chat fixture notification was not recognized as a chat target.")
        }
    }

    private func openTestChatIndicator() {
        guard let indicator = NativeNotificationRouter.shared.foregroundChatIndicator,
              let consumed = NativeNotificationRouter.shared.consumeForegroundChatIndicator(id: indicator.id) else {
            return
        }
        let serial = (testNotificationNavigation?.serial ?? 0) &+ 1
        testNotificationNavigation = NativeInboxNavigation(
            serial: serial, request: consumed.request, opensChat: true)
    }

    private func testChatSheetDidAppear() {
        guard ProcessInfo.processInfo.arguments.contains(
                "--harklight-test-foreground-chat-indicator-over-chat"),
              !didInjectReplyWhileChatWasOpen else { return }
        didInjectReplyWhileChatWasOpen = true
        receiveTestChatReply(for: "sample-information-0")
    }

    private func consumeTestChatRoute(_ serial: UInt64) {
        guard let route = testNotificationNavigation, route.serial == serial,
              route.opensChat, let request = route.request else { return }
        testNotificationNavigation = NativeInboxNavigation(serial: serial, request: request)
    }
}
