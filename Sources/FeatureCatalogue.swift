import AttentionDomain
import Foundation

/// The allowlist is intentionally independent of arbitrary names sent by a server.
enum AppFeature: String, CaseIterable, Identifiable, Sendable {
    case progressMessages
    case accountAwareNotifications
    case priorityLevels

    var id: Self { self }

    var flag: RemoteFeatureFlag {
        switch self {
        case .progressMessages: .progressInbox
        case .accountAwareNotifications: .serverMatchedPushRouting
        case .priorityLevels: .priorityLevelEditing
        }
    }

    var title: String {
        switch self {
        case .progressMessages: "Progress messages"
        case .accountAwareNotifications: "Account-aware notifications"
        case .priorityLevels: "Priority-level editing"
        }
    }

    var description: String {
        switch self {
        case .progressMessages:
            "Follow ongoing work in a dedicated Inbox section, with its percentage, stage and update history."
        case .accountAwareNotifications:
            "Match notification taps to the right account and server, and remove this device’s notification registration when leaving an account."
        case .priorityLevels:
            "Read priority levels, edit a local draft of their names and ranges, then save the complete table to your server."
        }
    }

    var maturity: FeatureMaturity {
        self == .progressMessages ? .beta : .alpha
    }

    var limitation: String {
        switch self {
        case .progressMessages:
            "The list and detail presentation have been tested in a limited scope. Wider confirmation with representative server updates is still pending."
        case .accountAwareNotifications:
            "Real notification delivery, tap routing and leaving-account behavior still need acceptance testing together."
        case .priorityLevels:
            "Reading and saving with a real server and an authorised account still need confirmation."
        }
    }

    var requirements: String {
        switch self {
        case .progressMessages:
            "An approved account and a server that sends Progress messages. Saved messages can be read offline."
        case .accountAwareNotifications:
            "An approved account, notification permission, a valid notification registration and a supporting server. Turning the feature on does not grant any of these."
        case .priorityLevels:
            "A writable account connected to a supporting server that permits reading and saving priority levels. Local examples and saved read-only accounts cannot save."
        }
    }
}

enum FeatureMaturity: String, Sendable {
    case alpha = "Alpha"
    case beta = "Beta"

    var explanation: String {
        switch self {
        case .alpha: "Experimental: it may or may not work. Read the specific limits for this feature."
        case .beta: "The workflow has been tested in a limited scope; wider confirmation is still pending."
        }
    }
}

struct FeatureFlagEvaluation: Equatable, Sendable {
    enum Source: Equatable, Sendable { case appDefault, server }
    enum Freshness: Equatable, Sendable { case appDefaultsOnly, awaitingSnapshot, latestSnapshot }
    enum FallbackReason: Equatable, Sendable { case noSnapshot, missingValue, malformedValue, malformedObject }

    let isEnabled: Bool
    let builtInDefault: Bool
    let source: Source
    let freshness: Freshness
    let fallbackReason: FallbackReason?
    let hasPreviousSnapshot: Bool

    static func appDefault(for feature: AppFeature) -> Self {
        Self(isEnabled: feature.flag.defaultValue, builtInDefault: feature.flag.defaultValue,
             source: .appDefault, freshness: .appDefaultsOnly,
             fallbackReason: .noSnapshot, hasPreviousSnapshot: false)
    }

    func settingExplanation(hasCurrentAccount: Bool) -> String {
        if freshness == .appDefaultsOnly {
            if hasCurrentAccount {
                return "Not connected yet. Connect this account to check the server’s setting. The app default is shown for now."
            }
            return "App default only. A server’s setting and availability have not been checked here."
        }
        let origin: String = switch source {
        case .server: "Server setting."
        case .appDefault:
            switch fallbackReason {
            case .malformedObject: "App default: the server’s feature settings could not be read."
            case .malformedValue: "App default: this feature’s server setting was invalid."
            case .missingValue: "App default: the server did not provide a value for this feature."
            case .noSnapshot, nil: "App default: no server setting has arrived yet."
            }
        }
        if freshness == .awaitingSnapshot {
            return hasPreviousSnapshot
                ? "Last known setting; waiting for the next connection’s update. \(origin)"
                : "Waiting for the connection’s feature settings. \(origin)"
        }
        return "\(origin) From the latest accepted server update; this does not confirm a live connection or permission."
    }
}

enum FeatureCatalogueRoute: Equatable {
    case progressMessage(RequestKey)
    case priorityLevels
}

/// Only capability facts needed to offer ordinary routes, never account lists or
/// private enrollment payloads. Constructing an availability performs no work.
struct FeatureCatalogueAccess {
    var hasCurrentAccount = false
    var isWritableAccount = false
    var progressMessage: RequestKey?
    var priorityRelayConfirmed = false
    var priorityUnsupported = false
    var priorityForbidden = false
}

struct FeatureCatalogueAvailability: Equatable {
    let explanation: String
    let route: FeatureCatalogueRoute?

    static func evaluate(_ feature: AppFeature, setting: FeatureFlagEvaluation,
                         access: FeatureCatalogueAccess) -> Self {
        guard access.hasCurrentAccount else {
            return Self(explanation: "Join through the normal invitation and approval flow to check this feature for an account.", route: nil)
        }
        guard setting.isEnabled else {
            if setting.freshness == .appDefaultsOnly {
                return Self(explanation: "Using the app default while this account is not connected. Connect to check the server’s setting and requirements.", route: nil)
            }
            return Self(explanation: "Currently off. The feature’s requirements still apply if the server turns it on.", route: nil)
        }
        switch feature {
        case .progressMessages:
            guard let key = access.progressMessage else {
                return Self(explanation: "No eligible Progress message is available in this Inbox. Your server must send one first.", route: nil)
            }
            return Self(explanation: "A saved Progress message is available. New updates require a connection.", route: .progressMessage(key))
        case .accountAwareNotifications:
            return Self(explanation: "Notification delivery and account permissions must be checked through the ordinary notification flow. This catalogue does not send a notification or change permission.", route: nil)
        case .priorityLevels:
            guard access.isWritableAccount else {
                return Self(explanation: "Priority levels cannot be edited in a local example or a read-only saved account.", route: nil)
            }
            guard !access.priorityUnsupported else {
                return Self(explanation: "This server reported that it does not support priority levels.", route: nil)
            }
            guard !access.priorityForbidden else {
                return Self(explanation: "This account was not allowed to access priority levels.", route: nil)
            }
            guard access.priorityRelayConfirmed else {
                return Self(explanation: "Connect this account before opening priority levels. The server must confirm support and permission.", route: nil)
            }
            return Self(explanation: "Open the existing Priority levels settings. The server confirms support and permission there; saving remains a separate action.", route: .priorityLevels)
        }
    }
}
