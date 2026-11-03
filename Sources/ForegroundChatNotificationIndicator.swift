import SwiftUI

@MainActor
struct ForegroundChatNotificationIndicatorView: View {
    let indicator: NativeForegroundChatIndicator
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 3) {
                    Text(indicator.title.isEmpty ? "New chat reply" : indicator.title)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !indicator.body.isEmpty {
                        Text(indicator.body)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(2)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .padding(.top, 3)
            }
            .padding(12)
            .foregroundStyle(.primary)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .accessibilityLabel("Chat reply. \(indicator.title). \(indicator.body)")
        .accessibilityIdentifier("foreground-chat-notification")
    }
}

/// Places the one pending foreground chat indicator in the presentation that
/// is currently visible. A root inset alone is covered by a sheet on iPhone,
/// so every sheet root uses this same modifier as the app root.
@MainActor
struct ForegroundChatNotificationLayer: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(NativeAppLaunch.self) private var launch: NativeAppLaunch?

    var includeAppLaunch = true
    var testRouter: NativeNotificationRouter? = nil
    var testOpen: (() -> Void)? = nil

    func body(content: Content) -> some View {
        let router = testRouter ?? (includeAppLaunch ? launch?.notificationRouter : nil)
        content.safeAreaInset(edge: .top, spacing: 0) {
            if scenePhase == .active,
               let indicator = router?.foregroundChatIndicator {
                ForegroundChatNotificationIndicatorView(indicator: indicator) {
                    if let testOpen {
                        testOpen()
                    } else if includeAppLaunch, let launch {
                        Task { await launch.openForegroundChatIndicator(id: indicator.id) }
                    }
                }
            }
        }
    }
}

extension View {
    @MainActor
    func foregroundChatNotificationLayer(
        includeAppLaunch: Bool = true,
        testRouter: NativeNotificationRouter? = nil,
        testOpen: (() -> Void)? = nil
    ) -> some View {
        modifier(ForegroundChatNotificationLayer(includeAppLaunch: includeAppLaunch,
                                                 testRouter: testRouter, testOpen: testOpen))
    }
}
