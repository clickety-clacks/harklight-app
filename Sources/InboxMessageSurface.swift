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
    let position: Int
    let total: Int
    let hasPrevious: Bool
    let hasNext: Bool
    var inlineChat = false
    var isSupersedesTarget = false
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
                HarklightDesignSystem.palette(for: colorScheme)
                    .messageType(context.messageType).backgroundColor
                    .ignoresSafeArea()
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("\(context.position) of \(context.total)").font(.subheadline.monospacedDigit())
                        .foregroundStyle(HarklightDesignSystem.palette(for: colorScheme)
                            .messageType(context.messageType).textColor)
                        .padding(.horizontal, 12).padding(.vertical, 7).glassEffect(in: Capsule())
                }
            }
            .accessibilityAction(named: "Previous message") { if context.hasPrevious { context.move(-1) } }
            .accessibilityAction(named: "Next message") { if context.hasNext { context.move(1) } }
        }
    }
}

struct MessageChoiceLabel: View {
    let title: String
    let detail: String
    let selected: Bool
    let multiple: Bool
    let suggested: Bool
    var ownAnswer = false
    var drawsSurface = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.harklightMessageType) private var messageType

    private var appearance: HarklightDesignSource.Appearance {
        HarklightDesignSystem.palette(for: colorScheme)
    }

    private var messageColors: HarklightDesignSource.MessageType {
        appearance.messageType(messageType)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                if multiple {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(selected ? messageColors.textColor : messageColors.secondaryTextColor,
                                lineWidth: 1.5)
                        .frame(width: 20, height: 20)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.caption.bold())
                            .foregroundStyle(messageColors.textColor)
                    }
                } else {
                    Circle()
                        .stroke(selected ? messageColors.textColor : messageColors.secondaryTextColor,
                                lineWidth: selected ? 6 : 2)
                        .frame(width: 20, height: 20)
                }
            }
            .frame(width: 20, height: 22)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(title).font(.headline)
                    if suggested {
                        Text("Suggested")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(messageColors.secondaryTextColor)
                    }
                }
                if !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(messageColors.secondaryTextColor)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(messageColors.textColor)
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if drawsSurface {
                RoundedRectangle(cornerRadius: 16)
                    .fill(selected ? appearance.detail.selectedChoiceColor : Color.clear)
            }
        }
        .overlay {
            if drawsSurface {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(selected ? messageColors.textColor : messageColors.textColor.opacity(0.3),
                                  style: StrokeStyle(lineWidth: selected ? 1.5 : 1,
                                                     dash: ownAnswer ? [5, 4] : []))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}
