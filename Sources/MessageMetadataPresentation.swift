import AttentionDomain
import SwiftUI

enum MessageTypePresentation {
    static func title(for type: MessageTypeValue) -> LocalizedStringResource {
        switch type {
        case .fyi: "FYI"
        case .request: "Request"
        }
    }

    static func symbolName(for type: MessageTypeValue) -> String {
        switch type {
        case .fyi: "info.circle.fill"
        case .request: "arrowshape.turn.up.right.fill"
        }
    }
}

enum MessageKindAccent: Equatable {
    case blocker
    case success
}

struct MessageKindPresentation {
    let kind: MessageKindValue

    var title: LocalizedStringResource {
        switch kind {
        case .blocker: "Blocker"
        case .success: "Success"
        }
    }

    var symbolName: String {
        switch kind {
        case .blocker: "exclamationmark.octagon.fill"
        case .success: "checkmark.seal.fill"
        }
    }

    var accent: MessageKindAccent {
        switch kind {
        case .blocker: .blocker
        case .success: .success
        }
    }

    var celebratoryFlairSymbolName: String? {
        kind == .success ? "sparkles" : nil
    }

    func shouldAnimateFlair(reduceMotion: Bool) -> Bool {
        kind == .success && !reduceMotion
    }
}

struct MessageMetadataBadges: View {
    let messageType: MessageTypeValue?
    let messageKind: MessageKindValue?

    @ViewBuilder
    var body: some View {
        if messageType != nil || messageKind != nil {
            HStack(alignment: .center, spacing: 6) {
                if let messageType {
                    MessageTypeBadge(type: messageType)
                }
                if let messageKind {
                    MessageKindBadge(kind: messageKind)
                }
                Spacer(minLength: 0)
            }
            .accessibilityIdentifier("message-metadata-badges")
        }
    }
}

private struct MessageTypeBadge: View {
    let type: MessageTypeValue

    private var title: LocalizedStringResource {
        MessageTypePresentation.title(for: type)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: MessageTypePresentation.symbolName(for: type))
                .accessibilityHidden(true)
            Text(title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.10), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier("message-type-\(type.rawValue)")
    }
}

private struct MessageKindBadge: View {
    let kind: MessageKindValue

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFlairActive = false

    private var presentation: MessageKindPresentation {
        MessageKindPresentation(kind: kind)
    }

    private var accentColor: Color {
        switch presentation.accent {
        case .blocker: .orange
        case .success: .green
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: presentation.symbolName)
                .foregroundStyle(accentColor)
                .accessibilityHidden(true)
            Text(presentation.title)
                .foregroundStyle(.primary)
            if let flair = presentation.celebratoryFlairSymbolName {
                Image(systemName: flair)
                    .foregroundStyle(accentColor)
                    .symbolEffect(.bounce, options: .nonRepeating,
                                  isActive: isFlairActive && presentation.shouldAnimateFlair(
                                    reduceMotion: reduceMotion))
                    .accessibilityHidden(true)
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(accentColor.opacity(0.10), in: Capsule())
        .overlay {
            Capsule().strokeBorder(accentColor.opacity(0.45), lineWidth: 0.8)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(presentation.title))
        .accessibilityIdentifier("message-kind-\(kind.rawValue)")
        .onAppear {
            guard presentation.shouldAnimateFlair(reduceMotion: reduceMotion) else { return }
            isFlairActive = true
        }
        .onChange(of: reduceMotion) { _, isReduced in
            guard isReduced else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isFlairActive = false
            }
        }
    }
}
