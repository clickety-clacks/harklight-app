import Foundation
import UIKit
import UserNotifications

/// Existing permission is restored without asking again. Only the deliberate
/// contextual choice can request permission; every completion remains bound
/// to the installation that started it.
@MainActor
struct NativeNotificationPermission {
    let status: @MainActor () async -> UNAuthorizationStatus
    let request: @MainActor () async throws -> Bool
    let register: @MainActor () -> Void

    static var system: Self {
        Self(status: { await UNUserNotificationCenter.current().notificationSettings().authorizationStatus },
             request: { try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) },
             register: {
                 #if !targetEnvironment(simulator)
                 if Bundle.main.bundleIdentifier == "co.clicketyclacks.Harklight" {
                     UIApplication.shared.registerForRemoteNotifications()
                 }
                 #endif
             })
    }

    func resume(isCurrent: @MainActor () -> Bool) async {
        let permission = await status()
        guard isCurrent(), Self.allowed(permission) else { return }
        register()
    }

    func choose(_ enabled: Bool, isCurrent: @MainActor () -> Bool) async throws -> Bool {
        let permission = await status()
        guard isCurrent() else { return false }
        var allowed = Self.allowed(permission)
        if enabled && permission == .notDetermined { allowed = try await request() }
        guard isCurrent() else { return false }
        if allowed { register() }
        return allowed
    }

    private static func allowed(_ status: UNAuthorizationStatus) -> Bool {
        [.authorized, .provisional, .ephemeral].contains(status)
    }
}
