import AttentionDomain
import Foundation
import Observation
import HarklightNativeRelay

extension NativeEnrollmentRecord {
    func matchesNotificationIdentity(_ identity: ProfileIdentity) -> Bool {
        isApproved && ExactText(profileAuthority) == identity.trustedRelayAuthority &&
            personID.map { ExactText($0) } == identity.personID && ExactText(deviceID) == identity.deviceID
    }

    func sameNotificationProfile(as other: Self) -> Bool {
        isApproved && other.isApproved && ExactText(profileAuthority) == ExactText(other.profileAuthority) &&
            NativeAuthorityBinding.samePerson(personID, other.personID) && ExactText(deviceID) == ExactText(other.deviceID) &&
            trustedRootDER == other.trustedRootDER && identityLabel == other.identityLabel &&
            notificationProfileGeneration == other.notificationProfileGeneration
    }
}

/// A push may wake Sync only for the installed account. Its position is
/// a freshness hint; the connection reads changes from its saved cursor.
struct NativeNotificationLocator: Codable, Equatable {
    let serverID: String?
    let bindingID: ExactText
    let deviceID: ExactText
    let request: RequestKey
    let target: String?

    init(v2Request: RequestKey, bindingID: ExactText, deviceID: ExactText, serverID: String, target: String?) {
        self.serverID = serverID
        self.bindingID = bindingID
        self.deviceID = deviceID
        request = v2Request
        self.target = target
    }

}

enum NativePushDestination {
    case inbox
    case item(NativeNotificationLocator)

    var locator: NativeNotificationLocator? {
        guard case let .item(locator) = self else { return nil }
        return locator
    }
}

struct NativeNotificationIntent: Codable, Equatable {
    let serial: UInt64
    var locator: NativeNotificationLocator?
}

struct NativeInboxNavigation: Equatable {
    let serial: UInt64
    let request: RequestKey?
    var opensChat = false
    var chatTargetFallsBackToMessage = false
    var isPushed = false
    var showsMessageOnly = false
    var opensInbox = false

    var isPending: Bool { request == nil && !opensInbox }

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Consuming the one-shot chat presentation must not replay workspace
        // selection or its existing Seen/unread-related presentation effects.
        lhs.serial == rhs.serial && lhs.request == rhs.request &&
            lhs.chatTargetFallsBackToMessage == rhs.chatTargetFallsBackToMessage &&
            lhs.isPushed == rhs.isPushed && lhs.showsMessageOnly == rhs.showsMessageOnly &&
            lhs.opensInbox == rhs.opensInbox
    }
}

struct NativeForegroundChatIndicator: Identifiable {
    let id: UUID
    let request: RequestKey
    let title: String
    let body: String
    let payload: JSONValue
}

struct NativeMessageDeepLink: Equatable {
    let senderID: String
    let messageID: String
    var opensChat = false
    var isPushed = false

    static func recognizes(_ url: URL) -> Bool {
        guard let scheme = url.scheme, let host = url.host else { return false }
        return scheme.caseInsensitiveCompare("harklight") == .orderedSame &&
            host.caseInsensitiveCompare("message") == .orderedSame
    }

    init?(url: URL) {
        guard Self.recognizes(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath.first == "/" else { return nil }

        let segments = components.percentEncodedPath.dropFirst()
            .split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 2,
              let senderID = String(segments[0]).removingPercentEncoding, !senderID.isEmpty,
              let messageID = String(segments[1]).removingPercentEncoding, !messageID.isEmpty else {
            return nil
        }
        self.senderID = senderID
        self.messageID = messageID
        opensChat = false
    }

    init(senderID: String, messageID: String,
         opensChat: Bool, isPushed: Bool = false) {
        self.senderID = senderID
        self.messageID = messageID
        self.opensChat = opensChat
        self.isPushed = isPushed
    }
}

/// Only a notification tap delivered in this process creates navigation intent.
/// An unfinished tap from a previous launch must not reopen detail on app launch.
@MainActor
@Observable
final class NativeNotificationRouter {
    static let shared = NativeNotificationRouter()
    private(set) var intent: NativeNotificationIntent?
    private(set) var foregroundChatIndicator: NativeForegroundChatIndicator?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "harklight.notification.navigation"
    @ObservationIgnored private var visibleConversationKey: RequestKey?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Discard navigation saved by earlier versions. The system delivers a
        // current launch tap through didReceive; it does not need disk replay.
        defaults.removeObject(forKey: key)
    }

    var pendingV2Tap: JSONValue?

    func receive(locator: NativeNotificationLocator?) {
        NativePushedViewCoordinator.shared.recordOwnOpen()
        let serial = UInt64(defaults.string(forKey: key + ".serial") ?? "0") ?? 0
        intent = NativeNotificationIntent(serial: serial &+ 1, locator: locator)
        foregroundChatIndicator = nil
        defaults.set(String(serial &+ 1), forKey: key + ".serial")
    }

    /// A chat alert delivered while the app is active is kept only as
    /// presentation state until the person taps it. The navigation intent is
    /// created through the current tap path, never from foreground receipt.
    @discardableResult
    func receiveForegroundNotification(_ payload: JSONValue, locator: NativeNotificationLocator,
                                       title: String, body: String) -> Bool {
        guard locator.target == "chat" else { return false }
        guard visibleConversationKey != locator.request else {
            foregroundChatIndicator = nil
            return true
        }
        foregroundChatIndicator = NativeForegroundChatIndicator(
            id: UUID(), request: locator.request, title: title, body: body, payload: payload)
        return true
    }

    func consumeForegroundChatIndicator(id: UUID) -> NativeForegroundChatIndicator? {
        guard let indicator = foregroundChatIndicator, indicator.id == id else { return nil }
        foregroundChatIndicator = nil
        return indicator
    }

    func conversationBecameVisible(_ key: RequestKey) {
        visibleConversationKey = key
        if foregroundChatIndicator?.request == key { foregroundChatIndicator = nil }
    }

    func conversationBecameHidden(_ key: RequestKey) {
        if visibleConversationKey == key { visibleConversationKey = nil }
    }

    func consumed() {
        intent = nil
        defaults.removeObject(forKey: key)
    }

}
