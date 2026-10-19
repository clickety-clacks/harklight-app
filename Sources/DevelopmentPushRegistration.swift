import Foundation
import UIKit
import UserNotifications
import AttentionDomain

// This receiver is scoped to the signed development build of the existing app.
// A simulator has no APNs address to hand off.
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
            try Self.addressStore().store(deviceToken)
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
        Task { @MainActor in
            let refreshed = await NativeRelayLifecycle.shared.refreshFromTrustedRelay()
            completionHandler(refreshed ? .newData : .noData)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        // Default opening is navigation only. Dismissal and unsupported actions
        // do not alter navigation, domain state, or notification presentation.
        let navigationPayload: JSONValue?
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let info = response.notification.request.content.userInfo
            var payload: JSONValue = .null
            let sequence = ((info["attention"] as? [String: Any])?["locator"] as? [String: Any])?["acceptance_seq"] as? NSNumber
            let integerSequence = sequence.map { !["d", "f"].contains(String(cString: $0.objCType)) && CFGetTypeID($0) != CFBooleanGetTypeID() } ?? true
            if integerSequence, let data = try? JSONSerialization.data(withJSONObject: info),
               let decoded = try? JSONValue.parse(data) { payload = decoded }
            navigationPayload = payload
        } else {
            navigationPayload = nil
        }
        Task { @MainActor in
            if let navigationPayload {
                NativeNotificationRouter.shared.receive(navigationPayload, opened: true)
            }
            // UIKit snapshots the app after this completion; finish on the main thread.
            completionHandler()
        }
    }

    private func clearAddressAndSetStatus(_ status: String) {
        do {
            try Self.addressStore().clear()
            UserDefaults.standard.set(status, forKey: Self.statusKey)
        } catch {
            NativeRelayLifecycle.shared.recordPushRegistrationFailure(error, area: .localStore)
            UserDefaults.standard.set("storage-failed", forKey: Self.statusKey)
        }
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

    func store(_ token: Data) throws {
        guard !token.isEmpty else {
            try clear()
            throw AddressError.emptyToken
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                .posixPermissions: 0o700
            ]
        )
        let address = token.map { String(format: "%02x", $0) }.joined()
        do {
            try Data(address.utf8).write(
                to: file,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            try? clear()
            throw error
        }
    }

    func load() throws -> String? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        guard let address = String(data: data, encoding: .utf8),
              address.count == 64,
              address.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            try clear()
            throw AddressError.invalidStoredToken
        }
        return address
    }
}
