import AttentionDomain
import SwiftUI

extension EnvironmentValues {
    @Entry var harklightMessageType: HarklightMessageType = .request
}

private struct MessageCardContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct InboxCardContext {
    let position: Int?
    let total: Int?
    let hasPrevious: Bool
    let hasNext: Bool
    var inlineChat = false
    var reopenInlineChat: (() -> Void)? = nil
    var isSupersedesTarget = false
    var chatTargetFallsBackToMessage = false
    var notificationChatRouteSerial: UInt64? = nil
    var notificationChatRouteDidOpen: (() -> Void)? = nil
    /// Turn the chat should scroll to when the chat route opens it, such as
    /// the earliest unseen reply of a tapped reply item.
    var chatScrollTargetTurnID: ExactText? = nil
    var dismissToList: (() -> Void)? = nil
    var messageType: HarklightMessageType = .request
    let move: (Int) -> Void

    static var standalone: InboxCardContext {
        InboxCardContext(position: 1, total: 1, hasPrevious: false, hasNext: false, move: { _ in })
    }

    static var supersedesTarget: InboxCardContext {
        InboxCardContext(position: 1, total: 1, hasPrevious: false, hasNext: false,
                         isSupersedesTarget: true, move: { _ in })
    }
}

/// Native scroll and toolbar host shared by admitted messages and local examples.
@MainActor
struct MessageCardSurface<Content: View>: View {
    let context: InboxCardContext
    let replyEditorIsOpen: Bool
    private let onDownwardContentSwipe: () -> Void
    private let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme
    @State private var contentHeight: CGFloat = 0
    @State private var scrollIsInteracting = false
    @State private var movedContentDownDuringInteraction = false

    private let bottomControlClearance: CGFloat = 72

    init(context: InboxCardContext,
         replyEditorIsOpen: Bool,
         onDownwardContentSwipe: @escaping () -> Void = {},
         @ViewBuilder content: @escaping () -> Content) {
        self.context = context
        self.replyEditorIsOpen = replyEditorIsOpen
        self.onDownwardContentSwipe = onDownwardContentSwipe
        self.content = content
    }

    var body: some View {
        GeometryReader { viewport in
            let availableHeight = max(0, viewport.size.height - bottomControlClearance)
            let needsBottomControlClearance = contentHeight > availableHeight + 1

            ScrollView {
                content()
                    .environment(\.harklightMessageType, context.messageType)
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: MessageCardContentHeightKey.self,
                                                   value: geometry.size.height)
                        }
                        .allowsHitTesting(false)
                    }
            }
            .accessibilityIdentifier("message-card-scroll")
            .scrollBounceBehavior(.always)
            .scrollDismissesKeyboard(.interactively)
            .onPreferenceChange(MessageCardContentHeightKey.self) { contentHeight = $0 }
            // Add scroll room only when message content would extend beneath the bottom controls.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if needsBottomControlClearance {
                    Color.clear.frame(height: bottomControlClearance).accessibilityHidden(true)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { previousOffset, offset in
                if scrollIsInteracting, !movedContentDownDuringInteraction,
                   offset < previousOffset - 1 {
                    movedContentDownDuringInteraction = true
                }
            }
            .onScrollPhaseChange { oldPhase, newPhase in
                if newPhase == .interacting {
                    scrollIsInteracting = true
                    movedContentDownDuringInteraction = false
                } else if oldPhase == .interacting {
                    scrollIsInteracting = false
                    if movedContentDownDuringInteraction && replyEditorIsOpen {
                        onDownwardContentSwipe()
                    }
                    movedContentDownDuringInteraction = false
                } else {
                    scrollIsInteracting = false
                }
            }
            .background {
                // The type tint fills to every edge, behind the bars, and on
                // iPad runs beneath the floating list panel.
                HarklightDesignSystem.palette(for: colorScheme)
                    .typeTint(context.messageType)
                    .backgroundExtensionEffect()
                    .ignoresSafeArea()
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let position = context.position, let total = context.total {
                    ToolbarItem(placement: .principal) {
                        Text("\(position) of \(total)")
                            .harklightType(.positionPill)
                            .monospacedDigit()
                            .foregroundStyle(HarklightDesignSystem.palette(for: colorScheme).text)
                            .padding(.horizontal, 14).padding(.vertical, 10).glassEffect(in: Capsule())
                    }
                }
            }
            .accessibilityAction(named: "Previous message") { if context.hasPrevious { context.move(-1) } }
            .accessibilityAction(named: "Next message") { if context.hasNext { context.move(1) } }
        }
    }
}

enum MessageChoiceAppearance: Equatable {
    case card, prominent, destructive

    init(style: MessageChoiceStyle?) {
        switch style {
        case .primary: self = .prominent
        case .destructive: self = .destructive
        case .secondary, nil: self = .card
        }
    }

    /// Only the tappable summary is inside a system button. Editors, failed
    /// replies and read-only replies keep their standalone card surface.
    static func writtenReply(style: MessageChoiceStyle?, showsEditor: Bool,
                             isReadOnly: Bool, failed: Bool) -> Self {
        showsEditor || isReadOnly || failed ? .card : Self(style: style)
    }

    /// The accent is amber in each appearance; onBeam is its contrasting
    /// foreground (also used by the amber priority capsule).
    func foregroundToken(for colorScheme: ColorScheme, isEnabled: Bool) -> String? {
        self == .prominent && isEnabled
            ? HarklightDesignSystem.palette(for: colorScheme).color.onBeam : nil
    }

