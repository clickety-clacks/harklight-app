import SwiftUI

/// Isolated app composition used only by the UI-test bundle. The product app
/// has no launch flag or alternate root for synthetic conversation state.
@main
@MainActor
struct HarklightConversationUITestHost: App {
    @State private var samples = SampleLibrary()
    @State private var conversationFixture: SampleFixtureDomain?
    @State private var prototypeFixture: PrototypeStore?

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
            ShakeHostingView(onShake: { samples.populate() }) {
                Group {
                    if let conversationFixture {
                        LiveContentView(store: conversationFixture.viewModel, samples: samples)
                    } else if let prototypeFixture {
                        if let presentation = prototypeFixture.presentationStore {
                            LiveContentView(store: presentation, samples: samples,
                                            fixtureStore: prototypeFixture)
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
                }
            }
            .ignoresSafeArea(.container)
        }
    }
}
