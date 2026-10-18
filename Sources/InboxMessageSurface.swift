import SwiftUI

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
    let move: (Int) -> Void

    static var standalone: InboxCardContext {
        InboxCardContext(position: 1, total: 1, previous: nil, next: nil, move: { _ in })
    }
}

/// Native scroll and toolbar host shared by admitted messages and local examples.
struct MessageCardSurface<Content: View>: View {
    let context: InboxCardContext
    @ViewBuilder let content: () -> Content
    @State private var pull: CGFloat = 0
    @State private var armedDirection = 0

    var body: some View {
        ScrollView {
            content().frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("message-card-scroll")
        .scrollBounceBehavior(.always)
        .scrollDismissesKeyboard(.interactively)
        // Keep the last answer and receipt controls scrollable above the
        // overlaid bottom toolbar.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 72).accessibilityHidden(true)
        }
        .background { Color(uiColor: .systemBackground).ignoresSafeArea() }
        .toolbarBackground(.hidden, for: .navigationBar, .bottomBar)
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: multiple
                  ? (selected ? "checkmark.square.fill" : "square")
                  : (selected ? "checkmark.circle.fill" : "circle"))
                .foregroundStyle(selected ? selectionColor : .secondary).font(.title3)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                if suggested { Text("Suggested").font(.caption.weight(.semibold)).foregroundStyle(.blue) }
            }
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? selectionColor.opacity(0.13)
                    : suggested ? Color.blue.opacity(0.05) : Color(uiColor: .systemBackground),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(selected ? selectionColor : Color(uiColor: .separator).opacity(0.25),
                    lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}
