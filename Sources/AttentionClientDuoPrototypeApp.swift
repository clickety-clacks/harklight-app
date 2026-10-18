import SwiftUI
import UIKit

@main
@MainActor
struct AttentionClientDuoPrototypeApp: App {
    @UIApplicationDelegateAdaptor(DevelopmentPushRegistration.self) private var pushRegistration
    @Environment(\.scenePhase) private var scenePhase
    @State private var launch: NativeAppLaunch
    @State private var samples = SampleLibrary()

    init() {
        _launch = State(initialValue: NativeAppLaunch())
    }

    var body: some Scene {
        WindowGroup {
            ShakeHostingView(onShake: { samples.populate() }) {
                Group {
                    if let archive = launch.selectedArchivedPresentation,
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
                .task {
                    if ProcessInfo.processInfo.arguments.contains("--harklight-samples") { samples.populate() }
                }
            }
            // Fill the container; the hosted SwiftUI bars/content still respect
            // their own system safe areas, including the software keyboard.
            .ignoresSafeArea(.container)
            .task { await launch.restoreInstallation() }
            .onOpenURL { url in Task { await launch.receiveInvitation(url) } }
            .task(id: scenePhase) {
                launch.guidedJoin.invalidateApprovalObservation()
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await launch.refreshLive()
                    await launch.guidedJoin.retryAutomaticallyIfNeeded(
                        foregroundOutcome: launch.foregroundConnectProgress?.outcome)
                    try? await Task.sleep(for: .seconds(15))
                }
            }
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
            } else {
                Button("Retry removal") { Task { await launch.retryDisconnectRemoval() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(launch.isDisconnectBusy)
            }
        }
    }
}
