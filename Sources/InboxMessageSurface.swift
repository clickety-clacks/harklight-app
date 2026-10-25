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

struct InboxCardPreview {
    let sender: String
    let title: String
    let body: String
}

struct InboxCardContext {
    let position: Int
    let total: Int
    let previous: InboxCardPreview?
    let next: InboxCardPreview?
    var inlineChat = false
    var dismissToList: (() -> Void)? = nil
    var messageType: HarklightMessageType = .request
    let move: (Int) -> Void

    static var standalone: InboxCardContext {
        InboxCardContext(position: 1, total: 1, previous: nil, next: nil, move: { _ in })
    }
}

/// Native scroll and toolbar host shared by admitted messages and local examples.
struct MessageCardSurface<Content: View>: View {
    let context: InboxCardContext
    let replyEditorIsOpen: Bool
    private let onDownwardContentSwipe: () -> Void
    private let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme
    @State private var pull: CGFloat = 0
    @State private var armedDirection = 0
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
            // Only add scroll room when the card is taller than the usable area.
            // Short cards stay at the true boundary for the next/previous pull gesture.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if needsBottomControlClearance {
                    Color.clear.frame(height: bottomControlClearance).accessibilityHidden(true)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { previousOffset, offset in
                if scrollIsInteracting,
                   offset < previousOffset - 1 {
                    movedContentDownDuringInteraction = true
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                let top = geometry.contentOffset.y + geometry.contentInsets.top
                let extent = max(0, geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom)
                let bottom = top - extent
                if top < 0 { return -top }
                if bottom > 0 { return -bottom }
                return 0
            } action: { _, value in
                pull = value
                let direction = value > 0 ? -1 : 1
                let neighbor = direction < 0 ? context.previous : context.next
                armedDirection = abs(value) >= 80 && neighbor != nil ? direction : 0
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
                if oldPhase == .interacting && newPhase != .interacting && armedDirection != 0 {
                    context.move(armedDirection)
                }
            }
            .background {
                HarklightDesignSystem.palette(for: colorScheme)
                    .messageType(context.messageType).backgroundColor
                    .ignoresSafeArea()
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: pull > 0 ? .top : .bottom) {
                if abs(pull) > 8, let neighbor = pull > 0 ? context.previous : context.next {
                    MessageNeighborPreview(preview: neighbor, showingBottom: pull > 0, armed: armedDirection != 0)
                        .frame(height: armedDirection != 0 ? 104 : min(80, abs(pull)), alignment: pull > 0 ? .bottom : .top)
                        .clipped().allowsHitTesting(false)
                        .animation(.snappy, value: armedDirection)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("\(context.position) of \(context.total)").font(.subheadline.monospacedDigit())
                        .foregroundStyle(HarklightDesignSystem.palette(for: colorScheme)
                            .messageType(context.messageType).textColor)
                        .padding(.horizontal, 12).padding(.vertical, 7).glassEffect(in: Capsule())
                }
            }
            .accessibilityAction(named: "Previous message") { if context.previous != nil { context.move(-1) } }
            .accessibilityAction(named: "Next message") { if context.next != nil { context.move(1) } }
        }
    }
}

struct MessageNeighborPreview: View {
    let preview: InboxCardPreview
    let showingBottom: Bool
    let armed: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var neutral: HarklightDesignSource.Neutral {
        HarklightDesignSystem.palette(for: colorScheme).neutral
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(preview.sender).font(.subheadline.weight(.semibold))
            Text(preview.title).font(.title.bold())
            Text(preview.body).font(.body)
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: .infinity, alignment: showingBottom ? .bottom : .top)
        .clipped().background(neutral.backgroundColor)
        .foregroundStyle(neutral.textColor)
        .padding(showingBottom ? .bottom : .top, 8).background(neutral.backgroundColor)
        .overlay(alignment: .trailing) {
            if armed {
                Image(systemName: showingBottom ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .padding().foregroundStyle(neutral.textColor)
            }
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
