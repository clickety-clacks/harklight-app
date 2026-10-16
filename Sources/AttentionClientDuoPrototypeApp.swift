import SwiftUI
import UIKit

@main
@MainActor
struct AttentionClientDuoPrototypeApp: App {
    @UIApplicationDelegateAdaptor(DevelopmentPushRegistration.self) private var pushRegistration
    @Environment(\.scenePhase) private var scenePhase
    @State private var launch: NativeAppLaunch

    init() {
        _launch = State(initialValue: NativeAppLaunch())
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if launch.guidedJoin.isShowing {
                    NativeEnrollmentView(launch: launch)
                } else { switch launch.state {
                case .enrollmentRequired:
                    NativeEnrollmentView(launch: launch)
                case let .enrollmentPending(record):
                    NativeEnrollmentView(launch: launch, pending: record)
                case let .fixture(store):
                    ContentView(store: store)
                case let .live(store):
                    LiveContentView(store: store)
                } }
            }
            .task { await launch.restoreInstallation() }
            .onOpenURL { url in Task { await launch.guidedJoin.receive(url) } }
            .task(id: scenePhase) {
                launch.guidedJoin.invalidateApprovalObservation()
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await launch.refreshLive()
                    if launch.guidedJoin.isShowing &&
                        [.pending, .approvalExpired, .unreachable, .approvedFinishing].contains(launch.guidedJoin.screen) {
                        await launch.guidedJoin.retry()
                    }
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        }
    }
}
