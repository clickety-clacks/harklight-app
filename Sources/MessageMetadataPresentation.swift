import AttentionDomain
import SwiftUI

extension EnvironmentValues {
    @Entry var harklightReduceMotionOverride: Bool? = nil
}

struct MessageMetadataPresentation {
    var declaredType: MessageTypeValue? = nil
    var kind: MessageKindValue? = nil
    var hasSeenDescriptor = false

    var resolvedType: MessageTypeValue {
        declaredType ?? (hasSeenDescriptor ? .fyi : .request)
    }

    func iconRole(for designType: HarklightMessageType) -> MessageIconRole {
        switch (resolvedType, kind) {
        case (.request, .blocker): .requestBlocker
        case (.request, .success): .requestSuccess
        case (.fyi, .blocker): .fyiBlocker
        case (.fyi, .success): .fyiSuccess
        case (.request, nil) where declaredType != nil: .request
        case (.fyi, nil) where declaredType != nil: .fyi
        case (_, nil): designType.iconRole
        }
    }

    /// Match the old badges' explicit metadata. Legacy Seen controls can
    /// determine the icon without inventing a sender-declared accessibility label.
    var accessibilityLabels: [LocalizedStringResource] {
        let typeLabel: LocalizedStringResource? = switch declaredType {
        case .fyi: "FYI"
        case .request: "Request"
        case nil: nil
        }
        let kindLabel: LocalizedStringResource? = switch kind {
        case .blocker: "Blocker"
        case .success: "Success"
        case nil: nil
        }
        return [typeLabel, kindLabel].compactMap { $0 }
    }

    func accessibilityTitle(_ title: Text) -> Text {
        accessibilityLabels.reduce(title) { title, label in
            Text("\(title), \(Text(label))")
        }
    }
}
