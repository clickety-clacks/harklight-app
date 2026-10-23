import SwiftUI

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
    var canInlineChat = false
    var openChat: (() -> Void)? = nil
    var dismissToList: (() -> Void)? = nil
    let move: (Int) -> Void

    static var standalone: InboxCardContext {
        InboxCardContext(position: 1, total: 1, previous: nil, next: nil, move: { _ in })
    }
}

/// Native scroll and toolbar host shared by admitted messages and local examples.
struct MessageCardSurface<Content: View>: View {
    let context: InboxCardContext
    var backgroundColor: Color = Color(red: 0.89, green: 0.94, blue: 1)
    @ViewBuilder let content: () -> Content
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @State private var pull: CGFloat = 0
    @State private var armedDirection = 0
    @State private var contentHeight: CGFloat = 0

    private let bottomControlClearance: CGFloat = 72

    var body: some View {
        GeometryReader { viewport in
            let availableHeight = max(0, viewport.size.height - bottomControlClearance)
            let needsBottomControlClearance = contentHeight > availableHeight + 1

            ScrollView {
                content()
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
            .background {
                let detailBackground = colorScheme == .dark
                    ? Color(uiColor: .systemBackground)
                    : backgroundColor
                (horizontalSizeClass == .compact ? detailBackground : Color(uiColor: .systemBackground))
                    .ignoresSafeArea()
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
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
                if oldPhase == .interacting && newPhase != .interacting && armedDirection != 0 {
                    context.move(armedDirection)
                }
            }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(preview.sender).font(.subheadline.weight(.semibold))
            Text(preview.title).font(.title.bold())
            Text(preview.body).font(.body)
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: .infinity, alignment: showingBottom ? .bottom : .top)
        .clipped().background(Color(uiColor: .systemBackground))
        .padding(showingBottom ? .bottom : .top, 8).background(.white)
        .overlay(alignment: .trailing) {
            if armed {
                Image(systemName: showingBottom ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .padding().foregroundStyle(.blue)
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
    var selectionColor: Color = .blue
    var ownAnswer = false
    var drawsSurface = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                if multiple {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(selected ? Color.white : Color.secondary, lineWidth: 1.5)
                        .frame(width: 20, height: 20)
                    if selected { Image(systemName: "checkmark").font(.caption.bold()) }
                } else {
                    Circle()
                        .stroke(selected ? Color.white : Color.secondary, lineWidth: 1.5)
                        .frame(width: 20, height: 20)
                    if selected { Circle().fill(.white).frame(width: 11, height: 11) }
                }
            }
            .frame(width: 20, height: 22)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(title).font(.headline)
                    if suggested {
                        Text("Suggested")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(selected ? Color.white : Color.blue)
                    }
                }
                if !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if drawsSurface {
                RoundedRectangle(cornerRadius: 16)
                    .fill(selected ? selectionColor : Color(uiColor: .systemBackground))
            }
        }
        .overlay {
            if drawsSurface {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected ? Color.clear : Color(uiColor: .separator).opacity(ownAnswer ? 0.6 : 0),
                                  style: StrokeStyle(lineWidth: ownAnswer ? 1.5 : 0,
                                                     dash: ownAnswer ? [5, 4] : []))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}