    /// The translucent saved-reply pane is lighter than the accent in both
    /// appearances, so it uses the existing dark foreground for accent content.
    func savedReplyForegroundToken(for colorScheme: ColorScheme, isEnabled: Bool) -> String? {
        self == .prominent && isEnabled
            ? HarklightDesignSystem.palette(for: colorScheme).color.onAccent : nil
    }

    var usesSystemSurface: Bool { self != .card }
}

extension EnvironmentValues {
    @Entry var harklightChoiceAppearance: MessageChoiceAppearance = .card
}

struct MessageChoiceLabel: View {
    let title: String
    let detail: String
    let selected: Bool
    let multiple: Bool
    let suggested: Bool
    var ownAnswer = false
    var drawsSurface = true
    /// Which submission this choice sends, for its in-place send state.
    var submissionKind: SubmissionControlPhase.Kind = .answer
    /// Off where the surrounding control shows the failure itself, as the
    /// written-reply card does with its locked text, Edit and Retry.
    var showsFailure = true

    @Environment(\.harklightChoiceAppearance) private var appearance
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.harklightMessageType) private var messageType
    @Environment(\.harklightSubmissionDisplay) private var submission

    private var messageColors: HarklightMessageColors {
        HarklightDesignSystem.palette(for: colorScheme).message(messageType)
    }

    private func choiceForeground(fallback: Color) -> AnyShapeStyle {
        if let token = appearance.foregroundToken(for: colorScheme, isEnabled: isEnabled) {
            return AnyShapeStyle(Color(harklightToken: token))
        }
        return appearance.usesSystemSurface ? AnyShapeStyle(.foreground) : AnyShapeStyle(fallback)
    }

    private var textStyle: AnyShapeStyle {
        choiceForeground(fallback: messageColors.text)
    }
    private var secondaryStyle: AnyShapeStyle {
        choiceForeground(fallback: messageColors.secondary)
    }
    private var beamStyle: AnyShapeStyle {
        choiceForeground(fallback: messageColors.beam)
    }

    private var cornerRadius: CGFloat { HarklightDesignSystem.shape(.card) }

    /// The picked choice carries the send state: a spinner while sending, an
    /// error mark and Retry when it did not go through.
    private var isSendingHere: Bool { selected && submission.isSending(submissionKind) }
    private var isFailedHere: Bool { showsFailure && selected && submission.isFailed(submissionKind) }

    private var markSize: CGFloat { HarklightDesignSystem.shape(.choiceMarkSize) }
    private var markStroke: CGFloat { HarklightDesignSystem.shape(.choiceMarkStroke) }

    @ViewBuilder
    private var mark: some View {
        if isSendingHere {
            ProgressView()
                .controlSize(.small)
                .tint(appearance.usesSystemSurface ? nil : messageColors.beam)
                .accessibilityLabel("Sending")
        } else if isFailedHere {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: markSize, weight: .regular))
                .foregroundStyle(HarklightDesignSystem.palette(for: colorScheme).coral)
                .accessibilityLabel("Did not send")
        } else if multiple {
            ZStack {
                RoundedRectangle(cornerRadius: HarklightDesignSystem.shape(.choiceCheckboxRadius))
                    .stroke(selected ? beamStyle : secondaryStyle, lineWidth: markStroke)
                    .frame(width: markSize, height: markSize)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(beamStyle)
                }
            }
        } else {
            // A picked choice's mark is a 6 point ring in the type color.
            Circle()
                .stroke(selected ? beamStyle : secondaryStyle,
                        lineWidth: selected ? HarklightDesignSystem.shape(.choicePickedRadioStroke) : markStroke)
                .frame(width: markSize, height: markSize)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HarklightDesignSystem.shape(.choiceMarkGap)) {
            mark
                .frame(width: markSize, height: markSize)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + HarklightDesignSystem.shape(.choiceMarkBaselineOffset) }
            VStack(alignment: .leading, spacing: HarklightDesignSystem.shape(.choiceTextStackSpacing)) {
                HStack(alignment: .firstTextBaseline, spacing: HarklightDesignSystem.shape(.choiceSuggestedGap)) {
                    Text(title)
                        .harklightType(.choiceTitle)
                        .foregroundStyle(textStyle)
                    if suggested {
                        Text("Suggested")
                            .textCase(.uppercase)
                            .harklightType(.suggested)
                            .foregroundStyle(secondaryStyle)
                    }
                }
                if !detail.isEmpty {
                    Text(detail)
                        .harklightType(.choiceDetail)
                        .foregroundStyle(secondaryStyle)
                }
            }
            Spacer(minLength: 0)
            if isFailedHere, submission.retryAction(submissionKind) != nil {
                Text("Retry")
                    .harklightType(.choiceTitle)
                    .foregroundStyle(beamStyle)
                    .accessibilityIdentifier("request-choice-retry")
            }
        }
        .foregroundStyle(textStyle)
        .padding(HarklightDesignSystem.shape(.choicePadding)).frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if drawsSurface && !appearance.usesSystemSurface {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(selected ? messageColors.pickedFill : messageColors.raised)
            }
        }
        .overlay {
            if drawsSurface && !appearance.usesSystemSurface {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(selected ? beamStyle : AnyShapeStyle(messageColors.line),
                                  style: StrokeStyle(lineWidth: HarklightDesignSystem.shape(.lineWidth),
                                                     dash: ownAnswer && !selected ? HarklightDesignSystem.replyBorderDash : []))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        // While one choice is sending, the others step back.
        .opacity(submission.isSendingAny && !selected ? 0.45 : 1)
    }
}
