import AttentionDomain
import SwiftUI

extension EnvironmentValues {
    @Entry var openCatalogueMessage: (@MainActor (RequestKey) -> Void)? = nil
}

/// Describes features without fetching account data or changing any permission.
/// Only an explicit route button may ask the enclosing ordinary UI to navigate.
@MainActor
struct FeatureCatalogueView: View {
    let store: LivePresentationStore?
    let flags: RemoteFeatureFlags
    let onOpen: ((FeatureCatalogueRoute) -> Void)?

    init(store: LivePresentationStore? = nil, flags: RemoteFeatureFlags? = nil,
         onOpen: ((FeatureCatalogueRoute) -> Void)? = nil) {
        self.store = store
        self.flags = flags ?? NativeRelayLifecycle.shared.featureFlags
        self.onOpen = onOpen
    }

    private func evaluation(_ feature: AppFeature) -> FeatureFlagEvaluation {
        guard let store, !store.isReadOnly, !store.isLocalExample else {
            return .appDefault(for: feature)
        }
        return flags.evaluation(for: feature, expected: store.notificationContext)
    }

    private func access(for setting: FeatureFlagEvaluation) -> FeatureCatalogueAccess {
        guard let store else { return FeatureCatalogueAccess() }
        return FeatureCatalogueAccess(
            hasCurrentAccount: !store.isReadOnly && !store.isLocalExample &&
                setting.freshness != .appDefaultsOnly,
            isWritableAccount: store.canSendToCurrentServer && !store.isLocalExample,
            progressMessage: ProgressInboxProjection.rows(
                store.inboxRows.map { InboxItem.request($0) }, search: "",
                enabled: setting.isEnabled).first?.key,
            priorityRelayConfirmed: NativeRelayLifecycle.shared
                .hasConfirmedPriorityLevelsRelay(for: store.notificationContext),
            priorityUnsupported: store.priorityLevelsState.failureReason == "unknown_type",
            priorityForbidden: store.priorityLevelsState.failureReason == "forbidden")
    }

    var body: some View {
        Form {
            Section {
                Text("Feature settings, availability and maturity are different. Your server controls its settings; an on setting does not grant account permission or server support.")
                Text("Alpha and Beta describe the limits below, not a promise of general readiness.")
                    .foregroundStyle(.hkSecondary)
            }
            ForEach(AppFeature.allCases) { feature in
                let setting = evaluation(feature)
                let availability = FeatureCatalogueAvailability.evaluate(
                    feature, setting: setting, access: access(for: setting))
                Section {
                    Text(feature.description)
                        .accessibilityIdentifier("feature-\(feature.rawValue)-description")
                    LabeledContent("Maturity", value: feature.maturity.rawValue)
                    Text(feature.maturity.explanation).foregroundStyle(.hkSecondary)
                    Text(feature.limitation)
                    LabeledContent(setting.freshness == .appDefaultsOnly ? "App default" : "Current setting",
                                   value: setting.isEnabled ? "On" : "Off")
                        .accessibilityIdentifier("feature-\(feature.rawValue)-setting")
                    Text(setting.settingExplanation)
                        .foregroundStyle(.hkSecondary)
                        .accessibilityIdentifier("feature-\(feature.rawValue)-provenance")
                    if setting.freshness != .appDefaultsOnly {
                        LabeledContent("App default", value: setting.builtInDefault ? "On" : "Off")
                    }
                    Text(availability.explanation)
                        .accessibilityIdentifier("feature-\(feature.rawValue)-availability")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Requirements").font(.subheadline.weight(.semibold))
                        Text(feature.requirements)
                    }
                    if let route = availability.route, onOpen != nil {
                        Button(routeTitle(route)) {
                            // Re-evaluate after a flag/profile change before navigating.
                            let current = evaluation(feature)
                            guard let currentRoute = FeatureCatalogueAvailability.evaluate(
                                feature, setting: current, access: access(for: current)).route else { return }
                            onOpen?(currentRoute)
                        }
                        .accessibilityIdentifier("feature-\(feature.rawValue)-open")
                    }
                    if feature == .accountAwareNotifications {
                        Text("Use the normal notification choice when joining. To review your device’s permission later, open Settings on this device, then Notifications, then Harklight. Receive and tap a real notification to exercise routing; this page does not send one.")
                    }
                } header: {
                    Text(feature.title)
                        .accessibilityIdentifier("feature-\(feature.rawValue)-title")
                }
            }
        }
        .harklightListSurface(.sheet)
        .harklightSheetTitle("Features")
        .accessibilityIdentifier("feature-catalogue")
    }

    private func routeTitle(_ route: FeatureCatalogueRoute) -> String {
        switch route {
        case .progressMessage: "Open a Progress message"
        case .priorityLevels: "Open Priority levels settings"
        }
    }
}
