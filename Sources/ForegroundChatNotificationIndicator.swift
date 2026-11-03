import SwiftUI

@MainActor
struct ForegroundChatNotificationIndicatorView: View {
    let indicator: NativeForegroundChatIndicator
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 3) {
                    Text(indicator.title.isEmpty ? "New chat reply" : indicator.title)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !indicator.body.isEmpty {
                        Text(indicator.body)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(2)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .padding(.top, 3)
            }
            .padding(12)
            .foregroundStyle(.primary)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .accessibilityLabel("Chat reply. \(indicator.title). \(indicator.body)")
        .accessibilityIdentifier("foreground-chat-notification")
    }
}
