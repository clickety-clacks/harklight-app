import UIKit

/// Passive, offline rendering shared by the extension and focused presentation tests.
@MainActor
final class ExpandedNotificationView: UIView {
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor)
        ])
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func display(_ presentation: ExpandedNotificationPresentation) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        add(presentation.title, style: .headline)
        if let batch = presentation.batch {
            // Keep every delivered whole title, including duplicates, in order.
            for title in batch.titles { add(title, style: .body, includeEmpty: true) }
            if batch.titles.isEmpty {
                add(Self.countText(batch.totalCount), style: .footnote)
            } else if batch.remainingCount > 0 {
                let count = batch.remainingCount
                add(count == 1 ? "1 more message" : "\(count) more messages", style: .footnote)
            }
        } else {
            add(presentation.subtitle, style: .subheadline)
            add(presentation.body, style: .body)
            if presentation.title.isEmpty && presentation.subtitle.isEmpty && presentation.body.isEmpty {
                add("Open Harklight to view this notification.", style: .body)
            }
        }
    }

    private static func countText(_ count: Int) -> String {
        count == 1 ? "1 message" : "\(count) messages"
    }

    private func add(_ text: String, style: UIFont.TextStyle, includeEmpty: Bool = false) {
        guard includeEmpty || !text.isEmpty else { return }
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textColor = .label
        stack.addArrangedSubview(label)
    }
}
