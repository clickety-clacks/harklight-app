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
    @State private var showsRevokedText = false
    @State private var releaseNotes: ReleaseNotesPresentation

    private var diagnosticsFixtureLaunch: NativeAppLaunch? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--harklight-test-settings-diagnostics") {
            return launch
        }
        #endif
        return nil
    }

    init() {
        HarklightTypography.configureNavigationTitles()
        let arguments = ProcessInfo.processInfo.arguments
        let launch = NativeAppLaunch(arguments: arguments)
        _launch = State(initialValue: launch)
        let isReleaseNotesUITest = ProcessInfo.processInfo.environment["HARKLIGHT_RELEASE_NOTES_UI_TEST"] == "1"
        #if DEBUG
        let isReferenceOrFixtureRun = !isReleaseNotesUITest && (arguments.contains("--reset-attention-fixture") ||
            arguments.contains("--attention-fixture") || arguments.contains("--harklight-test-fyi-list") ||
            arguments.contains("--harklight-tier-reference"))
        #else
        let isReferenceOrFixtureRun = false
        #endif
        let defaults: UserDefaults
        if isReleaseNotesUITest,
           let uiTestDefaults = UserDefaults(suiteName: "HarklightReleaseNotesUITests") {
            uiTestDefaults.removePersistentDomain(forName: "HarklightReleaseNotesUITests")
            defaults = uiTestDefaults
        } else {
            defaults = .standard
        }
        let currentBuildIdentifier = isReferenceOrFixtureRun
            ? nil
            : HarklightReleaseNotes.currentBuildIdentifier()
        _releaseNotes = State(initialValue: ReleaseNotesPresentation(
            currentBuildIdentifier: currentBuildIdentifier,
            hasPriorAppState: isReleaseNotesUITest
                ? ProcessInfo.processInfo.environment["HARKLIGHT_RELEASE_NOTES_UI_TEST_FRESH_INSTALL"] != "1"
                : launch.hasPriorAppState,
            entries: HarklightReleaseNotes.numberedEntries(
                currentBuildIdentifier: currentBuildIdentifier),
            defaults: defaults))
    }

    /// The account Inbox drives the icon badge even while an archive is open;
    /// a whole-app local example badges its own inbox. No inbox means no badge.
    private var inboxBadgeCount: Int {
        if let store = launch.inboxPresentation {
            return InboxBadge.count(requests: store.inboxRows, samples: samples,
                                    showsLocalExamples: loadsSampleMessages && !store.isReadOnly)
        }
        if case let .fixture(fixture) = launch.state, let store = fixture.presentationStore {
            return InboxBadge.count(requests: store.inboxRows, samples: samples,
                                    showsLocalExamples: loadsSampleMessages && !store.isReadOnly)
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

    #if DEBUG
    private var messageKindAcceptanceColorScheme: ColorScheme? {
        guard ProcessInfo.processInfo.arguments.contains("--harklight-message-kind-acceptance") else { return nil }
        switch ProcessInfo.processInfo.environment["HARKLIGHT_MESSAGE_KIND_TEST_APPEARANCE"] {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
    #endif

    private var showsTierReference: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--harklight-tier-reference")
        #else
        return false
        #endif
    }

    private var loadsSampleMessages: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--harklight-samples")
        #else
        return false
        #endif
    }

    var body: some Scene {
        WindowGroup {
            @Bindable var releaseNotes = self.releaseNotes
            Group {
                if showsTierReference {
                    InboxTierReferenceScreen()
                } else if case .reenrolmentRequired = launch.state {
                    v2ReenrolmentView
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
                    case .reenrolmentRequired:
                        v2ReenrolmentView
                    case let .fixture(store):
                        if let presentation = store.presentationStore {
                            LiveContentView(store: presentation, samples: samples,
                                            launch: diagnosticsFixtureLaunch, fixtureStore: store)
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
            // Every screen sits on the design's page and takes its amber accent,
            // including loading, empty and recovery states that have no drawing.
            .background { Rectangle().fill(.hkBackground).ignoresSafeArea() }
            .modifier(HarklightAccentTint())
            .modifier(AcceptanceReduceMotionOverride(isEnabled: acceptanceReduceMotionOverride))
            #if DEBUG
            .preferredColorScheme(messageKindAcceptanceColorScheme)
            #endif
            .foregroundChatNotificationLayer()
            .task {
                if loadsSampleMessages { samples.populate() }
            }
            .task {
                await launch.restoreInstallation()
                await launch.handleNotification()
            }
            .task(id: inboxBadgeCount) {
                await NativeIconBadge.system.apply(inboxBadgeCount)
            }
            .onChange(of: launch.notificationRouter.pendingV2Tap) { _, payload in
                if payload != nil { Task { await launch.handleNotification() } }
            }
            .onOpenURL { url in Task { await launch.receiveInvitation(url) } }
            .task(id: scenePhase) {
                NativeRelayLifecycle.shared.v2FocusScenePhaseChanged(scenePhase)
                NativeRelayLifecycle.shared.sceneActivityChanged(isActive: scenePhase == .active)
                launch.guidedJoin.invalidateApprovalObservation()
                guard scenePhase == .active else { return }
                var isActivationRefresh = true
                while !Task.isCancelled {
                    if isActivationRefresh {
                        await launch.refreshForForegroundActivation()
                        isActivationRefresh = false
                    } else if NativeRelayLifecycle.shared.shouldPollV2PausedAccount {
                        await launch.refreshLive()
                    }
                    await launch.guidedJoin.retryAutomaticallyIfNeeded()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
            .sheet(isPresented: $releaseNotes.isShowingCurrentRelease) {
                if !releaseNotes.notesToShow.isEmpty {
                    ReleaseNotesSheet(notes: releaseNotes.notesToShow)
                        .foregroundChatNotificationLayer()
                        .harklightSheetSurface()
                }
            }
            .environment(launch)
        }
    }

    private var v2ReenrolmentView: some View {
        ContentUnavailableView {
            Label("This device was revoked", systemImage: "xmark.shield")
        } description: {
            Text(launch.enrollmentMessage ?? "Use a new server invitation to enrol this device again.")
        } actions: {
            if !launch.revokedRecoveryText.isEmpty {
                Button("View unsent text") { showsRevokedText = true }
            }
            Button("Enrol again") { launch.beginV2Reenrolment() }
        }
        .sheet(isPresented: $showsRevokedText) {
            NavigationStack {
                PreviousDeviceUnsentTextView { launch.revokedRecoveryText }
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
                    .tint(HarklightColor(token: .inverse))
            }
            if !launch.unconfirmedAccountDepartures.isEmpty {
                ForEach(launch.unconfirmedAccountDepartures, id: \.archiveID) { departure in
                    UnconfirmedAccountRemovalNotice(launch: launch, departure: departure)
                }
            } else if launch.disconnectedAccount?.removed != true {
                Button("Retry removal") { Task { await launch.retryDisconnectRemoval() } }
                    .buttonStyle(.borderedProminent)
                    .tint(HarklightColor(token: .inverse))
                    .disabled(launch.disconnectedAccount.map { launch.isDisconnectBusy(for: $0) } ?? false)
            }
        }
    }
}
