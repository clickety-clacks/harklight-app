import Foundation
import UIKit
import UserNotifications
import AttentionDomain

// The same receiver handles development and distribution builds; the signed app
// target selects the APNs environment. A simulator has no APNs address to hand off.
@MainActor
final class DevelopmentPushRegistration: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let expectedBundleID = "co.clicketyclacks.Harklight"
    private static let statusKey = "harklight.apns.registration.status"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        guard Bundle.main.bundleIdentifier == Self.expectedBundleID else {
            NativeRelayLifecycle.shared.recordPushRegistrationFailure(
                causeCode: "notification_bundle_mismatch")
            clearAddressAndSetStatus("refused")
            return
        }

        do {
            try Self.persistToken(deviceToken,
                                  legacyStore: Self.addressStore(), enrollment: NativeEnrollmentStore())
            UserDefaults.standard.set("registered", forKey: Self.statusKey)
            Task { await NativeRelayLifecycle.shared.refreshAfterPushAddressStored() }
        } catch DevelopmentAPNsAddressStore.AddressError.emptyToken {
            NativeRelayLifecycle.shared.recordPushRegistrationFailure(
                causeCode: "notification_empty_token")
            UserDefaults.standard.set("refused", forKey: Self.statusKey)
        } catch {
            NativeRelayLifecycle.shared.recordPushRegistrationFailure(error)
            UserDefaults.standard.set("storage-failed", forKey: Self.statusKey)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NativeRelayLifecycle.shared.recordPushRegistrationFailure(error)
        clearAddressAndSetStatus("registration-failed")
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let payload = Self.notificationNavigationPayload(
            actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: userInfo)
        Task { @MainActor in
            let refreshed = await NativeRelayLifecycle.shared.refreshForRemotePush(payload)
            completionHandler(refreshed ? .newData : .noData)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let actionIdentifier = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let navigationPayload = Self.notificationNavigationPayload(
            actionIdentifier: actionIdentifier, userInfo: userInfo)
        Task { @MainActor in
            NativeNotificationRouter.shared.pendingV2Tap = navigationPayload
            // UIKit snapshots the app after this completion; finish on the main thread.
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        let content = notification.request.content
        let payload = Self.notificationNavigationPayload(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: content.userInfo)
        guard let payload else { completionHandler([]); return }
        let title = content.title
        let body = content.body

        Task { @MainActor in
            completionHandler([])
            if let locator = await NativeRelayLifecycle.shared.v2LocatorForPush(payload) {
                NativeNotificationRouter.shared.receiveForegroundNotification(payload, locator: locator,
                                                                            title: title, body: body)
            }
        }
    }

    /// Keep the system response handoff testable without constructing a
    /// device-owned UNNotificationResponse.
    nonisolated static func notificationNavigationPayload(actionIdentifier: String,
                                                          userInfo: [AnyHashable: Any]) -> JSONValue? {
        // Default opening is navigation only. Dismissal and unsupported actions
        // do not alter navigation, domain state, or notification presentation.
        guard actionIdentifier == UNNotificationDefaultActionIdentifier else { return nil }

        guard let data = try? JSONSerialization.data(withJSONObject: userInfo),
              let payload = try? JSONValue.parse(data) else { return .null }
        return payload
    }

    private func clearAddressAndSetStatus(_ status: String) {
        do {
            try Self.addressStore().clear()
            try NativeEnrollmentStore().clearV2APNsToken()
            UserDefaults.standard.set(status, forKey: Self.statusKey)
        } catch {
            NativeRelayLifecycle.shared.recordPushRegistrationFailure(error, area: .localStore)
            UserDefaults.standard.set("storage-failed", forKey: Self.statusKey)
        }
    }

    static func persistToken(_ token: Data, legacyStore: DevelopmentAPNsAddressStore,
                             enrollment: NativeEnrollmentStore) throws {
        // Remove the previous release's address file. Current bytes come from APNs.
        try legacyStore.clear()
        try enrollment.storeV2APNsToken(token)
    }

    static func addressStore() throws -> DevelopmentAPNsAddressStore {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return DevelopmentAPNsAddressStore(
            directory: support.appendingPathComponent("APNsSandbox", isDirectory: true)
        )
    }
}

struct DevelopmentAPNsAddressStore {
    enum AddressError: Error {
        case emptyToken
        case invalidStoredToken
    }

    let directory: URL

    private var file: URL {
        directory.appendingPathComponent("device-token.hex")
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

}
