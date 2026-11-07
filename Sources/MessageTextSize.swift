import SwiftUI
import UIKit

enum MessageTextSize: String, CaseIterable, Equatable, Identifiable, Sendable {
    case standard
    case large
    case larger

    static let preferenceKey = "harklight.messageTextSize"

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .standard: "Standard"
        case .large: "Large"
        case .larger: "Larger"
        }
    }

    var multiplier: CGFloat {
        switch self {
        case .standard: 1
        case .large: 1.2
        case .larger: 1.4
        }
    }

    static func resolve(storedValue: String) -> Self {
        Self(rawValue: storedValue) ?? .standard
    }

    func font(basePointSize: CGFloat = 17,
              weight: Font.Weight = .regular,
              relativeTo textStyle: Font.TextStyle = .body) -> Font {
        .system(size: basePointSize * multiplier,
                weight: weight,
                design: .default,
                relativeTo: textStyle)
    }

    func uiFont(basePointSize: CGFloat = 17,
                weight: UIFont.Weight = .regular,
                compatibleWith traits: UITraitCollection) -> UIFont {
        let base = UIFont.systemFont(ofSize: basePointSize * multiplier, weight: weight)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base,
                                                              compatibleWith: traits)
    }
}

private struct MessageTextSizeEnvironmentKey: EnvironmentKey {
    static let defaultValue = MessageTextSize.standard
}

extension EnvironmentValues {
    var messageTextSize: MessageTextSize {
        get { self[MessageTextSizeEnvironmentKey.self] }
        set { self[MessageTextSizeEnvironmentKey.self] = newValue }
    }
}

private struct MessageTextSizeModifier: ViewModifier {
    @Environment(\.messageTextSize) private var messageTextSize
    let basePointSize: CGFloat
    let weight: Font.Weight
    let relativeTo: Font.TextStyle

    func body(content: Content) -> some View {
        content.font(messageTextSize.font(basePointSize: basePointSize,
                                          weight: weight,
                                          relativeTo: relativeTo))
    }
}

extension View {
    func messageTextSize(basePointSize: CGFloat = 17,
                         weight: Font.Weight = .regular,
                         relativeTo textStyle: Font.TextStyle = .body) -> some View {
        modifier(MessageTextSizeModifier(basePointSize: basePointSize,
                                         weight: weight,
                                         relativeTo: textStyle))
    }
}

struct MessageTextSizeSettingsSection: View {
    @AppStorage(MessageTextSize.preferenceKey)
    private var selectedRawValue = MessageTextSize.standard.rawValue

    var body: some View {
        Section {
            Picker("Message text size", selection: $selectedRawValue) {
                ForEach(MessageTextSize.allCases) { size in
                    Text(size.title)
                        .tag(size.rawValue)
                        .accessibilityIdentifier("message-text-size-\(size.rawValue)")
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("message-text-size-picker")

            Text("Changes authored message text only. Standard matches system body size; larger steps also follow Dynamic Type.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Message text")
        }
        .accessibilityIdentifier("message-text-size-section")
    }
}
