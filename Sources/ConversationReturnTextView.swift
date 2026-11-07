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
        if view.text != text {
            context.coordinator.invalidateSizeMeasurement()
            view.text = text
        }
        if view.isEditable != isEnabled {
            view.isEditable = isEnabled
        }
        let accessibilityValue = text.isEmpty ? placeholder : text
        if view.accessibilityValue as? String != accessibilityValue {
            view.accessibilityValue = accessibilityValue
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        if let cached = context.coordinator.cachedSizeThatFits(for: uiView, width: width) {
            return cached
        }
        let lineHeight = uiView.font?.lineHeight ?? 20
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let size = CGSize(width: width, height: min(max(measured.height, lineHeight), lineHeight * 5))
        context.coordinator.cacheSizeThatFits(size, for: uiView, width: width)
        return size
    }

    final class Coordinator: NSObject, UITextViewDelegate, UITextPasteDelegate {
        var parent: ConversationReturnTextView
        private var applyingPaste = false
        private var cachedMeasurementKey: MeasurementKey?
        private var cachedMeasurementSize: CGSize?

        private struct InsetsKey: Equatable {
            let top: CGFloat
            let left: CGFloat
            let bottom: CGFloat
            let right: CGFloat

            init(_ insets: UIEdgeInsets) {
                top = insets.top
                left = insets.left
                bottom = insets.bottom
                right = insets.right
            }
        }

        private struct MeasurementKey: Equatable {
            let text: String
            let width: CGFloat
            let fontName: String?
            let fontPointSize: CGFloat
            let fontLineHeight: CGFloat
            let fontTraits: UInt32
            let textContainerInset: InsetsKey
            let contentInset: InsetsKey
            let adjustedContentInset: InsetsKey
            let lineFragmentPadding: CGFloat
            let isComposing: Bool

            init(_ textView: UITextView, width: CGFloat) {
                text = textView.text
                self.width = width
                fontName = textView.font?.fontName
                fontPointSize = textView.font?.pointSize ?? 0
                fontLineHeight = textView.font?.lineHeight ?? 20
                fontTraits = textView.font?.fontDescriptor.symbolicTraits.rawValue ?? 0
                textContainerInset = InsetsKey(textView.textContainerInset)
                contentInset = InsetsKey(textView.contentInset)
                adjustedContentInset = InsetsKey(textView.adjustedContentInset)
                lineFragmentPadding = textView.textContainer.lineFragmentPadding
                isComposing = textView.markedTextRange != nil
            }
        }

        init(_ parent: ConversationReturnTextView) { self.parent = parent }

        func invalidateSizeMeasurement() {
            cachedMeasurementKey = nil
            cachedMeasurementSize = nil
        }

        func cachedSizeThatFits(for textView: UITextView, width: CGFloat) -> CGSize? {
            let key = MeasurementKey(textView, width: width)
            guard cachedMeasurementKey == key else { return nil }
            return cachedMeasurementSize
        }

        func cacheSizeThatFits(_ size: CGSize, for textView: UITextView, width: CGFloat) {
            cachedMeasurementKey = MeasurementKey(textView, width: width)
            cachedMeasurementSize = size
        }

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
