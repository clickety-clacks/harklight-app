import Observation
import SwiftUI
import UIKit

@main
@MainActor
struct HarklightApp: App {
    @UIApplicationDelegateAdaptor(DevelopmentPushRegistration.self) private var pushRegistration
    @Environment(\.scenePhase) private var scenePhase
    @State private var launch: NativeAppLaunch
    @State private var samples = SampleLibrary()
    @State private var releaseNotes: ReleaseNotesPresentation

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let launch = NativeAppLaunch(arguments: arguments)
        _launch = State(initialValue: launch)
        let isReleaseNotesUITest = ProcessInfo.processInfo.environment["HARKLIGHT_RELEASE_NOTES_UI_TEST"] == "1"
        let isReferenceOrFixtureRun = !isReleaseNotesUITest && (arguments.contains("--reset-attention-fixture") ||
            arguments.contains("--attention-fixture") ||
            arguments.contains("--harklight-tier-reference"))
        let defaults: UserDefaults
        if isReleaseNotesUITest,
           let uiTestDefaults = UserDefaults(suiteName: "HarklightReleaseNotesUITests") {
            uiTestDefaults.removePersistentDomain(forName: "HarklightReleaseNotesUITests")
            defaults = uiTestDefaults
        } else {
            defaults = .standard
        }
        _releaseNotes = State(initialValue: ReleaseNotesPresentation(
            currentBuildIdentifier: isReferenceOrFixtureRun
                ? nil
                : HarklightReleaseNotes.currentBuildIdentifier(),
            hasPriorAppState: isReleaseNotesUITest ? true : launch.hasPriorAppState,
            defaults: defaults))
    }

    /// The account Inbox drives the icon badge even while an archive is open;
    /// a whole-app local example badges its own inbox. No inbox means no badge.
    private var inboxBadgeCount: Int {
        if let store = launch.inboxPresentation {
            return InboxBadge.count(requests: store.inboxRows, samples: samples,
                                    showsLocalExamples: !store.isReadOnly)
        }
        if case let .fixture(fixture) = launch.state, let store = fixture.presentationStore {
            return InboxBadge.count(requests: store.inboxRows, samples: samples,
                                    showsLocalExamples: !store.isReadOnly)
        }
        return 0
    }

    /// UI acceptance screenshots can exercise both values consumed by SwiftUI
    /// without changing the simulator's system accessibility setting.
    private var acceptanceReduceMotionOverride: Bool? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--harklight-test-reduce-motion-on") { return true }
        if arguments.contains("--harklight-test-reduce-motion-off") { return false }
        #endif
        return nil
    }

    var body: some Scene {
        WindowGroup {
            @Bindable var releaseNotes = self.releaseNotes
            Group {
                if ProcessInfo.processInfo.arguments.contains("--harklight-tier-reference") {
                    InboxTierReferenceScreen()
                } else if let archive = launch.selectedArchivedPresentation,
                   let departure = launch.selectedArchivedAccount {
                    LiveContentView(store: archive, samples: samples, launch: launch,
                                    archiveDeparture: departure)
                } else if launch.guidedJoin.isShowing {
                    NativeEnrollmentView(launch: launch)
                } else if launch.canOpenDisconnectedArchive && launch.isShowingDisconnectedArchive,
                          let archive = launch.disconnectedArchive {
                    LiveContentView(store: archive, samples: samples, launch: launch,
                                    archiveDeparture: launch.disconnectedAccount)
                } else if let store = launch.inboxPresentation {
                    LiveContentView(store: store, samples: samples, launch: launch,
                                    archiveDeparture: launch.displayedArchiveDeparture)
                } else {
                    switch launch.state {
                    case .enrollmentRequired:
                        NativeEnrollmentView(launch: launch)
                    case let .enrollmentPending(record):
                        NativeEnrollmentView(launch: launch, pending: record)
                    case let .fixture(store):
                        if let presentation = store.presentationStore {
                            LiveContentView(store: presentation, samples: samples,
                                            fixtureStore: store)
                        } else {
                            ContentUnavailableView(
                                store.loadError ?? "The local example could not be opened.",
                                systemImage: "exclamationmark.triangle")
                        }
                    case .live, .disconnected:
                        DisconnectedAccountRecoveryView(launch: launch)
                    }
                }
            }
            .modifier(AcceptanceReduceMotionOverride(isEnabled: acceptanceReduceMotionOverride))
            .task {
                if ProcessInfo.processInfo.arguments.contains("--harklight-samples") { samples.populate() }
            }
            .task {
                await launch.restoreInstallation()
                await launch.handleNotification()
            }
            .task(id: inboxBadgeCount) {
                await NativeIconBadge.system.apply(inboxBadgeCount)
            }
            .onChange(of: launch.notificationRouter.intent?.serial) { _, _ in
                Task { await launch.handleNotification() }
            }
            .onOpenURL { url in Task { await launch.receiveInvitation(url) } }
            .task(id: scenePhase) {
                launch.guidedJoin.invalidateApprovalObservation()
                guard scenePhase == .active else { return }
                var isActivationRefresh = true
                while !Task.isCancelled {
                    if isActivationRefresh {
                        await launch.refreshForForegroundActivation()
                        isActivationRefresh = false
                    } else {
                        await launch.refreshLive()
                    }
                    await launch.guidedJoin.retryAutomaticallyIfNeeded(
                        foregroundOutcome: launch.foregroundConnectProgress?.outcome)
                    try? await Task.sleep(for: .seconds(15))
                }
            }
            .sheet(isPresented: $releaseNotes.isShowingCurrentRelease) {
                if !releaseNotes.notesToShow.isEmpty {
                    ReleaseNotesSheet(notes: releaseNotes.notesToShow)
                }
            }
        }
    }
}

private struct AcceptanceReduceMotionOverride: ViewModifier {
    let isEnabled: Bool?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let isEnabled {
            content.environment(\.harklightReduceMotionOverride, isEnabled)
        } else {
            content
        }
    }
}

extension EnvironmentValues {
    @Entry var harklightReduceMotionOverride: Bool? = nil
}

@MainActor
private struct DisconnectedAccountRecoveryView: View {
    let launch: NativeAppLaunch

    var body: some View {
        ContentUnavailableView {
            Label("Saved messages are unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(launch.disconnectMessage ?? "The disconnected account’s local messages could not be opened. The original account identity is retained.")
        } actions: {
            if launch.disconnectedAccount?.removed == true {
                Button("Connect with an invitation") { launch.beginReconnect() }
                    .buttonStyle(.borderedProminent)
            }
            if !launch.unconfirmedAccountDepartures.isEmpty {
                ForEach(launch.unconfirmedAccountDepartures, id: \.archiveID) { departure in
                    UnconfirmedAccountRemovalNotice(launch: launch, departure: departure)
                }
            } else if launch.disconnectedAccount?.removed != true {
                Button("Retry removal") { Task { await launch.retryDisconnectRemoval() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(launch.disconnectedAccount.map { launch.isDisconnectBusy(for: $0) } ?? false)
            }
        }
    }
}
