import SwiftUI
import UIKit

/// A multiline message editor whose keyboard Send key invokes an explicit action.
/// Pasted newlines remain text, including when the paste contains only a newline.
struct ConversationReturnTextView: UIViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    let onReturn: () -> Void

    private let placeholder = "Write a message…"

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.pasteDelegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.returnKeyType = .send
        view.isScrollEnabled = true
        view.accessibilityIdentifier = "sample-chat-composer"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        view.isEditable = isEnabled
        view.accessibilityValue = text.isEmpty ? placeholder : text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let lineHeight = uiView.font?.lineHeight ?? 20
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: min(max(measured.height, lineHeight), lineHeight * 5))
    }

    final class Coordinator: NSObject, UITextViewDelegate, UITextPasteDelegate {
        var parent: ConversationReturnTextView
        private var applyingPaste = false

        init(_ parent: ConversationReturnTextView) { self.parent = parent }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText replacement: String) -> Bool {
            if replacement == "\n", !applyingPaste, textView.markedTextRange == nil {
                parent.onReturn()
                return false
            }
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            textView.accessibilityValue = textView.text.isEmpty ? parent.placeholder : textView.text
        }

        func textPasteConfigurationSupporting(
            _ support: any UITextPasteConfigurationSupporting,
            performPasteOf attributedString: NSAttributedString,
            to range: UITextRange
        ) -> UITextRange {
            guard let view = support as? UITextView else { return range }
            applyingPaste = true
            defer { applyingPaste = false }
            view.replace(range, withText: attributedString.string)
            parent.text = view.text
            let end = view.position(from: range.start, offset: attributedString.string.utf16.count) ?? range.end
            return view.textRange(from: range.start, to: end) ?? range
        }
    }
}
